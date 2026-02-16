import global_config_pkg::*;
module bpu #(
    parameter config_pkg::cfg_t Cfg = config_pkg::EmptyCfg,
    parameter int unsigned BTB_ENTRIES = 64,
    parameter int unsigned BHT_ENTRIES = 128
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

    // from IFU
    output handshake_t  bpu_to_ifu_handshake_o,
    output bpu_to_ifu_t bpu_to_ifu_o
);

  localparam int unsigned SLOT_IDX_W = (Cfg.INSTR_PER_FETCH > 1) ? $clog2(Cfg.INSTR_PER_FETCH) : 1;
  localparam int unsigned BTB_IDX_W = (BTB_ENTRIES > 1) ? $clog2(BTB_ENTRIES) : 1;
  localparam int unsigned BHT_IDX_W = (BHT_ENTRIES > 1) ? $clog2(BHT_ENTRIES) : 1;
  localparam int unsigned INSTR_BYTES = Cfg.ILEN / 8;
  localparam int unsigned BTB_TAG_W = Cfg.PLEN - BTB_IDX_W - 2;

  logic [BTB_ENTRIES-1:0] btb_valid_q;
  logic [BTB_ENTRIES-1:0] btb_is_cond_q;
  logic [BTB_ENTRIES-1:0][BTB_TAG_W-1:0] btb_tag_q;
  logic [BTB_ENTRIES-1:0][Cfg.PLEN-1:0] btb_target_q;
  logic [BHT_ENTRIES-1:0][1:0] bht_q;

  function automatic logic [BTB_IDX_W-1:0] btb_index(input logic [Cfg.PLEN-1:0] pc);
    btb_index = pc[2 +: BTB_IDX_W];
  endfunction

  function automatic logic [BTB_TAG_W-1:0] btb_tag(input logic [Cfg.PLEN-1:0] pc);
    btb_tag = pc[Cfg.PLEN-1:2+BTB_IDX_W];
  endfunction

  function automatic logic [BHT_IDX_W-1:0] bht_index(input logic [Cfg.PLEN-1:0] pc);
    bht_index = pc[2+:BHT_IDX_W];
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
  logic [Cfg.INSTR_PER_FETCH-1:0][Cfg.PLEN-1:0] predict_pc;
  logic [Cfg.INSTR_PER_FETCH-1:0][Cfg.PLEN-1:0] predict_target;
  logic [SLOT_IDX_W-1:0] pred_slot_idx_w;
  logic pred_slot_valid_w;
  logic [Cfg.PLEN-1:0] pred_slot_target_w;
  logic [Cfg.PLEN-1:0] pred_npc_w;

  always_comb begin
    for (int i = 0; i < Cfg.INSTR_PER_FETCH; i++) begin
      logic [BTB_IDX_W-1:0] idx;
      logic [BHT_IDX_W-1:0] bht_idx;
      logic [Cfg.PLEN-1:0] slot_pc;
      slot_pc = ifu_to_bpu_i.pc + Cfg.PLEN'(INSTR_BYTES * i);
      idx = btb_index(slot_pc);
      bht_idx = bht_index(slot_pc);

      predict_pc[i] = slot_pc;
      predict_target[i] = btb_target_q[idx];
      predict_hit[i] = btb_valid_q[idx] && (btb_tag_q[idx] == btb_tag(slot_pc));

      predict_taken[i] = 1'b0;
      if (predict_hit[i]) begin
        if (!btb_is_cond_q[idx]) begin
          predict_taken[i] = 1'b1;
        end else begin
          predict_taken[i] = bht_q[bht_idx][1];
        end
      end
    end
  end

  always_comb begin
    pred_slot_valid_w = 1'b0;
    pred_slot_idx_w = '0;
    pred_slot_target_w = '0;
    for (int i = 0; i < Cfg.INSTR_PER_FETCH; i++) begin
      if (!pred_slot_valid_w && predict_taken[i]) begin
        pred_slot_valid_w = 1'b1;
        pred_slot_idx_w = SLOT_IDX_W'(i);
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
      btb_tag_q     <= '0;
      btb_target_q  <= '0;
      for (int i = 0; i < BHT_ENTRIES; i++) begin
        bht_q[i] <= 2'b01;
      end
    end else if (update_valid_i) begin
      logic [BTB_IDX_W-1:0] up_btb_idx;
      logic [BHT_IDX_W-1:0] up_bht_idx;
      logic do_btb_write;
      up_btb_idx = btb_index(update_pc_i);
      up_bht_idx = bht_index(update_pc_i);
      do_btb_write = (!update_is_cond_i) || update_taken_i;

      if (do_btb_write) begin
        btb_valid_q[up_btb_idx] <= 1'b1;
        btb_is_cond_q[up_btb_idx] <= update_is_cond_i;
        btb_tag_q[up_btb_idx] <= btb_tag(update_pc_i);
        btb_target_q[up_btb_idx] <= update_target_i;
      end

      if (update_is_cond_i) begin
        if (update_taken_i) begin
          bht_q[up_bht_idx] <= sat_inc(bht_q[up_bht_idx]);
        end else begin
          bht_q[up_bht_idx] <= sat_dec(bht_q[up_bht_idx]);
        end
      end else begin
        bht_q[up_bht_idx] <= 2'b11;
      end
    end
  end
endmodule : bpu
