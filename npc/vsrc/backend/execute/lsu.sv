// vsrc/backend/execute/lsu.sv
import config_pkg::*;
import decode_pkg::*;

// Simple LSU:
// - Computes effective address (rs1 + imm)
// - Loads: optional store-buffer forwarding, otherwise blocking D$ request
// - Stores: write address/data into Store Buffer, then complete in ROB
// - Single in-flight load, no load queue
module lsu #(
    parameter config_pkg::cfg_t Cfg           = config_pkg::EmptyCfg,
    parameter int unsigned      ROB_IDX_WIDTH = 6,
    parameter int unsigned      SB_DEPTH      = 16,
    parameter int unsigned      SB_IDX_WIDTH  = $clog2(SB_DEPTH)
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

    input  logic                ld_rsp_valid_i,
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
    output logic [              4:0] wb_ecause_o,
    output logic                     wb_is_mispred_o,
    output logic [     Cfg.PLEN-1:0] wb_redirect_pc_o,
    input  logic                     wb_ready_i
);

  // ---------------------------------------------------------
  // Exception cause (RISC-V standard)
  // ---------------------------------------------------------
  localparam logic [4:0] EXC_LD_ADDR_MISALIGNED = 5'd4;
  localparam logic [4:0] EXC_LD_ACCESS_FAULT = 5'd5;
  localparam logic [4:0] EXC_ST_ADDR_MISALIGNED = 5'd6;

  // ---------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------
  function automatic logic is_misaligned(input decode_pkg::lsu_op_e op,
                                         input logic [Cfg.PLEN-1:0] addr);
    unique case (op)
      LSU_LB, LSU_LBU, LSU_SB: is_misaligned = 1'b0;
      LSU_LH, LSU_LHU, LSU_SH: is_misaligned = addr[0];
      LSU_LW, LSU_LWU, LSU_SW: is_misaligned = |addr[1:0];
      LSU_LD, LSU_SD:          is_misaligned = |addr[2:0];
      default:                 is_misaligned = 1'b0;
    endcase
  endfunction

  // Forwarded data extraction (assumes store data aligns to byte_off=0)
  function automatic logic [Cfg.XLEN-1:0] extract_fwd(input logic [Cfg.XLEN-1:0] data,
                                                      input decode_pkg::lsu_op_e op);
    logic sign;
    begin
      extract_fwd = '0;
      unique case (op)
        LSU_LB: begin
          sign        = data[7];
          extract_fwd = {{(Cfg.XLEN - 8) {sign}}, data[7:0]};
        end
        LSU_LBU: begin
          extract_fwd = {{(Cfg.XLEN - 8) {1'b0}}, data[7:0]};
        end
        LSU_LH: begin
          sign        = data[15];
          extract_fwd = {{(Cfg.XLEN - 16) {sign}}, data[15:0]};
        end
        LSU_LHU: begin
          extract_fwd = {{(Cfg.XLEN - 16) {1'b0}}, data[15:0]};
        end
        LSU_LW: begin
          if (Cfg.XLEN == 32) begin
            extract_fwd = data[31:0];
          end else begin
            sign        = data[31];
            extract_fwd = {{(Cfg.XLEN - 32) {sign}}, data[31:0]};
          end
        end
        LSU_LWU: begin
          if (Cfg.XLEN == 32) begin
            extract_fwd = data[31:0];
          end else begin
            extract_fwd = {{(Cfg.XLEN - 32) {1'b0}}, data[31:0]};
          end
        end
        LSU_LD: begin
          extract_fwd = data;
        end
        default: extract_fwd = data;
      endcase
    end
  endfunction

  // ---------------------------------------------------------
  // Internal signals
  // ---------------------------------------------------------
  logic is_load;
  logic is_store;
  logic [Cfg.XLEN-1:0] eff_addr_xlen;
  logic [Cfg.PLEN-1:0] eff_addr;
  logic misaligned;
  logic [Cfg.XLEN-1:0] fwd_data;

  assign is_load       = uop_i.is_load;
  assign is_store      = uop_i.is_store;

  assign eff_addr_xlen = rs1_data_i + uop_i.imm;
  assign eff_addr      = eff_addr_xlen[Cfg.PLEN-1:0];
  assign misaligned    = is_misaligned(uop_i.lsu_op, eff_addr);

  assign fwd_data      = extract_fwd(sb_load_data_i, uop_i.lsu_op);

  // ---------------------------------------------------------
  // State machine
  // ---------------------------------------------------------
  typedef enum logic [1:0] {
    S_IDLE,
    S_LD_REQ,
    S_LD_RSP,
    S_RESP
  } lsu_state_e;

  lsu_state_e state_q, state_d;

  // In-flight load request
  logic                [     Cfg.PLEN-1:0] req_addr_q;
  decode_pkg::lsu_op_e                     req_op_q;
  logic                [ROB_IDX_WIDTH-1:0] req_tag_q;

  // Response holding regs
  logic                [     Cfg.XLEN-1:0] resp_data_q;
  logic                                    resp_exc_q;
  logic                [              4:0] resp_ecause_q;
  logic                [ROB_IDX_WIDTH-1:0] resp_tag_q;

  // ---------------------------------------------------------
  // Output defaults
  // ---------------------------------------------------------
  assign req_ready_o = (state_q == S_IDLE) && !flush_i;

  // Store buffer execute write (pulse when accepting a store)
  assign sb_ex_valid_o = (state_q == S_IDLE) && req_valid_i && req_ready_o && is_store && !misaligned;
  assign sb_ex_sb_id_o = sb_id_i;
  assign sb_ex_addr_o = eff_addr;
  assign sb_ex_data_o = rs2_data_i;
  assign sb_ex_op_o = uop_i.lsu_op;
  assign sb_ex_rob_idx_o = rob_tag_i;

  // Store-buffer forwarding address (only meaningful for incoming load)
  assign sb_load_addr_o = (state_q == S_IDLE && req_valid_i && is_load) ? eff_addr : '0;
  assign sb_load_rob_idx_o = rob_tag_i;

  // D-Cache load port
  assign ld_req_valid_o = (state_q == S_LD_REQ);
  assign ld_req_addr_o = req_addr_q;
  assign ld_req_op_o = req_op_q;

  assign ld_rsp_ready_o = (state_q == S_LD_RSP);

  // Writeback (to CDB/ROB)
  assign wb_valid_o = (state_q == S_RESP);
  assign wb_rob_idx_o = resp_tag_q;
  assign wb_data_o = resp_data_q;
  assign wb_exception_o = resp_exc_q;
  assign wb_ecause_o = resp_ecause_q;
  assign wb_is_mispred_o = 1'b0;
  assign wb_redirect_pc_o = '0;

  // ---------------------------------------------------------
  // Next-state logic
  // ---------------------------------------------------------
  always_comb begin
    state_d = state_q;

    unique case (state_q)
      S_IDLE: begin
        if (req_valid_i && req_ready_o) begin
          if (is_store) begin
            state_d = S_RESP;
          end else if (is_load) begin
            if (misaligned) begin
              state_d = S_RESP;
            end else if (sb_load_hit_i) begin
              state_d = S_RESP;
            end else begin
              state_d = S_LD_REQ;
            end
          end else begin
            state_d = S_RESP;
          end
        end
      end

      S_LD_REQ: begin
        if (ld_req_ready_i) begin
          state_d = S_LD_RSP;
        end
      end

      S_LD_RSP: begin
        if (ld_rsp_valid_i) begin
          state_d = S_RESP;
        end
      end

      S_RESP: begin
        if (wb_ready_i) begin
          state_d = S_IDLE;
        end
      end

      default: state_d = S_IDLE;
    endcase

    if (flush_i) begin
      state_d = S_IDLE;
    end
  end

  // ---------------------------------------------------------
  // Sequential logic
  // ---------------------------------------------------------
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      state_q       <= S_IDLE;

      req_addr_q    <= '0;
      req_op_q      <= decode_pkg::LSU_LW;
      req_tag_q     <= '0;

      resp_data_q   <= '0;
      resp_exc_q    <= 1'b0;
      resp_ecause_q <= '0;
      resp_tag_q    <= '0;
    end else begin
      state_q <= state_d;

      if (flush_i) begin
        resp_data_q   <= '0;
        resp_exc_q    <= 1'b0;
        resp_ecause_q <= '0;
        resp_tag_q    <= '0;
      end else begin
        // Accept new request
        if (state_q == S_IDLE && req_valid_i && req_ready_o) begin
          if (is_load && !misaligned && !sb_load_hit_i) begin
            req_addr_q <= eff_addr;
            req_op_q   <= uop_i.lsu_op;
            req_tag_q  <= rob_tag_i;
          end

          if (is_store) begin
            resp_tag_q    <= rob_tag_i;
            resp_data_q   <= '0;
            resp_exc_q    <= misaligned;
            resp_ecause_q <= misaligned ? EXC_ST_ADDR_MISALIGNED : '0;
          end else if (is_load) begin
            resp_tag_q <= rob_tag_i;
            if (misaligned) begin
              resp_data_q   <= '0;
              resp_exc_q    <= 1'b1;
              resp_ecause_q <= EXC_LD_ADDR_MISALIGNED;
            end else if (sb_load_hit_i) begin
              resp_data_q   <= fwd_data;
              resp_exc_q    <= 1'b0;
              resp_ecause_q <= '0;
            end
          end else begin
            // Non-LSU op (should not happen): complete without exception
            resp_tag_q    <= rob_tag_i;
            resp_data_q   <= '0;
            resp_exc_q    <= 1'b0;
            resp_ecause_q <= '0;
          end
        end

        // Capture load response
        if (state_q == S_LD_RSP && ld_rsp_valid_i) begin
          resp_tag_q    <= req_tag_q;
          resp_data_q   <= ld_rsp_data_i;
          resp_exc_q    <= ld_rsp_err_i;
          resp_ecause_q <= ld_rsp_err_i ? EXC_LD_ACCESS_FAULT : '0;
        end
      end
    end
  end

endmodule
