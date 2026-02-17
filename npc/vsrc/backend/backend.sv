import config_pkg::*;
import decode_pkg::*;

module backend #(
    parameter config_pkg::cfg_t Cfg = config_pkg::EmptyCfg
) (
    input logic clk_i,
    input logic rst_ni,
    input logic flush_from_backend,
    input logic frontend_ibuf_valid,
    output logic frontend_ibuf_ready,
    input logic [Cfg.INSTR_PER_FETCH-1:0][Cfg.ILEN-1:0] frontend_ibuf_instrs,
    input logic [Cfg.PLEN-1:0] frontend_ibuf_pc,
    input logic [Cfg.INSTR_PER_FETCH-1:0] frontend_ibuf_slot_valid,
    input logic [Cfg.INSTR_PER_FETCH-1:0][Cfg.PLEN-1:0] frontend_ibuf_pred_npc,
    // Redirect/flush to frontend
    output logic backend_flush_o,
    output logic [Cfg.PLEN-1:0] backend_redirect_pc_o,
    output logic bpu_update_valid_o,
    output logic [Cfg.PLEN-1:0] bpu_update_pc_o,
    output logic bpu_update_is_cond_o,
    output logic bpu_update_taken_o,
    output logic [Cfg.PLEN-1:0] bpu_update_target_o,
    output logic bpu_update_is_call_o,
    output logic bpu_update_is_ret_o,

    // D-Cache miss/refill/writeback interface (to memory system)
    output logic                                  dcache_miss_req_valid_o,
    input  logic                                  dcache_miss_req_ready_i,
    output logic [                  Cfg.PLEN-1:0] dcache_miss_req_paddr_o,
    output logic [Cfg.DCACHE_SET_ASSOC_WIDTH-1:0] dcache_miss_req_victim_way_o,
    output logic [    Cfg.DCACHE_INDEX_WIDTH-1:0] dcache_miss_req_index_o,

    input  logic                                  dcache_refill_valid_i,
    output logic                                  dcache_refill_ready_o,
    input  logic [                  Cfg.PLEN-1:0] dcache_refill_paddr_i,
    input  logic [Cfg.DCACHE_SET_ASSOC_WIDTH-1:0] dcache_refill_way_i,
    input  logic [     Cfg.DCACHE_LINE_WIDTH-1:0] dcache_refill_data_i,

    output logic                             dcache_wb_req_valid_o,
    input  logic                             dcache_wb_req_ready_i,
    output logic [             Cfg.PLEN-1:0] dcache_wb_req_paddr_o,
    output logic [Cfg.DCACHE_LINE_WIDTH-1:0] dcache_wb_req_data_o
);

  localparam int unsigned DISPATCH_WIDTH = Cfg.INSTR_PER_FETCH;
  localparam int unsigned COMMIT_WIDTH = Cfg.NRET;
  localparam int unsigned ROB_DEPTH = 64;
  localparam int unsigned ROB_IDX_WIDTH = $clog2(ROB_DEPTH);
  localparam int unsigned SB_DEPTH = 16;
  localparam int unsigned SB_IDX_WIDTH = $clog2(SB_DEPTH);
  localparam int unsigned RS_DEPTH = Cfg.RS_DEPTH;
  localparam int unsigned WB_WIDTH = 7;
  localparam int unsigned NUM_FUS = 7;  // ALU0, ALU1, BRU, LSU, ALU2, ALU3, CSR
  // Commit-time call/ret update 对短函数场景延迟过大，暂默认关闭，后续以低延迟链路重启。
  localparam bit ENABLE_COMMIT_RAS_UPDATE = 1'b0;

  // =========================================================
  // IBuffer
  // =========================================================
  logic decode_ibuf_valid;
  logic decode_ibuf_ready;
  logic [Cfg.INSTR_PER_FETCH-1:0][Cfg.ILEN-1:0] decode_ibuf_instrs;
  logic [Cfg.INSTR_PER_FETCH-1:0][Cfg.PLEN-1:0] decode_ibuf_pcs;
  logic [Cfg.INSTR_PER_FETCH-1:0] decode_ibuf_slot_valid;
  logic [Cfg.INSTR_PER_FETCH-1:0][Cfg.PLEN-1:0] decode_ibuf_pred_npc;

  logic backend_flush;

  ibuffer #(
      .Cfg         (Cfg),
      .IB_DEPTH    (16),
      .DECODE_WIDTH(Cfg.INSTR_PER_FETCH)
  ) u_ibuffer (
      .clk_i (clk_i),
      .rst_ni(rst_ni),

      .fe_valid_i     (frontend_ibuf_valid),
      .fe_ready_o     (frontend_ibuf_ready),
      .fe_instrs_i    (frontend_ibuf_instrs),
      .fe_pc_i        (frontend_ibuf_pc),
      .fe_slot_valid_i(frontend_ibuf_slot_valid),
      .fe_pred_npc_i  (frontend_ibuf_pred_npc),

      .ibuf_valid_o (decode_ibuf_valid),
      .ibuf_ready_i (decode_ibuf_ready),
      .ibuf_instrs_o(decode_ibuf_instrs),
      .ibuf_pcs_o   (decode_ibuf_pcs),
      .ibuf_slot_valid_o(decode_ibuf_slot_valid),
      .ibuf_pred_npc_o(decode_ibuf_pred_npc),

      .flush_i(backend_flush)
  );

  // =========================================================
  // Decoder
  // =========================================================
  logic dec_valid;
  logic [DISPATCH_WIDTH-1:0] dec_slot_valid;
  decode_pkg::uop_t [DISPATCH_WIDTH-1:0] dec_uops;

  decoder #(
      .Cfg(Cfg),
      .DECODE_WIDTH(DISPATCH_WIDTH)
  ) u_decoder (
      .clk_i (clk_i),
      .rst_ni(rst_ni),

      .ibuf2dec_valid_i (decode_ibuf_valid),
      .dec2ibuf_ready_o (decode_ibuf_ready),
      .ibuf_instrs_i    (decode_ibuf_instrs),
      .ibuf_pcs_i       (decode_ibuf_pcs),
      .ibuf_slot_valid_i(decode_ibuf_slot_valid),
      .ibuf_pred_npc_i  (decode_ibuf_pred_npc),

      .dec2backend_valid_o(dec_valid),
      .backend2dec_ready_i(rename_ready),
      .dec_slot_valid_o   (dec_slot_valid),
      .dec_uops_o         (dec_uops)
  );

  // =========================================================
  // ROB
  // =========================================================
  logic                                           rob_ready;
  logic [  DISPATCH_WIDTH-1:0][ROB_IDX_WIDTH-1:0] rob_dispatch_rob_index;

  logic [    COMMIT_WIDTH-1:0]                    commit_valid;
  logic [    COMMIT_WIDTH-1:0][     Cfg.PLEN-1:0] commit_pc;
  logic [    COMMIT_WIDTH-1:0]                    commit_we;
  logic [    COMMIT_WIDTH-1:0][              4:0] commit_areg;
  logic [    COMMIT_WIDTH-1:0][     Cfg.XLEN-1:0] commit_wdata;
  logic [    COMMIT_WIDTH-1:0][ROB_IDX_WIDTH-1:0] commit_rob_index;
  logic [    COMMIT_WIDTH-1:0]                    commit_is_store;
  logic [    COMMIT_WIDTH-1:0][ SB_IDX_WIDTH-1:0] commit_sb_id;
  logic [    COMMIT_WIDTH-1:0]                    commit_is_branch;
  logic [    COMMIT_WIDTH-1:0]                    commit_is_jump;
  logic [    COMMIT_WIDTH-1:0]                    commit_is_call;
  logic [    COMMIT_WIDTH-1:0]                    commit_is_ret;
  logic [    COMMIT_WIDTH-1:0][     Cfg.PLEN-1:0] commit_actual_npc;

  logic                                           rob_flush;
  logic [        Cfg.PLEN-1:0]                    rob_flush_pc;
  logic [                 4:0]                    rob_flush_cause;
  logic                                           rob_flush_is_mispred;
  logic                                           rob_flush_is_exception;
  logic                                           rob_flush_is_branch;
  logic                                           rob_flush_is_jump;
  logic [        Cfg.PLEN-1:0]                    rob_flush_src_pc;

  // ROB operand query (late subscription fix)
  logic [DISPATCH_WIDTH*2-1:0][ROB_IDX_WIDTH-1:0] rob_query_idx;
  logic [DISPATCH_WIDTH*2-1:0]                    rob_query_ready;
  logic [DISPATCH_WIDTH*2-1:0][     Cfg.XLEN-1:0] rob_query_data;
  logic [   ROB_IDX_WIDTH-1:0]                    rob_head_ptr;

  rob #(
      .Cfg(Cfg),
      .ROB_DEPTH(ROB_DEPTH),
      .DISPATCH_WIDTH(DISPATCH_WIDTH),
      .COMMIT_WIDTH(COMMIT_WIDTH),
      .WB_WIDTH(WB_WIDTH),
      .QUERY_WIDTH(DISPATCH_WIDTH * 2),
      .SB_DEPTH(SB_DEPTH)
  ) u_rob (
      .clk_i (clk_i),
      .rst_ni(rst_ni),

      .dispatch_valid_i(rob_dispatch_valid),
      .dispatch_pc_i   (rob_dispatch_pc),
      .dispatch_fu_type_i(rob_dispatch_fu_type),
      .dispatch_areg_i (rob_dispatch_areg),
      .dispatch_has_rd_i(rob_dispatch_has_rd),
      .dispatch_is_branch_i(rob_dispatch_is_branch),
      .dispatch_is_jump_i(rob_dispatch_is_jump),
      .dispatch_is_call_i(rob_dispatch_is_call),
      .dispatch_is_ret_i(rob_dispatch_is_ret),
      .dispatch_is_store_i(rob_dispatch_is_store),
      .dispatch_sb_id_i(rob_dispatch_sb_id),

      .rob_ready_o(rob_ready),
      .dispatch_rob_index_o(rob_dispatch_rob_index),

      .wb_valid_i      (wb_valid),
      .wb_rob_index_i  (wb_rob_idx),
      .wb_data_i       (wb_data),
      .wb_exception_i  (wb_exception),
      .wb_ecause_i     (wb_ecause),
      .wb_is_mispred_i (wb_is_mispred),
      .wb_redirect_pc_i(wb_redirect_pc),

      .commit_valid_o     (commit_valid),
      .commit_pc_o        (commit_pc),
      .commit_we_o        (commit_we),
      .commit_areg_o      (commit_areg),
      .commit_wdata_o     (commit_wdata),
      .commit_rob_index_o (commit_rob_index),
      .commit_is_store_o  (commit_is_store),
      .commit_sb_id_o     (commit_sb_id),
      .commit_is_branch_o (commit_is_branch),
      .commit_is_jump_o   (commit_is_jump),
      .commit_is_call_o   (commit_is_call),
      .commit_is_ret_o    (commit_is_ret),
      .commit_actual_npc_o(commit_actual_npc),

      .flush_o             (rob_flush),
      .flush_pc_o          (rob_flush_pc),
      .flush_cause_o       (rob_flush_cause),
      .flush_is_mispred_o  (rob_flush_is_mispred),
      .flush_is_exception_o(rob_flush_is_exception),
      .flush_is_branch_o   (rob_flush_is_branch),
      .flush_is_jump_o     (rob_flush_is_jump),
      .flush_src_pc_o      (rob_flush_src_pc),

      .query_rob_idx_i(rob_query_idx),
      .query_ready_o  (rob_query_ready),
      .query_data_o   (rob_query_data),

      .rob_empty_o(),
      .rob_full_o (),
      .rob_head_o (rob_head_ptr)
  );

  assign backend_flush = flush_from_backend | rob_flush;
  assign backend_flush_o = backend_flush;
  assign backend_redirect_pc_o = rob_flush_pc;

  always_comb begin
    bpu_update_valid_o = 1'b0;
    bpu_update_pc_o = '0;
    bpu_update_is_cond_o = 1'b0;
    bpu_update_taken_o = 1'b0;
    bpu_update_target_o = '0;
    bpu_update_is_call_o = 1'b0;
    bpu_update_is_ret_o = 1'b0;

    for (int i = 0; i < COMMIT_WIDTH; i++) begin
      logic [Cfg.PLEN-1:0] fallthrough_pc;
      fallthrough_pc = commit_pc[i] + Cfg.PLEN'(4);
      if (!bpu_update_valid_o && commit_valid[i] && commit_is_branch[i]) begin
        bpu_update_valid_o = 1'b1;
        bpu_update_pc_o = commit_pc[i];
        bpu_update_is_cond_o = !commit_is_jump[i];
        bpu_update_taken_o = commit_is_jump[i] ? 1'b1 : (commit_actual_npc[i] != fallthrough_pc);
        bpu_update_target_o = commit_actual_npc[i];
        bpu_update_is_call_o = ENABLE_COMMIT_RAS_UPDATE ? commit_is_call[i] : 1'b0;
        bpu_update_is_ret_o = ENABLE_COMMIT_RAS_UPDATE ? commit_is_ret[i] : 1'b0;
      end
    end
  end

  // =========================================================
  // Store Buffer (allocation + commit + forwarding)
  // =========================================================
  logic [3:0] sb_alloc_req;
  logic sb_alloc_ready;
  logic [3:0][SB_IDX_WIDTH-1:0] sb_alloc_id;
  logic sb_alloc_fire;

  // Store buffer -> D$ store port
  logic sb_dcache_req_valid;
  logic sb_dcache_req_ready;
  logic [Cfg.PLEN-1:0] sb_dcache_req_addr;
  logic [Cfg.XLEN-1:0] sb_dcache_req_data;
  decode_pkg::lsu_op_e sb_dcache_req_op;

  logic [COMMIT_WIDTH-1:0] sb_commit_valid;
  logic [COMMIT_WIDTH-1:0][SB_IDX_WIDTH-1:0] sb_commit_id;

  always_comb begin
    for (int i = 0; i < COMMIT_WIDTH; i++) begin
      sb_commit_valid[i] = commit_valid[i] && commit_is_store[i];
      sb_commit_id[i]    = commit_sb_id[i];
    end
  end

  // LSU <-> Store Buffer
  logic sb_ex_valid;
  logic [SB_IDX_WIDTH-1:0] sb_ex_sb_id;
  logic [Cfg.PLEN-1:0] sb_ex_addr;
  logic [Cfg.XLEN-1:0] sb_ex_data;
  decode_pkg::lsu_op_e sb_ex_op;
  logic [ROB_IDX_WIDTH-1:0] sb_ex_rob_idx;

  logic [Cfg.PLEN-1:0] sb_load_addr;
  logic [ROB_IDX_WIDTH-1:0] sb_load_rob_idx;
  logic sb_load_hit;
  logic [Cfg.XLEN-1:0] sb_load_data;

  store_buffer #(
      .SB_DEPTH     (SB_DEPTH),
      .ROB_IDX_WIDTH(ROB_IDX_WIDTH),
      .COMMIT_WIDTH (COMMIT_WIDTH)
  ) u_sb (
      .clk_i (clk_i),
      .rst_ni(rst_ni),

      .alloc_req_i(sb_alloc_req),
      .alloc_ready_o(sb_alloc_ready),
      .alloc_id_o(sb_alloc_id),
      .alloc_fire_i(sb_alloc_fire),

      .ex_valid_i  (sb_ex_valid),
      .ex_sb_id_i  (sb_ex_sb_id),
      .ex_addr_i   (sb_ex_addr),
      .ex_data_i   (sb_ex_data),
      .ex_op_i     (sb_ex_op),
      .ex_rob_idx_i(sb_ex_rob_idx),

      .commit_valid_i(sb_commit_valid),
      .commit_sb_id_i(sb_commit_id),

      .dcache_req_valid_o(sb_dcache_req_valid),
      .dcache_req_ready_i(sb_dcache_req_ready),
      .dcache_req_addr_o (sb_dcache_req_addr),
      .dcache_req_data_o (sb_dcache_req_data),
      .dcache_req_op_o   (sb_dcache_req_op),

      .load_addr_i(sb_load_addr),
      .load_rob_idx_i(sb_load_rob_idx),
      .load_hit_o(sb_load_hit),
      .load_data_o(sb_load_data),

      .rob_head_i(rob_head_ptr),

      .flush_i(backend_flush)
  );

  // =========================================================
  // Rename
  // =========================================================
  logic                                                    rename_ready;

  logic            [DISPATCH_WIDTH-1:0]                    rob_dispatch_valid;
  logic            [DISPATCH_WIDTH-1:0][     Cfg.PLEN-1:0] rob_dispatch_pc;
  decode_pkg::fu_e [DISPATCH_WIDTH-1:0]                    rob_dispatch_fu_type;
  logic            [DISPATCH_WIDTH-1:0][              4:0] rob_dispatch_areg;
  logic            [DISPATCH_WIDTH-1:0]                    rob_dispatch_has_rd;
  logic            [DISPATCH_WIDTH-1:0]                    rob_dispatch_is_branch;
  logic            [DISPATCH_WIDTH-1:0]                    rob_dispatch_is_jump;
  logic            [DISPATCH_WIDTH-1:0]                    rob_dispatch_is_call;
  logic            [DISPATCH_WIDTH-1:0]                    rob_dispatch_is_ret;
  logic            [DISPATCH_WIDTH-1:0]                    rob_dispatch_is_store;
  logic            [DISPATCH_WIDTH-1:0][ SB_IDX_WIDTH-1:0] rob_dispatch_sb_id;

  logic            [DISPATCH_WIDTH-1:0]                    issue_valid;
  logic            [DISPATCH_WIDTH-1:0]                    issue_rs1_in_rob;
  logic            [DISPATCH_WIDTH-1:0][ROB_IDX_WIDTH-1:0] issue_rs1_rob_idx;
  logic            [DISPATCH_WIDTH-1:0][              4:0] issue_rs1_idx;

  logic            [DISPATCH_WIDTH-1:0]                    issue_rs2_in_rob;
  logic            [DISPATCH_WIDTH-1:0][ROB_IDX_WIDTH-1:0] issue_rs2_rob_idx;
  logic            [DISPATCH_WIDTH-1:0][              4:0] issue_rs2_idx;

  logic            [DISPATCH_WIDTH-1:0][ROB_IDX_WIDTH-1:0] issue_rd_rob_idx;

  logic                                                    rob_ready_gated;
  logic            [DISPATCH_WIDTH-1:0]                    rs1_tag_allocated;
  logic            [DISPATCH_WIDTH-1:0]                    rs2_tag_allocated;

  rename #(
      .Cfg(Cfg),
      .ROB_DEPTH(ROB_DEPTH),
      .SB_DEPTH(SB_DEPTH)
  ) u_rename (
      .clk_i (clk_i),
      .rst_ni(rst_ni),

      .dec_valid_i(dec_slot_valid),
      .dec_uops_i(dec_uops),
      .rename_ready_o(rename_ready),

      .rob_dispatch_valid_o(rob_dispatch_valid),
      .rob_dispatch_pc_o   (rob_dispatch_pc),
      .rob_dispatch_fu_type_o(rob_dispatch_fu_type),
      .rob_dispatch_areg_o (rob_dispatch_areg),
      .rob_dispatch_has_rd_o(rob_dispatch_has_rd),
      .rob_dispatch_is_branch_o(rob_dispatch_is_branch),
      .rob_dispatch_is_jump_o(rob_dispatch_is_jump),
      .rob_dispatch_is_call_o(rob_dispatch_is_call),
      .rob_dispatch_is_ret_o(rob_dispatch_is_ret),
      .rob_dispatch_is_store_o(rob_dispatch_is_store),
      .rob_dispatch_sb_id_o(rob_dispatch_sb_id),

      .rob_ready_i   (rob_ready_gated),
      .rob_tail_ptr_i(rob_dispatch_rob_index[0]),

      .sb_alloc_req_o(sb_alloc_req),
      .sb_alloc_ready_i(sb_alloc_ready),
      .sb_alloc_id_i(sb_alloc_id),

      .issue_valid_o      (issue_valid),
      .issue_rs1_in_rob_o (issue_rs1_in_rob),
      .issue_rs1_rob_idx_o(issue_rs1_rob_idx),
      .issue_rs1_idx_o    (issue_rs1_idx),
      .issue_rs2_in_rob_o (issue_rs2_in_rob),
      .issue_rs2_rob_idx_o(issue_rs2_rob_idx),
      .issue_rs2_idx_o    (issue_rs2_idx),
      .issue_rd_rob_idx_o (issue_rd_rob_idx),

      .commit_valid_i  (commit_valid),
      .commit_areg_i   (commit_areg),
      .commit_rob_idx_i(commit_rob_index),

      .flush_i(backend_flush)
  );

  // Store Buffer allocation fires only when rename accepts the bundle.
  assign sb_alloc_fire = rename_ready && (|sb_alloc_req);

  // =========================================================
  // ARF (8 read ports)
  // =========================================================
  logic [7:0][4:0] arf_raddr;
  logic [7:0][Cfg.XLEN-1:0] arf_rdata;

  arf #(
      .Cfg(Cfg),
      .COMMIT_WIDTH(COMMIT_WIDTH)
  ) u_arf (
      .clk_i (clk_i),
      .rst_ni(rst_ni),

      .we_i   (commit_we),
      .waddr_i(commit_areg),
      .wdata_i(commit_wdata),

      .raddr_i(arf_raddr),
      .rdata_o(arf_rdata)
  );

  // =========================================================
  // Operand Read (from ARF) + Tagging
  // =========================================================
  logic [DISPATCH_WIDTH-1:0][Cfg.XLEN-1:0] issue_v1;
  logic [DISPATCH_WIDTH-1:0][Cfg.XLEN-1:0] issue_v2;
  logic [DISPATCH_WIDTH-1:0][ROB_IDX_WIDTH-1:0] issue_q1;
  logic [DISPATCH_WIDTH-1:0][ROB_IDX_WIDTH-1:0] issue_q2;
  logic [DISPATCH_WIDTH-1:0] issue_r1;
  logic [DISPATCH_WIDTH-1:0] issue_r2;

  // Commit -> ARF read bypass (handles same-cycle commit/rename after flush)
  function automatic logic [Cfg.XLEN-1:0] arf_bypass(input logic [4:0] reg_idx,
                                                     input logic [Cfg.XLEN-1:0] arf_val);
    logic [Cfg.XLEN-1:0] val;
    begin
      val = arf_val;
      if (reg_idx != '0) begin
        for (int c = 0; c < COMMIT_WIDTH; c++) begin
          if (commit_we[c] && (commit_areg[c] == reg_idx)) begin
            val = commit_wdata[c];
          end
        end
      end
      return val;
    end
  endfunction

  always_comb begin
    // ARF read addresses
    for (int i = 0; i < DISPATCH_WIDTH; i++) begin
      arf_raddr[i]       = issue_rs1_idx[i];
      arf_raddr[i+4]     = issue_rs2_idx[i];
      rob_query_idx[i]   = issue_rs1_rob_idx[i];
      rob_query_idx[i+4] = issue_rs2_rob_idx[i];
    end

    // Detect if a source tag is allocated in the same dispatch cycle
    for (int i = 0; i < DISPATCH_WIDTH; i++) begin
      rs1_tag_allocated[i] = 1'b0;
      rs2_tag_allocated[i] = 1'b0;
      for (int j = 0; j < DISPATCH_WIDTH; j++) begin
        if (rob_dispatch_valid[j] && (issue_rs1_rob_idx[i] == rob_dispatch_rob_index[j])) begin
          rs1_tag_allocated[i] = 1'b1;
        end
        if (rob_dispatch_valid[j] && (issue_rs2_rob_idx[i] == rob_dispatch_rob_index[j])) begin
          rs2_tag_allocated[i] = 1'b1;
        end
      end
    end

    // Default outputs
    for (int i = 0; i < DISPATCH_WIDTH; i++) begin
      issue_v1[i] = '0;
      issue_v2[i] = '0;
      issue_q1[i] = '0;
      issue_q2[i] = '0;
      issue_r1[i] = 1'b0;
      issue_r2[i] = 1'b0;

      if (issue_valid[i]) begin
        if (issue_rs1_in_rob[i]) begin
          if (rob_query_ready[i] && !rs1_tag_allocated[i]) begin
            issue_r1[i] = 1'b1;
            issue_v1[i] = rob_query_data[i];
          end else begin
            issue_r1[i] = 1'b0;
            issue_q1[i] = issue_rs1_rob_idx[i];
          end
        end else begin
          issue_r1[i] = 1'b1;
          issue_v1[i] = arf_bypass(issue_rs1_idx[i], arf_rdata[i]);
        end

        if (issue_rs2_in_rob[i]) begin
          if (rob_query_ready[i+4] && !rs2_tag_allocated[i]) begin
            issue_r2[i] = 1'b1;
            issue_v2[i] = rob_query_data[i+4];
          end else begin
            issue_r2[i] = 1'b0;
            issue_q2[i] = issue_rs2_rob_idx[i];
          end
        end else begin
          issue_r2[i] = 1'b1;
          issue_v2[i] = arf_bypass(issue_rs2_idx[i], arf_rdata[i+4]);
        end
      end
    end
  end

  // =========================================================
  // FU Demux + Packing
  // =========================================================
  logic [2:0] alu_need_cnt;
  logic [2:0] bru_need_cnt;
  logic [2:0] lsu_need_cnt;
  logic [2:0] mdu_need_cnt;
  logic [2:0] csr_need_cnt;

  always_comb begin
    alu_need_cnt = 0;
    bru_need_cnt = 0;
    lsu_need_cnt = 0;
    mdu_need_cnt = 0;
    csr_need_cnt = 0;

    for (int i = 0; i < DISPATCH_WIDTH; i++) begin
      if (dec_slot_valid[i]) begin
        unique case (dec_uops[i].fu)
          FU_ALU:    alu_need_cnt++;
          FU_BRANCH: bru_need_cnt++;
          FU_LSU:    lsu_need_cnt++;
          FU_MUL,
          FU_DIV:    mdu_need_cnt++;
          FU_CSR:    csr_need_cnt++;
          default:   alu_need_cnt++;
        endcase
      end
    end
  end

  // Packed dispatch arrays per FU
  logic [3:0] alu_dispatch_valid;
  decode_pkg::uop_t alu_dispatch_op[0:3];
  logic [ROB_IDX_WIDTH-1:0] alu_dispatch_dst[0:3];
  logic [Cfg.XLEN-1:0] alu_dispatch_v1[0:3];
  logic [ROB_IDX_WIDTH-1:0] alu_dispatch_q1[0:3];
  logic alu_dispatch_r1[0:3];
  logic [Cfg.XLEN-1:0] alu_dispatch_v2[0:3];
  logic [ROB_IDX_WIDTH-1:0] alu_dispatch_q2[0:3];
  logic alu_dispatch_r2[0:3];

  logic [3:0] bru_dispatch_valid;
  decode_pkg::uop_t bru_dispatch_op[0:3];
  logic [ROB_IDX_WIDTH-1:0] bru_dispatch_dst[0:3];
  logic [Cfg.XLEN-1:0] bru_dispatch_v1[0:3];
  logic [ROB_IDX_WIDTH-1:0] bru_dispatch_q1[0:3];
  logic bru_dispatch_r1[0:3];
  logic [Cfg.XLEN-1:0] bru_dispatch_v2[0:3];
  logic [ROB_IDX_WIDTH-1:0] bru_dispatch_q2[0:3];
  logic bru_dispatch_r2[0:3];

  logic [3:0] lsu_dispatch_valid;
  decode_pkg::uop_t lsu_dispatch_op[0:3];
  logic [ROB_IDX_WIDTH-1:0] lsu_dispatch_dst[0:3];
  logic [Cfg.XLEN-1:0] lsu_dispatch_v1[0:3];
  logic [ROB_IDX_WIDTH-1:0] lsu_dispatch_q1[0:3];
  logic lsu_dispatch_r1[0:3];
  logic [Cfg.XLEN-1:0] lsu_dispatch_v2[0:3];
  logic [ROB_IDX_WIDTH-1:0] lsu_dispatch_q2[0:3];
  logic lsu_dispatch_r2[0:3];
  logic [SB_IDX_WIDTH-1:0] lsu_dispatch_sb_id[0:3];

  logic [3:0] csr_dispatch_valid;
  decode_pkg::uop_t csr_dispatch_op[0:3];
  logic [ROB_IDX_WIDTH-1:0] csr_dispatch_dst[0:3];
  logic [Cfg.XLEN-1:0] csr_dispatch_v1[0:3];
  logic [ROB_IDX_WIDTH-1:0] csr_dispatch_q1[0:3];
  logic csr_dispatch_r1[0:3];
  logic [Cfg.XLEN-1:0] csr_dispatch_v2[0:3];
  logic [ROB_IDX_WIDTH-1:0] csr_dispatch_q2[0:3];
  logic csr_dispatch_r2[0:3];

  always_comb begin
    int alu_k;
    int bru_k;
    int lsu_k;
    int csr_k;

    // init
    alu_dispatch_valid = '0;
    bru_dispatch_valid = '0;
    lsu_dispatch_valid = '0;
    csr_dispatch_valid = '0;

    for (int k = 0; k < 4; k++) begin
      alu_dispatch_op[k] = '0;
      alu_dispatch_dst[k] = '0;
      alu_dispatch_v1[k] = '0;
      alu_dispatch_q1[k] = '0;
      alu_dispatch_r1[k] = 1'b0;
      alu_dispatch_v2[k] = '0;
      alu_dispatch_q2[k] = '0;
      alu_dispatch_r2[k] = 1'b0;

      bru_dispatch_op[k] = '0;
      bru_dispatch_dst[k] = '0;
      bru_dispatch_v1[k] = '0;
      bru_dispatch_q1[k] = '0;
      bru_dispatch_r1[k] = 1'b0;
      bru_dispatch_v2[k] = '0;
      bru_dispatch_q2[k] = '0;
      bru_dispatch_r2[k] = 1'b0;

      lsu_dispatch_op[k] = '0;
      lsu_dispatch_dst[k] = '0;
      lsu_dispatch_v1[k] = '0;
      lsu_dispatch_q1[k] = '0;
      lsu_dispatch_r1[k] = 1'b0;
      lsu_dispatch_v2[k] = '0;
      lsu_dispatch_q2[k] = '0;
      lsu_dispatch_r2[k] = 1'b0;
      lsu_dispatch_sb_id[k] = '0;

      csr_dispatch_op[k] = '0;
      csr_dispatch_dst[k] = '0;
      csr_dispatch_v1[k] = '0;
      csr_dispatch_q1[k] = '0;
      csr_dispatch_r1[k] = 1'b0;
      csr_dispatch_v2[k] = '0;
      csr_dispatch_q2[k] = '0;
      csr_dispatch_r2[k] = 1'b0;
    end

    alu_k = 0;
    bru_k = 0;
    lsu_k = 0;
    csr_k = 0;

    for (int i = 0; i < DISPATCH_WIDTH; i++) begin
      if (issue_valid[i]) begin
        unique case (dec_uops[i].fu)
          FU_ALU: begin
            alu_dispatch_valid[alu_k] = 1'b1;
            alu_dispatch_op[alu_k]    = dec_uops[i];
            alu_dispatch_dst[alu_k]   = issue_rd_rob_idx[i];
            alu_dispatch_v1[alu_k]    = issue_v1[i];
            alu_dispatch_q1[alu_k]    = issue_q1[i];
            alu_dispatch_r1[alu_k]    = issue_r1[i];
            alu_dispatch_v2[alu_k]    = issue_v2[i];
            alu_dispatch_q2[alu_k]    = issue_q2[i];
            alu_dispatch_r2[alu_k]    = issue_r2[i];
            alu_k++;
          end
          FU_BRANCH: begin
            bru_dispatch_valid[bru_k] = 1'b1;
            bru_dispatch_op[bru_k]    = dec_uops[i];
            bru_dispatch_dst[bru_k]   = issue_rd_rob_idx[i];
            bru_dispatch_v1[bru_k]    = issue_v1[i];
            bru_dispatch_q1[bru_k]    = issue_q1[i];
            bru_dispatch_r1[bru_k]    = issue_r1[i];
            bru_dispatch_v2[bru_k]    = issue_v2[i];
            bru_dispatch_q2[bru_k]    = issue_q2[i];
            bru_dispatch_r2[bru_k]    = issue_r2[i];
            bru_k++;
          end
          FU_LSU: begin
            lsu_dispatch_valid[lsu_k] = 1'b1;
            lsu_dispatch_op[lsu_k]    = dec_uops[i];
            lsu_dispatch_dst[lsu_k]   = issue_rd_rob_idx[i];
            lsu_dispatch_v1[lsu_k]    = issue_v1[i];
            lsu_dispatch_q1[lsu_k]    = issue_q1[i];
            lsu_dispatch_r1[lsu_k]    = issue_r1[i];
            lsu_dispatch_v2[lsu_k]    = issue_v2[i];
            lsu_dispatch_q2[lsu_k]    = issue_q2[i];
            lsu_dispatch_r2[lsu_k]    = issue_r2[i];
            lsu_dispatch_sb_id[lsu_k] = rob_dispatch_sb_id[i];

            lsu_k++;
          end
          FU_CSR: begin
            csr_dispatch_valid[csr_k] = 1'b1;
            csr_dispatch_op[csr_k]    = dec_uops[i];
            csr_dispatch_dst[csr_k]   = issue_rd_rob_idx[i];
            csr_dispatch_v1[csr_k]    = issue_v1[i];
            csr_dispatch_q1[csr_k]    = issue_q1[i];
            csr_dispatch_r1[csr_k]    = issue_r1[i];
            csr_dispatch_v2[csr_k]    = issue_v2[i];
            csr_dispatch_q2[csr_k]    = issue_q2[i];
            csr_dispatch_r2[csr_k]    = issue_r2[i];
            csr_k++;
          end
          default: begin
            alu_dispatch_valid[alu_k] = 1'b1;
            alu_dispatch_op[alu_k]    = dec_uops[i];
            alu_dispatch_dst[alu_k]   = issue_rd_rob_idx[i];
            alu_dispatch_v1[alu_k]    = issue_v1[i];
            alu_dispatch_q1[alu_k]    = issue_q1[i];
            alu_dispatch_r1[alu_k]    = issue_r1[i];
            alu_dispatch_v2[alu_k]    = issue_v2[i];
            alu_dispatch_q2[alu_k]    = issue_q2[i];
            alu_dispatch_r2[alu_k]    = issue_r2[i];
            alu_k++;
          end
        endcase
      end
    end
  end

  // =========================================================
  // Issue Queues
  // =========================================================
  logic [$clog2(RS_DEPTH+1)-1:0] alu_free_count;
  logic [$clog2(RS_DEPTH+1)-1:0] bru_free_count;
  logic [$clog2(RS_DEPTH+1)-1:0] lsu_free_count;
  logic [$clog2(RS_DEPTH+1)-1:0] csr_free_count;

  logic alu_issue_ready;
  logic bru_issue_ready;
  logic lsu_issue_ready;
  logic csr_issue_ready;

  // CDB broadcast
  logic [WB_WIDTH-1:0] cdb_valid;
  logic [ROB_IDX_WIDTH-1:0] cdb_tag[0:WB_WIDTH-1];
  logic [Cfg.XLEN-1:0] cdb_val[0:WB_WIDTH-1];

  issue #(
      .Cfg   (Cfg),
      .RS_DEPTH(RS_DEPTH),
      .DATA_W(Cfg.XLEN),
      .TAG_W (ROB_IDX_WIDTH),
      .CDB_W (WB_WIDTH)
  ) u_issue_alu (
      .clk(clk_i),
      .rst_n(rst_ni),
      .flush_i(backend_flush),

      .dispatch_valid(alu_dispatch_valid),
      .dispatch_op   (alu_dispatch_op),
      .dispatch_dst  (alu_dispatch_dst),
      .dispatch_v1   (alu_dispatch_v1),
      .dispatch_q1   (alu_dispatch_q1),
      .dispatch_r1   (alu_dispatch_r1),
      .dispatch_v2   (alu_dispatch_v2),
      .dispatch_q2   (alu_dispatch_q2),
      .dispatch_r2   (alu_dispatch_r2),

      .issue_ready (alu_issue_ready),
      .free_count_o(alu_free_count),

      .cdb_valid(cdb_valid),
      .cdb_tag  (cdb_tag),
      .cdb_val  (cdb_val),

      .alu0_en (alu0_en),
      .alu0_uop(alu0_uop),
      .alu0_v1 (alu0_v1),
      .alu0_v2 (alu0_v2),
      .alu0_dst(alu0_dst),

      .alu1_en (alu1_en),
      .alu1_uop(alu1_uop),
      .alu1_v1 (alu1_v1),
      .alu1_v2 (alu1_v2),
      .alu1_dst(alu1_dst),

      .alu2_en (alu2_en),
      .alu2_uop(alu2_uop),
      .alu2_v1 (alu2_v1),
      .alu2_v2 (alu2_v2),
      .alu2_dst(alu2_dst),

      .alu3_en (alu3_en),
      .alu3_uop(alu3_uop),
      .alu3_v1 (alu3_v1),
      .alu3_v2 (alu3_v2),
      .alu3_dst(alu3_dst)
  );

  issue_single #(
      .Cfg   (Cfg),
      .RS_DEPTH(RS_DEPTH),
      .DATA_W(Cfg.XLEN),
      .TAG_W (ROB_IDX_WIDTH),
      .CDB_W (WB_WIDTH)
  ) u_issue_bru (
      .clk(clk_i),
      .rst_n(rst_ni),
      .flush_i(backend_flush),
      .head_en_i(1'b0),
      .head_tag_i('0),

      .dispatch_valid(bru_dispatch_valid),
      .dispatch_op   (bru_dispatch_op),
      .dispatch_dst  (bru_dispatch_dst),
      .dispatch_v1   (bru_dispatch_v1),
      .dispatch_q1   (bru_dispatch_q1),
      .dispatch_r1   (bru_dispatch_r1),
      .dispatch_v2   (bru_dispatch_v2),
      .dispatch_q2   (bru_dispatch_q2),
      .dispatch_r2   (bru_dispatch_r2),

      .issue_ready (bru_issue_ready),
      .free_count_o(bru_free_count),

      .cdb_valid(cdb_valid),
      .cdb_tag  (cdb_tag),
      .cdb_val  (cdb_val),

      .fu_en (bru_en),
      .fu_uop(bru_uop),
      .fu_v1 (bru_v1),
      .fu_v2 (bru_v2),
      .fu_dst(bru_dst)
  );

  issue_lsu #(
      .Cfg   (Cfg),
      .RS_DEPTH(RS_DEPTH),
      .DATA_W(Cfg.XLEN),
      .TAG_W (ROB_IDX_WIDTH),
      .CDB_W (WB_WIDTH),
      .SB_W  (SB_IDX_WIDTH)
  ) u_issue_lsu (
      .clk(clk_i),
      .rst_n(rst_ni),
      .flush_i(backend_flush),

      .dispatch_valid(lsu_dispatch_valid),
      .dispatch_op   (lsu_dispatch_op),
      .dispatch_dst  (lsu_dispatch_dst),
      .dispatch_v1   (lsu_dispatch_v1),
      .dispatch_q1   (lsu_dispatch_q1),
      .dispatch_r1   (lsu_dispatch_r1),
      .dispatch_v2   (lsu_dispatch_v2),
      .dispatch_q2   (lsu_dispatch_q2),
      .dispatch_r2   (lsu_dispatch_r2),
      .dispatch_sb_id(lsu_dispatch_sb_id),

      .rob_head_i(rob_head_ptr),

      .fu_ready_i(lsu_req_ready),

      .issue_ready (lsu_issue_ready),
      .free_count_o(lsu_free_count),

      .cdb_valid(cdb_valid),
      .cdb_tag  (cdb_tag),
      .cdb_val  (cdb_val),

      .lsu_en   (lsu_en),
      .lsu_uop  (lsu_uop),
      .lsu_v1   (lsu_v1),
      .lsu_v2   (lsu_v2),
      .lsu_dst  (lsu_dst),
      .lsu_sb_id(lsu_sb_id)
  );

  issue_single #(
      .Cfg   (Cfg),
      .RS_DEPTH(RS_DEPTH),
      .DATA_W(Cfg.XLEN),
      .TAG_W (ROB_IDX_WIDTH),
      .CDB_W (WB_WIDTH)
  ) u_issue_csr (
      .clk(clk_i),
      .rst_n(rst_ni),
      .flush_i(backend_flush),
      .head_en_i(1'b1),
      .head_tag_i(rob_head_ptr),

      .dispatch_valid(csr_dispatch_valid),
      .dispatch_op   (csr_dispatch_op),
      .dispatch_dst  (csr_dispatch_dst),
      .dispatch_v1   (csr_dispatch_v1),
      .dispatch_q1   (csr_dispatch_q1),
      .dispatch_r1   (csr_dispatch_r1),
      .dispatch_v2   (csr_dispatch_v2),
      .dispatch_q2   (csr_dispatch_q2),
      .dispatch_r2   (csr_dispatch_r2),

      .issue_ready (csr_issue_ready),
      .free_count_o(csr_free_count),

      .cdb_valid(cdb_valid),
      .cdb_tag  (cdb_tag),
      .cdb_val  (cdb_val),

      .fu_en (csr_en),
      .fu_uop(csr_uop),
      .fu_v1 (csr_v1),
      .fu_v2 (csr_v2),
      .fu_dst(csr_dst)
  );


  // Backpressure calculation (MDU not implemented yet)
  logic alu_can_accept;
  logic bru_can_accept;
  logic lsu_can_accept;
  logic mdu_can_accept;
  logic csr_can_accept;

  always_comb begin
    alu_can_accept = (alu_need_cnt == 0) ? 1'b1 : (alu_free_count >= alu_need_cnt);
    bru_can_accept = (bru_need_cnt == 0) ? 1'b1 : (bru_free_count >= bru_need_cnt);
    lsu_can_accept = (lsu_need_cnt == 0) ? 1'b1 : (lsu_free_count >= lsu_need_cnt);
    mdu_can_accept = (mdu_need_cnt == 0) ? 1'b1 : 1'b0;  // placeholder
    csr_can_accept = (csr_need_cnt == 0) ? 1'b1 : (csr_free_count >= csr_need_cnt);
  end

  assign rob_ready_gated = rob_ready & alu_can_accept & bru_can_accept & lsu_can_accept & mdu_can_accept & csr_can_accept;

  // =========================================================
  // Execute Units
  // =========================================================
  logic alu0_en, alu1_en, alu2_en, alu3_en;
  decode_pkg::uop_t alu0_uop, alu1_uop, alu2_uop, alu3_uop;
  logic [Cfg.XLEN-1:0] alu0_v1, alu0_v2, alu1_v1, alu1_v2, alu2_v1, alu2_v2, alu3_v1, alu3_v2;
  logic [ROB_IDX_WIDTH-1:0] alu0_dst, alu1_dst, alu2_dst, alu3_dst;

  logic alu0_wb_valid, alu1_wb_valid, alu2_wb_valid, alu3_wb_valid;
  logic [ROB_IDX_WIDTH-1:0] alu0_wb_tag, alu1_wb_tag, alu2_wb_tag, alu3_wb_tag;
  logic [Cfg.XLEN-1:0] alu0_wb_data, alu1_wb_data, alu2_wb_data, alu3_wb_data;
  logic alu0_mispred, alu1_mispred, alu2_mispred, alu3_mispred;
  logic [Cfg.PLEN-1:0] alu0_redirect_pc, alu1_redirect_pc, alu2_redirect_pc, alu3_redirect_pc;

  execute_alu #(
      .Cfg  (Cfg),
      .TAG_W(ROB_IDX_WIDTH),
      .XLEN (Cfg.XLEN),
      .PC_W (Cfg.PLEN)
  ) u_alu0 (
      .clk_i      (clk_i),
      .rst_ni     (rst_ni),
      .alu_valid_i(alu0_en),
      .uop_i      (alu0_uop),
      .rs1_data_i (alu0_v1),
      .rs2_data_i (alu0_v2),
      .rob_tag_i  (alu0_dst),

      .alu_valid_o      (alu0_wb_valid),
      .alu_rob_tag_o    (alu0_wb_tag),
      .alu_result_o     (alu0_wb_data),
      .alu_is_mispred_o (alu0_mispred),
      .alu_redirect_pc_o(alu0_redirect_pc)
  );

  execute_alu #(
      .Cfg  (Cfg),
      .TAG_W(ROB_IDX_WIDTH),
      .XLEN (Cfg.XLEN),
      .PC_W (Cfg.PLEN)
  ) u_alu1 (
      .clk_i      (clk_i),
      .rst_ni     (rst_ni),
      .alu_valid_i(alu1_en),
      .uop_i      (alu1_uop),
      .rs1_data_i (alu1_v1),
      .rs2_data_i (alu1_v2),
      .rob_tag_i  (alu1_dst),

      .alu_valid_o      (alu1_wb_valid),
      .alu_rob_tag_o    (alu1_wb_tag),
      .alu_result_o     (alu1_wb_data),
      .alu_is_mispred_o (alu1_mispred),
      .alu_redirect_pc_o(alu1_redirect_pc)
  );

  execute_alu #(
      .Cfg  (Cfg),
      .TAG_W(ROB_IDX_WIDTH),
      .XLEN (Cfg.XLEN),
      .PC_W (Cfg.PLEN)
  ) u_alu2 (
      .clk_i      (clk_i),
      .rst_ni     (rst_ni),
      .alu_valid_i(alu2_en),
      .uop_i      (alu2_uop),
      .rs1_data_i (alu2_v1),
      .rs2_data_i (alu2_v2),
      .rob_tag_i  (alu2_dst),

      .alu_valid_o      (alu2_wb_valid),
      .alu_rob_tag_o    (alu2_wb_tag),
      .alu_result_o     (alu2_wb_data),
      .alu_is_mispred_o (alu2_mispred),
      .alu_redirect_pc_o(alu2_redirect_pc)
  );

  execute_alu #(
      .Cfg  (Cfg),
      .TAG_W(ROB_IDX_WIDTH),
      .XLEN (Cfg.XLEN),
      .PC_W (Cfg.PLEN)
  ) u_alu3 (
      .clk_i      (clk_i),
      .rst_ni     (rst_ni),
      .alu_valid_i(alu3_en),
      .uop_i      (alu3_uop),
      .rs1_data_i (alu3_v1),
      .rs2_data_i (alu3_v2),
      .rob_tag_i  (alu3_dst),

      .alu_valid_o      (alu3_wb_valid),
      .alu_rob_tag_o    (alu3_wb_tag),
      .alu_result_o     (alu3_wb_data),
      .alu_is_mispred_o (alu3_mispred),
      .alu_redirect_pc_o(alu3_redirect_pc)
  );

  // BRU
  logic bru_en;
  decode_pkg::uop_t bru_uop;
  logic [Cfg.XLEN-1:0] bru_v1, bru_v2;
  logic [ROB_IDX_WIDTH-1:0] bru_dst;

  logic bru_wb_valid;
  logic [ROB_IDX_WIDTH-1:0] bru_wb_tag;
  logic [Cfg.XLEN-1:0] bru_wb_data;
  logic bru_mispred;
  logic [Cfg.PLEN-1:0] bru_redirect_pc;

  execute_alu #(
      .Cfg  (Cfg),
      .TAG_W(ROB_IDX_WIDTH),
      .XLEN (Cfg.XLEN),
      .PC_W (Cfg.PLEN)
  ) u_bru (
      .clk_i      (clk_i),
      .rst_ni     (rst_ni),
      .alu_valid_i(bru_en),
      .uop_i      (bru_uop),
      .rs1_data_i (bru_v1),
      .rs2_data_i (bru_v2),
      .rob_tag_i  (bru_dst),

      .alu_valid_o      (bru_wb_valid),
      .alu_rob_tag_o    (bru_wb_tag),
      .alu_result_o     (bru_wb_data),
      .alu_is_mispred_o (bru_mispred),
      .alu_redirect_pc_o(bru_redirect_pc)
  );

  // LSU
  logic lsu_en;
  decode_pkg::uop_t lsu_uop;
  logic [Cfg.XLEN-1:0] lsu_v1, lsu_v2;
  logic [ROB_IDX_WIDTH-1:0] lsu_dst;
  logic [SB_IDX_WIDTH-1:0] lsu_sb_id;

  logic lsu_req_ready;
  logic lsu_wb_valid;
  logic [ROB_IDX_WIDTH-1:0] lsu_wb_tag;
  logic [Cfg.XLEN-1:0] lsu_wb_data;
  logic lsu_wb_exception;
  logic [4:0] lsu_wb_ecause;
  logic lsu_wb_is_mispred;
  logic [Cfg.PLEN-1:0] lsu_wb_redirect_pc;

  // LSU <-> D$
  logic lsu_ld_req_valid;
  logic lsu_ld_req_ready;
  logic [Cfg.PLEN-1:0] lsu_ld_req_addr;
  decode_pkg::lsu_op_e lsu_ld_req_op;

  logic lsu_ld_rsp_valid;
  logic lsu_ld_rsp_ready;
  logic [Cfg.XLEN-1:0] lsu_ld_rsp_data;
  logic lsu_ld_rsp_err;

  lsu #(
      .Cfg(Cfg),
      .ROB_IDX_WIDTH(ROB_IDX_WIDTH),
      .SB_DEPTH(SB_DEPTH)
  ) u_lsu (
      .clk_i  (clk_i),
      .rst_ni (rst_ni),
      .flush_i(backend_flush),

      .req_valid_i(lsu_en),
      .req_ready_o(lsu_req_ready),
      .uop_i      (lsu_uop),
      .rs1_data_i (lsu_v1),
      .rs2_data_i (lsu_v2),
      .rob_tag_i  (lsu_dst),
      .sb_id_i    (lsu_sb_id),

      .sb_ex_valid_o(sb_ex_valid),
      .sb_ex_sb_id_o(sb_ex_sb_id),
      .sb_ex_addr_o (sb_ex_addr),
      .sb_ex_data_o (sb_ex_data),
      .sb_ex_op_o   (sb_ex_op),
      .sb_ex_rob_idx_o(sb_ex_rob_idx),

      .sb_load_addr_o(sb_load_addr),
      .sb_load_rob_idx_o(sb_load_rob_idx),
      .sb_load_hit_i(sb_load_hit),
      .sb_load_data_i(sb_load_data),

      .ld_req_valid_o(lsu_ld_req_valid),
      .ld_req_ready_i(lsu_ld_req_ready),
      .ld_req_addr_o (lsu_ld_req_addr),
      .ld_req_op_o   (lsu_ld_req_op),

      .ld_rsp_valid_i(lsu_ld_rsp_valid),
      .ld_rsp_ready_o(lsu_ld_rsp_ready),
      .ld_rsp_data_i (lsu_ld_rsp_data),
      .ld_rsp_err_i  (lsu_ld_rsp_err),

      .wb_valid_o      (lsu_wb_valid),
      .wb_rob_idx_o    (lsu_wb_tag),
      .wb_data_o       (lsu_wb_data),
      .wb_exception_o  (lsu_wb_exception),
      .wb_ecause_o     (lsu_wb_ecause),
      .wb_is_mispred_o (lsu_wb_is_mispred),
      .wb_redirect_pc_o(lsu_wb_redirect_pc),
      .wb_ready_i      (1'b1)
  );

  // CSR
  logic csr_en;
  decode_pkg::uop_t csr_uop;
  logic [Cfg.XLEN-1:0] csr_v1, csr_v2;
  logic [ROB_IDX_WIDTH-1:0] csr_dst;

  logic csr_wb_valid;
  logic [ROB_IDX_WIDTH-1:0] csr_wb_tag;
  logic [Cfg.XLEN-1:0] csr_wb_data;
  logic csr_wb_exception;
  logic [4:0] csr_wb_ecause;

  execute_csr #(
      .Cfg  (Cfg),
      .TAG_W(ROB_IDX_WIDTH),
      .XLEN (Cfg.XLEN)
  ) u_csr (
      .clk_i      (clk_i),
      .rst_ni     (rst_ni),
      .csr_valid_i(csr_en),
      .uop_i      (csr_uop),
      .rs1_data_i (csr_v1),
      .rob_tag_i  (csr_dst),

      .csr_valid_o  (csr_wb_valid),
      .csr_rob_tag_o(csr_wb_tag),
      .csr_result_o (csr_wb_data),
      .csr_exception_o(csr_wb_exception),
      .csr_ecause_o   (csr_wb_ecause)
  );

  // =========================================================
  // Writeback (CDB)
  // =========================================================
  logic [NUM_FUS-1:0] fu_valid;
  logic [NUM_FUS-1:0][Cfg.XLEN-1:0] fu_data;
  logic [NUM_FUS-1:0][ROB_IDX_WIDTH-1:0] fu_rob_idx;
  logic [NUM_FUS-1:0] fu_exception;
  logic [NUM_FUS-1:0][4:0] fu_ecause;
  logic [NUM_FUS-1:0] fu_is_mispred;
  logic [NUM_FUS-1:0][Cfg.PLEN-1:0] fu_redirect_pc;
  logic [NUM_FUS-1:0] fu_ready;

  always_comb begin
    fu_valid          = '0;
    fu_data           = '0;
    fu_rob_idx        = '0;
    fu_exception      = '0;
    fu_ecause         = '0;
    fu_is_mispred     = '0;
    fu_redirect_pc    = '0;

    fu_valid[0]       = alu0_wb_valid;
    fu_data[0]        = alu0_wb_data;
    fu_rob_idx[0]     = alu0_wb_tag;
    fu_is_mispred[0]  = alu0_mispred;
    fu_redirect_pc[0] = alu0_redirect_pc;

    fu_valid[1]       = alu1_wb_valid;
    fu_data[1]        = alu1_wb_data;
    fu_rob_idx[1]     = alu1_wb_tag;
    fu_is_mispred[1]  = alu1_mispred;
    fu_redirect_pc[1] = alu1_redirect_pc;

    fu_valid[2]       = bru_wb_valid;
    fu_data[2]        = bru_wb_data;
    fu_rob_idx[2]     = bru_wb_tag;
    fu_is_mispred[2]  = bru_mispred;
    fu_redirect_pc[2] = bru_redirect_pc;

    fu_valid[3]       = lsu_wb_valid;
    fu_data[3]        = lsu_wb_data;
    fu_rob_idx[3]     = lsu_wb_tag;
    fu_exception[3]   = lsu_wb_exception;
    fu_ecause[3]      = lsu_wb_ecause;
    fu_is_mispred[3]  = lsu_wb_is_mispred;
    fu_redirect_pc[3] = lsu_wb_redirect_pc;

    fu_valid[4]       = alu2_wb_valid;
    fu_data[4]        = alu2_wb_data;
    fu_rob_idx[4]     = alu2_wb_tag;
    fu_is_mispred[4]  = alu2_mispred;
    fu_redirect_pc[4] = alu2_redirect_pc;

    fu_valid[5]       = alu3_wb_valid;
    fu_data[5]        = alu3_wb_data;
    fu_rob_idx[5]     = alu3_wb_tag;
    fu_is_mispred[5]  = alu3_mispred;
    fu_redirect_pc[5] = alu3_redirect_pc;

    fu_valid[6]       = csr_wb_valid;
    fu_data[6]        = csr_wb_data;
    fu_rob_idx[6]     = csr_wb_tag;
    fu_exception[6]   = csr_wb_exception;
    fu_ecause[6]      = csr_wb_ecause;
  end

  logic [WB_WIDTH-1:0]                    wb_valid;
  logic [WB_WIDTH-1:0][     Cfg.XLEN-1:0] wb_data;
  logic [WB_WIDTH-1:0][ROB_IDX_WIDTH-1:0] wb_rob_idx;
  logic [WB_WIDTH-1:0]                    wb_exception;
  logic [WB_WIDTH-1:0][              4:0] wb_ecause;
  logic [WB_WIDTH-1:0]                    wb_is_mispred;
  logic [WB_WIDTH-1:0][     Cfg.PLEN-1:0] wb_redirect_pc;

  writeback #(
      .Cfg          (Cfg),
      .WB_WIDTH     (WB_WIDTH),
      .NUM_FUS      (NUM_FUS),
      .ROB_IDX_WIDTH(ROB_IDX_WIDTH)
  ) u_wb (
      .fu_valid_i      (fu_valid),
      .fu_data_i       (fu_data),
      .fu_rob_idx_i    (fu_rob_idx),
      .fu_exception_i  (fu_exception),
      .fu_ecause_i     (fu_ecause),
      .fu_is_mispred_i (fu_is_mispred),
      .fu_redirect_pc_i(fu_redirect_pc),

      .fu_ready_o(fu_ready),

      .wb_valid_o      (wb_valid),
      .wb_data_o       (wb_data),
      .wb_rob_idx_o    (wb_rob_idx),
      .wb_exception_o  (wb_exception),
      .wb_ecause_o     (wb_ecause),
      .wb_is_mispred_o (wb_is_mispred),
      .wb_redirect_pc_o(wb_redirect_pc)
  );

  always_comb begin
    for (int i = 0; i < WB_WIDTH; i++) begin
      cdb_valid[i] = wb_valid[i];
      cdb_tag[i]   = wb_rob_idx[i];
      cdb_val[i]   = wb_data[i];
    end
  end

  // =========================================================
  // D-Cache (Load/Store)
  // =========================================================
  dcache #(
      .Cfg(Cfg)
  ) u_dcache (
      .clk_i  (clk_i),
      .rst_ni (rst_ni),
      .flush_i(backend_flush),

      // Load port (from LSU)
      .ld_req_valid_i(lsu_ld_req_valid),
      .ld_req_ready_o(lsu_ld_req_ready),
      .ld_req_addr_i (lsu_ld_req_addr),
      .ld_req_op_i   (lsu_ld_req_op),

      .ld_rsp_valid_o(lsu_ld_rsp_valid),
      .ld_rsp_ready_i(lsu_ld_rsp_ready),
      .ld_rsp_data_o (lsu_ld_rsp_data),
      .ld_rsp_err_o  (lsu_ld_rsp_err),

      // Store port (from Store Buffer)
      .st_req_valid_i(sb_dcache_req_valid),
      .st_req_ready_o(sb_dcache_req_ready),
      .st_req_addr_i (sb_dcache_req_addr),
      .st_req_data_i (sb_dcache_req_data),
      .st_req_op_i   (sb_dcache_req_op),

      // Miss/Refill interface (to memory)
      .miss_req_valid_o     (dcache_miss_req_valid_o),
      .miss_req_ready_i     (dcache_miss_req_ready_i),
      .miss_req_paddr_o     (dcache_miss_req_paddr_o),
      .miss_req_victim_way_o(dcache_miss_req_victim_way_o),
      .miss_req_index_o     (dcache_miss_req_index_o),

      .refill_valid_i(dcache_refill_valid_i),
      .refill_ready_o(dcache_refill_ready_o),
      .refill_paddr_i(dcache_refill_paddr_i),
      .refill_way_i  (dcache_refill_way_i),
      .refill_data_i (dcache_refill_data_i),

      // Writeback
      .wb_req_valid_o(dcache_wb_req_valid_o),
      .wb_req_ready_i(dcache_wb_req_ready_i),
      .wb_req_paddr_o(dcache_wb_req_paddr_o),
      .wb_req_data_o (dcache_wb_req_data_o)
  );

endmodule
