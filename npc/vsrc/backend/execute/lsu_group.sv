// vsrc/backend/execute/lsu_group.sv
import config_pkg::*;
import decode_pkg::*;

module lsu_group #(
    parameter config_pkg::cfg_t Cfg           = config_pkg::EmptyCfg,
    parameter int unsigned      ROB_IDX_WIDTH = 6,
    parameter int unsigned      SB_DEPTH      = 16,
    parameter int unsigned      SB_IDX_WIDTH  = $clog2(SB_DEPTH),
    parameter int unsigned      LQ_DEPTH      = 16,
    parameter int unsigned      SQ_DEPTH      = 16,
    parameter int unsigned      N_LSU         = 1,
    parameter int unsigned      ECAUSE_WIDTH  = 5
) (
    input logic clk_i,
    input logic rst_ni,
    input logic flush_i,

    // =========================================================
    // 1) Request from Issue/Execute
    // =========================================================
    input  logic                                 req_valid_i,
    output logic                                 req_ready_o,
    input  decode_pkg::uop_t                     uop_i,
    input  logic             [     Cfg.XLEN-1:0] rs1_data_i,
    input  logic             [     Cfg.XLEN-1:0] rs2_data_i,
    input  logic             [ROB_IDX_WIDTH-1:0] rob_tag_i,
    input  logic             [ SB_IDX_WIDTH-1:0] sb_id_i,

    // =========================================================
    // 2) Store Buffer interface (execute fill)
    // =========================================================
    output logic                                    sb_ex_valid_o,
    output logic                [ SB_IDX_WIDTH-1:0] sb_ex_sb_id_o,
    output logic                [     Cfg.PLEN-1:0] sb_ex_addr_o,
    output logic                [     Cfg.XLEN-1:0] sb_ex_data_o,
    output decode_pkg::lsu_op_e                     sb_ex_op_o,
    output logic                [ROB_IDX_WIDTH-1:0] sb_ex_rob_idx_o,

    // Store-to-Load Forwarding (query)
    output logic [     Cfg.PLEN-1:0] sb_load_addr_o,
    output logic [ROB_IDX_WIDTH-1:0] sb_load_rob_idx_o,
    input  logic                     sb_load_hit_i,
    input  logic [     Cfg.XLEN-1:0] sb_load_data_i,

    // =========================================================
    // 3) D-Cache Load interface
    // =========================================================
    output logic                               ld_req_valid_o,
    input  logic                               ld_req_ready_i,
    output logic                [Cfg.PLEN-1:0] ld_req_addr_o,
    output decode_pkg::lsu_op_e                ld_req_op_o,
    output logic [((N_LSU <= 1) ? 1 : $clog2(N_LSU))-1:0] ld_req_id_o,

    input  logic                ld_rsp_valid_i,
    input  logic [((N_LSU <= 1) ? 1 : $clog2(N_LSU))-1:0] ld_rsp_id_i,
    output logic                ld_rsp_ready_o,
    input  logic [Cfg.XLEN-1:0] ld_rsp_data_i,
    input  logic                ld_rsp_err_i,

    // =========================================================
    // 4) Writeback to ROB/CDB
    // =========================================================
    output logic                     wb_valid_o,
    output logic [ROB_IDX_WIDTH-1:0] wb_rob_idx_o,
    output logic [     Cfg.XLEN-1:0] wb_data_o,
    output logic                     wb_exception_o,
    output logic [ECAUSE_WIDTH-1:0]  wb_ecause_o,
    output logic                     wb_is_mispred_o,
    output logic [     Cfg.PLEN-1:0] wb_redirect_pc_o,
    input  logic                     wb_ready_i,

    // =========================================================
    // 5) Debug visibility for queue skeleton
    // =========================================================
    output logic [$clog2(LQ_DEPTH + 1)-1:0] dbg_lq_count_o,
    output logic                            dbg_lq_head_valid_o,
    output logic [       ROB_IDX_WIDTH-1:0] dbg_lq_head_rob_tag_o,
    output logic [$clog2(SQ_DEPTH + 1)-1:0] dbg_sq_count_o,
    output logic                            dbg_sq_head_valid_o,
    output logic [       ROB_IDX_WIDTH-1:0] dbg_sq_head_rob_tag_o
);

  localparam int unsigned LANE_SEL_WIDTH = (N_LSU <= 1) ? 1 : $clog2(N_LSU);
  localparam int unsigned LD_ID_WIDTH = (N_LSU <= 1) ? 1 : $clog2(N_LSU);
  localparam int unsigned DBG_SEL_WIDTH = (N_LSU <= 1) ? 1 : $clog2(N_LSU + 1);
  localparam int unsigned SQ_BE_WIDTH = Cfg.XLEN / 8;
  localparam int unsigned SQ_BYTE_OFF_W = (SQ_BE_WIDTH <= 1) ? 1 : $clog2(SQ_BE_WIDTH);

  // Keep these debug names for existing testbench hierarchical probes.
  logic                [               1:0]                    state_q;
  logic                [ ROB_IDX_WIDTH-1:0]                    req_tag_q;
  logic                [      Cfg.PLEN-1:0]                    req_addr_q;
  logic                [         N_LSU-1:0]                    dbg_lane_busy;
  logic                                                        dbg_alloc_fire;
  logic                [ DBG_SEL_WIDTH-1:0]                    dbg_alloc_lane;
  logic                [ DBG_SEL_WIDTH-1:0]                    dbg_ld_owner;

  logic                [         N_LSU-1:0]                    lane_req_valid;
  logic                [         N_LSU-1:0]                    lane_req_ready;

  logic                [         N_LSU-1:0]                    lane_sb_ex_valid;
  logic                [         N_LSU-1:0][ SB_IDX_WIDTH-1:0] lane_sb_ex_sb_id;
  logic                [         N_LSU-1:0][     Cfg.PLEN-1:0] lane_sb_ex_addr;
  logic                [         N_LSU-1:0][     Cfg.XLEN-1:0] lane_sb_ex_data;
  decode_pkg::lsu_op_e                                         lane_sb_ex_op        [N_LSU];
  logic                [         N_LSU-1:0][ROB_IDX_WIDTH-1:0] lane_sb_ex_rob_idx;

  logic                [         N_LSU-1:0][     Cfg.PLEN-1:0] lane_sb_load_addr;
  logic                [         N_LSU-1:0][ROB_IDX_WIDTH-1:0] lane_sb_load_rob_idx;

  logic                [         N_LSU-1:0]                    lane_ld_req_valid;
  logic                [         N_LSU-1:0]                    lane_ld_req_ready;
  logic                [         N_LSU-1:0][     Cfg.PLEN-1:0] lane_ld_req_addr;
  decode_pkg::lsu_op_e                                         lane_ld_req_op       [N_LSU];

  logic                [         N_LSU-1:0]                    lane_ld_rsp_valid;
  logic                [         N_LSU-1:0]                    lane_ld_rsp_ready;

  logic                [         N_LSU-1:0]                    lane_wb_valid;
  logic                [         N_LSU-1:0][ROB_IDX_WIDTH-1:0] lane_wb_rob_idx;
  logic                [         N_LSU-1:0][     Cfg.XLEN-1:0] lane_wb_data;
  logic                [         N_LSU-1:0]                    lane_wb_exception;
  logic                [         N_LSU-1:0][ECAUSE_WIDTH-1:0] lane_wb_ecause;
  logic                [         N_LSU-1:0]                    lane_wb_is_mispred;
  logic                [         N_LSU-1:0][     Cfg.PLEN-1:0] lane_wb_redirect_pc;
  logic                [         N_LSU-1:0]                    lane_wb_ready;

  logic                [         N_LSU-1:0]                    alloc_grant;
  logic                [LANE_SEL_WIDTH-1:0]                    alloc_lane_idx;
  logic                                                        alloc_fire;

  logic                [         N_LSU-1:0]                    ld_req_grant;
  logic                [LANE_SEL_WIDTH-1:0]                    ld_req_lane_idx;
  logic                                                        ld_req_grant_valid;

  logic                [         N_LSU-1:0]                    wb_grant;
  logic                [LANE_SEL_WIDTH-1:0]                    wb_lane_idx;
  logic                                                        wb_grant_valid;
  logic                                                        wb_fire;
  logic                                                        wb_fire_is_store;

  logic                                                        lq_alloc_valid;
  logic                                                        lq_alloc_ready;
  logic                                                        lq_pop_valid;
  logic                                                        lq_pop_ready;
  logic                                                        lq_full;
  logic                                                        lq_empty;

  logic                                                        sq_alloc_valid;
  logic                                                        sq_alloc_ready;
  logic                                                        sq_pop_valid;
  logic                                                        sq_pop_ready;
  logic                                                        sq_full;
  logic                                                        sq_empty;
  logic                                                        sq_fwd_query_valid;
  logic                                                        sq_fwd_query_hit;
  logic                [     Cfg.XLEN-1:0]                    sq_fwd_query_data;
  logic                [      Cfg.PLEN-1:0]                   sq_req_word_addr;
  logic                [      Cfg.XLEN-1:0]                   sq_store_data_aligned;
  logic                [     SQ_BE_WIDTH-1:0]                 sq_store_be;
  logic                [     SQ_BE_WIDTH-1:0]                 sq_load_be;
  logic                                                        sb_load_hit_mux;
  logic                [     Cfg.XLEN-1:0]                    sb_load_data_mux;
  logic                [      Cfg.XLEN-1:0]                   req_eff_addr_xlen;
  logic                [      Cfg.PLEN-1:0]                   req_eff_addr;

  logic                [         N_LSU-1:0]                    lane_has_store_q;
  logic                [         N_LSU-1:0]                    lane_has_store_d;

  logic rsp_id_in_range;
  logic [LANE_SEL_WIDTH-1:0] rsp_lane_idx;

  function automatic logic [SQ_BE_WIDTH-1:0] store_be_mask(input decode_pkg::lsu_op_e op,
                                                            input logic [Cfg.PLEN-1:0] addr);
    logic [SQ_BE_WIDTH-1:0] mask;
    logic [SQ_BYTE_OFF_W-1:0] off;
    begin
      mask = '0;
      off = addr[SQ_BYTE_OFF_W-1:0];
      unique case (op)
        decode_pkg::LSU_SB: begin
          mask[off] = 1'b1;
        end
        decode_pkg::LSU_SH: begin
          for (int i = 0; i < 2; i++) begin
            if ((off + i) < SQ_BE_WIDTH) begin
              mask[off+i] = 1'b1;
            end
          end
        end
        decode_pkg::LSU_SW: begin
          for (int i = 0; i < 4; i++) begin
            if ((off + i) < SQ_BE_WIDTH) begin
              mask[off+i] = 1'b1;
            end
          end
        end
        decode_pkg::LSU_SD: begin
          for (int i = 0; i < SQ_BE_WIDTH; i++) begin
            mask[i] = 1'b1;
          end
        end
        default: begin
          mask = '0;
        end
      endcase
      store_be_mask = mask;
    end
  endfunction

  function automatic logic [SQ_BE_WIDTH-1:0] load_be_mask(input decode_pkg::lsu_op_e op,
                                                           input logic [Cfg.PLEN-1:0] addr);
    logic [SQ_BE_WIDTH-1:0] mask;
    logic [SQ_BYTE_OFF_W-1:0] off;
    begin
      mask = '0;
      off = addr[SQ_BYTE_OFF_W-1:0];
      unique case (op)
        decode_pkg::LSU_LB, decode_pkg::LSU_LBU: begin
          mask[off] = 1'b1;
        end
        decode_pkg::LSU_LH, decode_pkg::LSU_LHU: begin
          for (int i = 0; i < 2; i++) begin
            if ((off + i) < SQ_BE_WIDTH) begin
              mask[off+i] = 1'b1;
            end
          end
        end
        decode_pkg::LSU_LW, decode_pkg::LSU_LWU: begin
          for (int i = 0; i < 4; i++) begin
            if ((off + i) < SQ_BE_WIDTH) begin
              mask[off+i] = 1'b1;
            end
          end
        end
        decode_pkg::LSU_LD: begin
          for (int i = 0; i < SQ_BE_WIDTH; i++) begin
            mask[i] = 1'b1;
          end
        end
        default: begin
          mask = '0;
        end
      endcase
      load_be_mask = mask;
    end
  endfunction

  function automatic logic [Cfg.XLEN-1:0] store_aligned_data(
      input decode_pkg::lsu_op_e op,
      input logic [Cfg.XLEN-1:0] data,
      input logic [Cfg.PLEN-1:0] addr
  );
    logic [Cfg.XLEN-1:0] aligned;
    logic [SQ_BYTE_OFF_W-1:0] off;
    begin
      aligned = '0;
      off = addr[SQ_BYTE_OFF_W-1:0];
      unique case (op)
        decode_pkg::LSU_SB: begin
          if (off < SQ_BE_WIDTH) begin
            aligned[(8*off)+:8] = data[7:0];
          end
        end
        decode_pkg::LSU_SH: begin
          if ((off + 1) < SQ_BE_WIDTH) begin
            aligned[(8*off)+:16] = data[15:0];
          end
        end
        decode_pkg::LSU_SW: begin
          if ((off + 3) < SQ_BE_WIDTH) begin
            aligned[(8*off)+:32] = data[31:0];
          end
        end
        decode_pkg::LSU_SD: begin
          aligned = data;
        end
        default: begin
          aligned = data;
        end
      endcase
      store_aligned_data = aligned;
    end
  endfunction

  generate
    for (genvar gi = 0; gi < N_LSU; gi++) begin : g_lanes
      lsu_lane #(
          .Cfg(Cfg),
          .ROB_IDX_WIDTH(ROB_IDX_WIDTH),
          .SB_DEPTH(SB_DEPTH),
          .SB_IDX_WIDTH(SB_IDX_WIDTH),
          .ECAUSE_WIDTH(ECAUSE_WIDTH)
      ) u_lane (
          .clk_i,
          .rst_ni,
          .flush_i,

          .req_valid_i(lane_req_valid[gi]),
          .req_ready_o(lane_req_ready[gi]),
          .uop_i,
          .rs1_data_i,
          .rs2_data_i,
          .rob_tag_i,
          .sb_id_i,

          .sb_ex_valid_o(lane_sb_ex_valid[gi]),
          .sb_ex_sb_id_o(lane_sb_ex_sb_id[gi]),
          .sb_ex_addr_o(lane_sb_ex_addr[gi]),
          .sb_ex_data_o(lane_sb_ex_data[gi]),
          .sb_ex_op_o(lane_sb_ex_op[gi]),
          .sb_ex_rob_idx_o(lane_sb_ex_rob_idx[gi]),

          .sb_load_addr_o(lane_sb_load_addr[gi]),
          .sb_load_rob_idx_o(lane_sb_load_rob_idx[gi]),
          .sb_load_hit_i(sb_load_hit_mux),
          .sb_load_data_i(sb_load_data_mux),

          .ld_req_valid_o(lane_ld_req_valid[gi]),
          .ld_req_ready_i(lane_ld_req_ready[gi]),
          .ld_req_addr_o(lane_ld_req_addr[gi]),
          .ld_req_op_o(lane_ld_req_op[gi]),

          .ld_rsp_valid_i(lane_ld_rsp_valid[gi]),
          .ld_rsp_ready_o(lane_ld_rsp_ready[gi]),
          .ld_rsp_data_i,
          .ld_rsp_err_i,

          .wb_valid_o(lane_wb_valid[gi]),
          .wb_rob_idx_o(lane_wb_rob_idx[gi]),
          .wb_data_o(lane_wb_data[gi]),
          .wb_exception_o(lane_wb_exception[gi]),
          .wb_ecause_o(lane_wb_ecause[gi]),
          .wb_is_mispred_o(lane_wb_is_mispred[gi]),
          .wb_redirect_pc_o(lane_wb_redirect_pc[gi]),
          .wb_ready_i(lane_wb_ready[gi])
      );

      assign dbg_lane_busy[gi] = lane_ld_req_valid[gi] | lane_ld_rsp_ready[gi] | lane_wb_valid[gi];
    end
  endgenerate

  assign state_q    = g_lanes[0].u_lane.state_q;
  assign req_tag_q  = g_lanes[0].u_lane.req_tag_q;
  assign req_addr_q = g_lanes[0].u_lane.req_addr_q;
  assign req_eff_addr_xlen = rs1_data_i + uop_i.imm;
  assign req_eff_addr = req_eff_addr_xlen[Cfg.PLEN-1:0];
  assign sq_req_word_addr = {req_eff_addr[Cfg.PLEN-1:SQ_BYTE_OFF_W], {SQ_BYTE_OFF_W{1'b0}}};
  assign sq_store_be = store_be_mask(uop_i.lsu_op, req_eff_addr);
  assign sq_load_be = load_be_mask(uop_i.lsu_op, req_eff_addr);
  assign sq_store_data_aligned = store_aligned_data(uop_i.lsu_op, rs2_data_i, req_eff_addr);
  assign sq_fwd_query_valid = alloc_fire && uop_i.is_load;
  assign sb_load_hit_mux = sb_load_hit_i || sq_fwd_query_hit;
  assign sb_load_data_mux = sq_fwd_query_hit ? sq_fwd_query_data : sb_load_data_i;

  assign lq_alloc_valid = alloc_fire && uop_i.is_load;
  assign sq_alloc_valid = alloc_fire && uop_i.is_store;

  always_comb begin
    req_ready_o = 1'b0;
    alloc_grant = '0;
    alloc_lane_idx = '0;
    for (int i = 0; i < N_LSU; i++) begin
      if (!req_ready_o && lane_req_ready[i] &&
          (!uop_i.is_load || lq_alloc_ready) &&
          (!uop_i.is_store || sq_alloc_ready)) begin
        req_ready_o = 1'b1;
        alloc_grant[i] = 1'b1;
        alloc_lane_idx = LANE_SEL_WIDTH'(i);
      end
    end
  end

  assign alloc_fire = req_valid_i && req_ready_o;
  assign dbg_alloc_fire = alloc_fire;

  always_comb begin
    lane_req_valid = '0;
    for (int i = 0; i < N_LSU; i++) begin
      lane_req_valid[i] = alloc_fire && alloc_grant[i];
    end
  end

  always_comb begin
    sb_ex_valid_o = 1'b0;
    sb_ex_sb_id_o = '0;
    sb_ex_addr_o = '0;
    sb_ex_data_o = '0;
    sb_ex_op_o = decode_pkg::LSU_LW;
    sb_ex_rob_idx_o = '0;
    sb_load_addr_o = '0;
    sb_load_rob_idx_o = '0;
    for (int i = 0; i < N_LSU; i++) begin
      if (lane_sb_ex_valid[i] && !sb_ex_valid_o) begin
        sb_ex_valid_o = 1'b1;
        sb_ex_sb_id_o = lane_sb_ex_sb_id[i];
        sb_ex_addr_o = lane_sb_ex_addr[i];
        sb_ex_data_o = lane_sb_ex_data[i];
        sb_ex_op_o = lane_sb_ex_op[i];
        sb_ex_rob_idx_o = lane_sb_ex_rob_idx[i];
      end
      if (lane_req_valid[i]) begin
        sb_load_addr_o = lane_sb_load_addr[i];
        sb_load_rob_idx_o = lane_sb_load_rob_idx[i];
      end
    end
  end

  always_comb begin
    ld_req_grant = '0;
    ld_req_lane_idx = '0;
    ld_req_grant_valid = 1'b0;
    for (int i = 0; i < N_LSU; i++) begin
      if (!ld_req_grant_valid && lane_ld_req_valid[i]) begin
        ld_req_grant_valid = 1'b1;
        ld_req_grant[i] = 1'b1;
        ld_req_lane_idx = LANE_SEL_WIDTH'(i);
      end
    end
  end

  assign ld_req_valid_o = ld_req_grant_valid;
  assign ld_req_id_o = LD_ID_WIDTH'(ld_req_lane_idx);
  assign rsp_lane_idx = LANE_SEL_WIDTH'(ld_rsp_id_i);
  assign rsp_id_in_range = ($unsigned(ld_rsp_id_i) < N_LSU);

  always_comb begin
    ld_req_addr_o = '0;
    ld_req_op_o = decode_pkg::LSU_LW;
    lane_ld_req_ready = '0;

    if (ld_req_grant_valid) begin
      ld_req_addr_o = lane_ld_req_addr[ld_req_lane_idx];
      ld_req_op_o = lane_ld_req_op[ld_req_lane_idx];
      lane_ld_req_ready[ld_req_lane_idx] = ld_req_ready_i;
    end
  end

  always_comb begin
    lane_ld_rsp_valid = '0;
    ld_rsp_ready_o = 1'b0;
    if (ld_rsp_valid_i && rsp_id_in_range) begin
      lane_ld_rsp_valid[rsp_lane_idx] = 1'b1;
      ld_rsp_ready_o = lane_ld_rsp_ready[rsp_lane_idx];
    end
  end

  always_comb begin
    wb_grant = '0;
    wb_lane_idx = '0;
    wb_grant_valid = 1'b0;
    for (int i = 0; i < N_LSU; i++) begin
      if (!wb_grant_valid && lane_wb_valid[i]) begin
        wb_grant_valid = 1'b1;
        wb_grant[i] = 1'b1;
        wb_lane_idx = LANE_SEL_WIDTH'(i);
      end
    end
  end

  always_comb begin
    wb_valid_o = wb_grant_valid;
    wb_rob_idx_o = '0;
    wb_data_o = '0;
    wb_exception_o = 1'b0;
    wb_ecause_o = '0;
    wb_is_mispred_o = 1'b0;
    wb_redirect_pc_o = '0;
    lane_wb_ready = '0;

    if (wb_grant_valid) begin
      wb_rob_idx_o = lane_wb_rob_idx[wb_lane_idx];
      wb_data_o = lane_wb_data[wb_lane_idx];
      wb_exception_o = lane_wb_exception[wb_lane_idx];
      wb_ecause_o = lane_wb_ecause[wb_lane_idx];
      wb_is_mispred_o = lane_wb_is_mispred[wb_lane_idx];
      wb_redirect_pc_o = lane_wb_redirect_pc[wb_lane_idx];
      lane_wb_ready[wb_lane_idx] = wb_ready_i;
    end
  end

  assign wb_fire = wb_grant_valid && wb_ready_i;

  always_comb begin
    wb_fire_is_store = 1'b0;
    if (wb_grant_valid) begin
      wb_fire_is_store = lane_has_store_q[wb_lane_idx];
    end
  end

  assign lq_pop_valid = wb_fire && !wb_fire_is_store;
  assign sq_pop_valid = wb_fire && wb_fire_is_store;

  always_comb begin
    lane_has_store_d = lane_has_store_q;
    if (wb_fire) begin
      lane_has_store_d[wb_lane_idx] = 1'b0;
    end
    if (alloc_fire) begin
      lane_has_store_d[alloc_lane_idx] = uop_i.is_store;
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      lane_has_store_q <= '0;
    end else if (flush_i) begin
      lane_has_store_q <= '0;
    end else begin
      lane_has_store_q <= lane_has_store_d;
    end
  end

  lq #(
      .ROB_IDX_WIDTH(ROB_IDX_WIDTH),
      .DEPTH(LQ_DEPTH)
  ) u_lq (
      .clk_i,
      .rst_ni,
      .flush_i,
      .alloc_valid_i(lq_alloc_valid),
      .alloc_ready_o(lq_alloc_ready),
      .alloc_rob_tag_i(rob_tag_i),
      .pop_valid_i(lq_pop_valid),
      .pop_ready_o(lq_pop_ready),
      .head_valid_o(dbg_lq_head_valid_o),
      .head_rob_tag_o(dbg_lq_head_rob_tag_o),
      .count_o(dbg_lq_count_o),
      .full_o(lq_full),
      .empty_o(lq_empty)
  );

  sq #(
      .ROB_IDX_WIDTH(ROB_IDX_WIDTH),
      .ADDR_WIDTH(Cfg.PLEN),
      .DATA_WIDTH(Cfg.XLEN),
      .DEPTH(SQ_DEPTH)
  ) u_sq (
      .clk_i,
      .rst_ni,
      .flush_i,
      .alloc_valid_i(sq_alloc_valid),
      .alloc_ready_o(sq_alloc_ready),
      .alloc_rob_tag_i(rob_tag_i),
      .alloc_addr_i(sq_req_word_addr),
      .alloc_data_i(sq_store_data_aligned),
      .alloc_be_i(sq_store_be),
      .pop_valid_i(sq_pop_valid),
      .pop_ready_o(sq_pop_ready),
      .fwd_query_valid_i(sq_fwd_query_valid),
      .fwd_query_addr_i(sq_req_word_addr),
      .fwd_query_be_i(sq_load_be),
      .fwd_query_hit_o(sq_fwd_query_hit),
      .fwd_query_data_o(sq_fwd_query_data),
      .head_valid_o(dbg_sq_head_valid_o),
      .head_rob_tag_o(dbg_sq_head_rob_tag_o),
      .head_addr_o(),
      .head_data_o(),
      .head_be_o(),
      .count_o(dbg_sq_count_o),
      .full_o(sq_full),
      .empty_o(sq_empty)
  );

  always_comb begin
    dbg_alloc_lane = alloc_fire ? DBG_SEL_WIDTH'(alloc_lane_idx + 1'b1) : '0;
    dbg_ld_owner = '0;

    // Prefer the response lane in current cycle; fallback to first lane waiting response.
    if (ld_rsp_valid_i && rsp_id_in_range) begin
      dbg_ld_owner = DBG_SEL_WIDTH'(ld_rsp_id_i + 1'b1);
    end else begin
      for (int i = 0; i < N_LSU; i++) begin
        if (dbg_ld_owner == '0 && lane_ld_rsp_ready[i]) begin
          dbg_ld_owner = DBG_SEL_WIDTH'(i + 1);
        end
      end
    end
  end

  initial begin
    if (N_LSU < 1) begin
      $error("lsu_group: N_LSU must be >= 1, got %0d", N_LSU);
    end
  end

endmodule
