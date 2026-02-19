import global_config_pkg::*;
module bpu #(
    parameter config_pkg::cfg_t Cfg = config_pkg::EmptyCfg,
    parameter int unsigned BTB_ENTRIES = 64,
    parameter int unsigned BHT_ENTRIES = 128,
    parameter int unsigned RAS_DEPTH = 16,
    parameter bit BTB_HASH_ENABLE = 1'b1,
    parameter bit BHT_HASH_ENABLE = 1'b1,
    parameter bit USE_GSHARE = 1'b0,
    parameter bit USE_TOURNAMENT = 1'b1,
    parameter int unsigned GHR_BITS = 8
) (
    input logic clk_i,
    input logic rst_i,

    input  ifu_to_bpu_t ifu_to_bpu_i,
    input  handshake_t  ifu_to_bpu_handshake_i,

    // Commit-time predictor update
    input logic                update_valid_i,
    input logic [Cfg.PLEN-1:0] update_pc_i,
    input logic                update_is_cond_i,
    input logic                update_taken_i,
    input logic [Cfg.PLEN-1:0] update_target_i,
    input logic                update_is_call_i,
    input logic                update_is_ret_i,
    input logic [Cfg.NRET-1:0] ras_update_valid_i,
    input logic [Cfg.NRET-1:0] ras_update_is_call_i,
    input logic [Cfg.NRET-1:0] ras_update_is_ret_i,
    input logic [Cfg.NRET-1:0][Cfg.PLEN-1:0] ras_update_pc_i,
    input logic                flush_i,

    // from IFU
    output handshake_t  bpu_to_ifu_handshake_o,
    output bpu_to_ifu_t bpu_to_ifu_o
);

  localparam int unsigned SLOT_IDX_W = (Cfg.INSTR_PER_FETCH > 1) ? $clog2(Cfg.INSTR_PER_FETCH) : 1;
  localparam int unsigned BTB_IDX_W = (BTB_ENTRIES > 1) ? $clog2(BTB_ENTRIES) : 1;
  localparam int unsigned BHT_IDX_W = (BHT_ENTRIES > 1) ? $clog2(BHT_ENTRIES) : 1;
  localparam int unsigned INSTR_BYTES = Cfg.ILEN / 8;
  localparam int unsigned INSTR_ADDR_LSB = $clog2(INSTR_BYTES);
  localparam int unsigned BTB_TAG_W = Cfg.PLEN - BTB_IDX_W - INSTR_ADDR_LSB;
  localparam int unsigned RAS_CNT_W = (RAS_DEPTH > 0) ? $clog2(RAS_DEPTH + 1) : 1;
  localparam int unsigned GHR_W = (GHR_BITS > 0) ? GHR_BITS : 1;
  logic [BTB_ENTRIES-1:0] btb_valid_q;
  logic [BTB_ENTRIES-1:0] btb_is_cond_q;
  logic [BTB_ENTRIES-1:0] btb_is_backward_q;
  logic [BTB_ENTRIES-1:0] btb_is_call_q;
  logic [BTB_ENTRIES-1:0] btb_is_ret_q;
  logic [BTB_ENTRIES-1:0] btb_use_ras_q;
  logic [BTB_ENTRIES-1:0][BTB_TAG_W-1:0] btb_tag_q;
  logic [BTB_ENTRIES-1:0][Cfg.PLEN-1:0] btb_target_q;
  logic [BHT_ENTRIES-1:0][1:0] local_bht_q;
  logic [BHT_ENTRIES-1:0][1:0] global_bht_q;
  logic [BHT_ENTRIES-1:0][1:0] chooser_q;
  logic [RAS_DEPTH-1:0][Cfg.PLEN-1:0] arch_ras_stack_q;
  logic [RAS_DEPTH-1:0][Cfg.PLEN-1:0] spec_ras_stack_q;
  logic [RAS_CNT_W-1:0] arch_ras_count_q;
  logic [RAS_CNT_W-1:0] spec_ras_count_q;
  logic pred_event_valid_q;
  logic pred_event_is_call_q;
  logic pred_event_is_ret_q;
  logic [Cfg.PLEN-1:0] pred_event_pc_q;
  logic [GHR_W-1:0] ghr_q;
  logic [63:0] dbg_cond_update_total_q;
  logic [63:0] dbg_cond_local_correct_q;
  logic [63:0] dbg_cond_global_correct_q;
  logic [63:0] dbg_cond_selected_correct_q;
  logic [63:0] dbg_cond_choose_local_q;
  logic [63:0] dbg_cond_choose_global_q;

  function automatic logic [BTB_IDX_W-1:0] btb_index(input logic [Cfg.PLEN-1:0] pc);
    logic [BTB_IDX_W-1:0] pc_idx;
    logic [BTB_IDX_W-1:0] fold_idx;
    begin
      pc_idx = pc[INSTR_ADDR_LSB +: BTB_IDX_W];
      fold_idx = '0;
      for (int i = INSTR_ADDR_LSB + BTB_IDX_W; i < Cfg.PLEN; i++) begin
        fold_idx[(i - (INSTR_ADDR_LSB + BTB_IDX_W)) % BTB_IDX_W] ^= pc[i];
      end
      btb_index = BTB_HASH_ENABLE ? (pc_idx ^ fold_idx) : pc_idx;
    end
  endfunction

  function automatic logic [BTB_TAG_W-1:0] btb_tag(input logic [Cfg.PLEN-1:0] pc);
    btb_tag = pc[Cfg.PLEN-1:INSTR_ADDR_LSB+BTB_IDX_W];
  endfunction

  function automatic logic [BHT_IDX_W-1:0] bht_pc_index(input logic [Cfg.PLEN-1:0] pc);
    logic [BHT_IDX_W-1:0] pc_idx;
    logic [BHT_IDX_W-1:0] fold_idx;
    logic [BHT_IDX_W-1:0] mixed_pc_idx;
    begin
      pc_idx = pc[INSTR_ADDR_LSB+:BHT_IDX_W];
      fold_idx = '0;
      for (int i = INSTR_ADDR_LSB + BHT_IDX_W; i < Cfg.PLEN; i++) begin
        fold_idx[(i - (INSTR_ADDR_LSB + BHT_IDX_W)) % BHT_IDX_W] ^= pc[i];
      end
      mixed_pc_idx = BHT_HASH_ENABLE ? (pc_idx ^ fold_idx) : pc_idx;
      bht_pc_index = mixed_pc_idx;
    end
  endfunction

  function automatic logic [BHT_IDX_W-1:0] bht_global_index(input logic [Cfg.PLEN-1:0] pc,
                                                             input logic [GHR_W-1:0] ghr);
    logic [BHT_IDX_W-1:0] ghr_idx;
    begin
      ghr_idx = '0;
      for (int i = 0; i < BHT_IDX_W; i++) begin
        ghr_idx[i] = ghr[i%GHR_W];
      end
      bht_global_index = bht_pc_index(pc) ^ ghr_idx;
    end
  endfunction

  function automatic logic [1:0] sat_inc(input logic [1:0] val);
    if (val == 2'b11) sat_inc = val;
    else sat_inc = val + 2'b01;
  endfunction

  function automatic logic [1:0] sat_dec(input logic [1:0] val);
    if (val == 2'b00) sat_dec = val;
    else sat_dec = val - 2'b01;
  endfunction

  logic [Cfg.INSTR_PER_FETCH-1:0] predict_hit;
  logic [Cfg.INSTR_PER_FETCH-1:0] predict_taken;
  logic [Cfg.INSTR_PER_FETCH-1:0] predict_is_call;
  logic [Cfg.INSTR_PER_FETCH-1:0] predict_is_ret;
  logic [Cfg.INSTR_PER_FETCH-1:0][Cfg.PLEN-1:0] predict_pc;
  logic [Cfg.INSTR_PER_FETCH-1:0][Cfg.PLEN-1:0] predict_target;
  logic [Cfg.PLEN-1:0] spec_ras_top_w;
  logic spec_ras_has_entry_w;
  logic [Cfg.PLEN-1:0] arch_ras_top_w;
  logic arch_ras_has_entry_w;
  logic [SLOT_IDX_W-1:0] pred_slot_idx_w;
  logic pred_slot_valid_w;
  logic pred_slot_is_call_w;
  logic pred_slot_is_ret_w;
  logic [Cfg.PLEN-1:0] pred_slot_pc_w;
  logic [Cfg.PLEN-1:0] pred_slot_target_w;
  logic [Cfg.PLEN-1:0] pred_npc_w;

  always_comb begin
    spec_ras_has_entry_w = (spec_ras_count_q != '0);
    spec_ras_top_w = '0;
    if (spec_ras_has_entry_w) begin
      spec_ras_top_w = spec_ras_stack_q[spec_ras_count_q-1];
    end
  end

  always_comb begin
    arch_ras_has_entry_w = (arch_ras_count_q != '0);
    arch_ras_top_w = '0;
    if (arch_ras_has_entry_w) begin
      arch_ras_top_w = arch_ras_stack_q[arch_ras_count_q-1];
    end
  end

  always_comb begin
    for (int i = 0; i < Cfg.INSTR_PER_FETCH; i++) begin
      logic [BTB_IDX_W-1:0] idx;
      logic [BHT_IDX_W-1:0] local_idx;
      logic [BHT_IDX_W-1:0] global_idx;
      logic [BHT_IDX_W-1:0] chooser_idx;
      logic [Cfg.PLEN-1:0] slot_pc;
      logic local_taken_pred;
      logic global_taken_pred;
      logic use_global_pred;
      slot_pc = ifu_to_bpu_i.pc + Cfg.PLEN'(INSTR_BYTES * i);
      idx = btb_index(slot_pc);
      local_idx = bht_pc_index(slot_pc);
      global_idx = bht_global_index(slot_pc, ghr_q);
      chooser_idx = local_idx;

      predict_pc[i] = slot_pc;
      predict_target[i] = btb_target_q[idx];
      predict_hit[i] = btb_valid_q[idx] && (btb_tag_q[idx] == btb_tag(slot_pc));
      predict_is_call[i] = predict_hit[i] && btb_is_call_q[idx];
      predict_is_ret[i] = predict_hit[i] && btb_is_ret_q[idx];

      local_taken_pred = local_bht_q[local_idx][1] ||
                         ((local_bht_q[local_idx] == 2'b01) && btb_is_backward_q[idx]);
      global_taken_pred = global_bht_q[global_idx][1] ||
                          ((global_bht_q[global_idx] == 2'b01) && btb_is_backward_q[idx]);
      use_global_pred = USE_GSHARE && (!USE_TOURNAMENT || chooser_q[chooser_idx][1]);

      predict_taken[i] = 1'b0;
      if (predict_hit[i]) begin
        if (btb_is_ret_q[idx]) begin
          predict_taken[i] = 1'b1;
          if (spec_ras_has_entry_w) begin
            predict_target[i] = spec_ras_top_w;
          end
        end else if (!btb_is_cond_q[idx]) begin
          predict_taken[i] = 1'b1;
        end else begin
          if (use_global_pred) begin
            predict_taken[i] = global_taken_pred;
          end else begin
            predict_taken[i] = local_taken_pred;
          end
        end
      end
    end
  end

  always_comb begin
    pred_slot_valid_w = 1'b0;
    pred_slot_idx_w = '0;
    pred_slot_is_call_w = 1'b0;
    pred_slot_is_ret_w = 1'b0;
    pred_slot_pc_w = '0;
    pred_slot_target_w = '0;
    for (int i = 0; i < Cfg.INSTR_PER_FETCH; i++) begin
      if (!pred_slot_valid_w && predict_taken[i]) begin
        pred_slot_valid_w = 1'b1;
        pred_slot_idx_w = SLOT_IDX_W'(i);
        pred_slot_is_call_w = predict_is_call[i];
        pred_slot_is_ret_w = predict_is_ret[i];
        pred_slot_pc_w = predict_pc[i];
        pred_slot_target_w = predict_target[i];
      end
    end
  end

  assign pred_npc_w = pred_slot_valid_w ? pred_slot_target_w : (ifu_to_bpu_i.pc + Cfg.FETCH_WIDTH);

  assign bpu_to_ifu_o.pred_slot_valid = pred_slot_valid_w;
  assign bpu_to_ifu_o.pred_slot_idx = pred_slot_idx_w;
  assign bpu_to_ifu_o.pred_slot_target = pred_slot_target_w;
  assign bpu_to_ifu_o.npc = pred_npc_w;
  assign bpu_to_ifu_handshake_o.ready = 1'b1;
  assign bpu_to_ifu_handshake_o.valid = 1'b1;

  always_ff @(posedge clk_i or posedge rst_i) begin
    if (rst_i) begin
      btb_valid_q   <= '0;
      btb_is_cond_q <= '0;
      btb_is_backward_q <= '0;
      btb_is_call_q <= '0;
      btb_is_ret_q  <= '0;
      btb_use_ras_q <= '0;
      btb_tag_q     <= '0;
      btb_target_q  <= '0;
      arch_ras_stack_q   <= '0;
      spec_ras_stack_q   <= '0;
      arch_ras_count_q   <= '0;
      spec_ras_count_q   <= '0;
      pred_event_valid_q <= 1'b0;
      pred_event_is_call_q <= 1'b0;
      pred_event_is_ret_q <= 1'b0;
      pred_event_pc_q <= '0;
      ghr_q <= '0;
      dbg_cond_update_total_q <= '0;
      dbg_cond_local_correct_q <= '0;
      dbg_cond_global_correct_q <= '0;
      dbg_cond_selected_correct_q <= '0;
      dbg_cond_choose_local_q <= '0;
      dbg_cond_choose_global_q <= '0;
      for (int i = 0; i < BHT_ENTRIES; i++) begin
        local_bht_q[i] <= 2'b01;
        global_bht_q[i] <= 2'b01;
        chooser_q[i] <= 2'b01;
      end
    end else begin
      logic [RAS_DEPTH-1:0][Cfg.PLEN-1:0] arch_stack_n;
      logic [RAS_DEPTH-1:0][Cfg.PLEN-1:0] spec_stack_n;
      logic [RAS_CNT_W-1:0] arch_count_n;
      logic [RAS_CNT_W-1:0] spec_count_n;
      logic [BTB_IDX_W-1:0] up_btb_idx;
      logic [BHT_IDX_W-1:0] up_local_idx;
      logic [BHT_IDX_W-1:0] up_global_idx;
      logic [BHT_IDX_W-1:0] up_chooser_idx;
      logic do_btb_write;
      logic pred_fire_w;
      logic local_pred_before;
      logic global_pred_before;
      logic selected_pred_before;
      logic choose_global_before;
      logic local_correct;
      logic global_correct;
      logic selected_correct;

      arch_stack_n = arch_ras_stack_q;
      spec_stack_n = spec_ras_stack_q;
      arch_count_n = arch_ras_count_q;
      spec_count_n = spec_ras_count_q;

      if (update_valid_i) begin
        up_btb_idx = btb_index(update_pc_i);
        up_local_idx = bht_pc_index(update_pc_i);
        up_global_idx = bht_global_index(update_pc_i, ghr_q);
        up_chooser_idx = up_local_idx;
        do_btb_write = (!update_is_cond_i) || update_taken_i;

        if (do_btb_write) begin
          btb_valid_q[up_btb_idx] <= 1'b1;
          btb_is_cond_q[up_btb_idx] <= update_is_cond_i;
          btb_is_backward_q[up_btb_idx] <= update_is_cond_i && (update_target_i < update_pc_i);
          btb_is_call_q[up_btb_idx] <= update_is_call_i;
          btb_is_ret_q[up_btb_idx] <= update_is_ret_i;
          if (update_is_ret_i) begin
            btb_use_ras_q[up_btb_idx] <= !arch_ras_has_entry_w || (arch_ras_top_w == update_target_i);
          end else begin
            btb_use_ras_q[up_btb_idx] <= 1'b0;
          end
          btb_tag_q[up_btb_idx] <= btb_tag(update_pc_i);
          btb_target_q[up_btb_idx] <= update_target_i;
        end

        if (update_is_cond_i) begin
          local_pred_before = local_bht_q[up_local_idx][1] ||
                              ((local_bht_q[up_local_idx] == 2'b01) &&
                               btb_is_backward_q[up_btb_idx]);
          global_pred_before = global_bht_q[up_global_idx][1] ||
                               ((global_bht_q[up_global_idx] == 2'b01) &&
                                btb_is_backward_q[up_btb_idx]);
          choose_global_before = USE_GSHARE && (!USE_TOURNAMENT || chooser_q[up_chooser_idx][1]);
          selected_pred_before = choose_global_before ? global_pred_before : local_pred_before;
          local_correct = (local_pred_before == update_taken_i);
          global_correct = (global_pred_before == update_taken_i);
          selected_correct = (selected_pred_before == update_taken_i);

          dbg_cond_update_total_q <= dbg_cond_update_total_q + 64'd1;
          if (local_correct) begin
            dbg_cond_local_correct_q <= dbg_cond_local_correct_q + 64'd1;
          end
          if (global_correct) begin
            dbg_cond_global_correct_q <= dbg_cond_global_correct_q + 64'd1;
          end
          if (selected_correct) begin
            dbg_cond_selected_correct_q <= dbg_cond_selected_correct_q + 64'd1;
          end
          if (choose_global_before) begin
            dbg_cond_choose_global_q <= dbg_cond_choose_global_q + 64'd1;
          end else begin
            dbg_cond_choose_local_q <= dbg_cond_choose_local_q + 64'd1;
          end

          if (update_taken_i) begin
            local_bht_q[up_local_idx] <= sat_inc(local_bht_q[up_local_idx]);
            global_bht_q[up_global_idx] <= sat_inc(global_bht_q[up_global_idx]);
          end else begin
            local_bht_q[up_local_idx] <= sat_dec(local_bht_q[up_local_idx]);
            global_bht_q[up_global_idx] <= sat_dec(global_bht_q[up_global_idx]);
          end

          if (USE_GSHARE && USE_TOURNAMENT && (local_correct != global_correct)) begin
            if (global_correct) begin
              chooser_q[up_chooser_idx] <= sat_inc(chooser_q[up_chooser_idx]);
            end else begin
              chooser_q[up_chooser_idx] <= sat_dec(chooser_q[up_chooser_idx]);
            end
          end

          ghr_q <= {ghr_q, update_taken_i};
        end
      end

      for (int i = 0; i < Cfg.NRET; i++) begin
        if (ras_update_valid_i[i]) begin
          if (ras_update_is_call_i[i]) begin
            logic [Cfg.PLEN-1:0] call_ret_addr;
            call_ret_addr = ras_update_pc_i[i] + Cfg.PLEN'(INSTR_BYTES);
            if (arch_count_n < RAS_DEPTH) begin
              arch_stack_n[arch_count_n] = call_ret_addr;
              arch_count_n = arch_count_n + 1'b1;
            end else begin
              for (int j = 0; j < RAS_DEPTH - 1; j++) begin
                arch_stack_n[j] = arch_stack_n[j+1];
              end
              arch_stack_n[RAS_DEPTH-1] = call_ret_addr;
              arch_count_n = RAS_DEPTH[RAS_CNT_W-1:0];
            end
          end else if (ras_update_is_ret_i[i]) begin
            if (arch_count_n != '0) begin
              arch_count_n = arch_count_n - 1'b1;
            end
          end
        end
      end

      if (flush_i) begin
        spec_stack_n = arch_stack_n;
        spec_count_n = arch_count_n;
      end else if (pred_event_valid_q && pred_event_is_call_q) begin
        logic [Cfg.PLEN-1:0] spec_ret_addr;
        spec_ret_addr = pred_event_pc_q + Cfg.PLEN'(INSTR_BYTES);
        if (spec_count_n < RAS_DEPTH) begin
          spec_stack_n[spec_count_n] = spec_ret_addr;
          spec_count_n = spec_count_n + 1'b1;
        end else begin
          for (int i = 0; i < RAS_DEPTH - 1; i++) begin
            spec_stack_n[i] = spec_stack_n[i+1];
          end
          spec_stack_n[RAS_DEPTH-1] = spec_ret_addr;
          spec_count_n = RAS_DEPTH[RAS_CNT_W-1:0];
        end
      end else if (pred_event_valid_q && pred_event_is_ret_q) begin
        if (spec_count_n != '0) begin
          spec_count_n = spec_count_n - 1'b1;
        end
      end
      arch_ras_stack_q <= arch_stack_n;
      arch_ras_count_q <= arch_count_n;
      spec_ras_stack_q <= spec_stack_n;
      spec_ras_count_q <= spec_count_n;

      if (flush_i) begin
        pred_event_valid_q <= 1'b0;
        pred_event_is_call_q <= 1'b0;
        pred_event_is_ret_q <= 1'b0;
        pred_event_pc_q <= '0;
      end else begin
        // IFU consumes prediction when ready pulses (valid may be low in WAIT states).
        pred_fire_w = ifu_to_bpu_handshake_i.ready && pred_slot_valid_w;
        pred_event_valid_q <= pred_fire_w;
        pred_event_is_call_q <= pred_fire_w && pred_slot_is_call_w;
        pred_event_is_ret_q <= pred_fire_w && pred_slot_is_ret_w;
        pred_event_pc_q <= pred_slot_pc_w;
      end
    end
  end
endmodule : bpu
