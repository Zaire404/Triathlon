// vsrc/frontend/ifu.sv
/*
  Instruction Fetch Unit (decoupled)
  1. 与 BPU 握手产生下一拍请求 PC
  2. 与 ICache 保持单 outstanding 请求
  3. 用内部 Fetch Queue 将 ICache 响应与 IBuffer 消费解耦
*/
import global_config_pkg::*;
module ifu #(
    parameter config_pkg::cfg_t Cfg = config_pkg::EmptyCfg
) (
    input logic clk,
    input logic rst,

    //--- 1.BPU握手接口 ---
    output handshake_t                ifu2bpu_handshake_o,
    input  handshake_t                bpu2ifu_handshake_i,
    output logic       [Cfg.PLEN-1:0] ifu2bpu_pc_o,
    input  logic       [Cfg.PLEN-1:0] bpu2ifu_predicted_pc_i,
    input  logic                       bpu2ifu_pred_slot_valid_i,
    input  logic [$clog2(Cfg.INSTR_PER_FETCH)-1:0] bpu2ifu_pred_slot_idx_i,
    input  logic       [Cfg.PLEN-1:0] bpu2ifu_pred_target_i,

    //--- 2.ICache请求接口 ---
    output handshake_t ifu2icache_req_handshake_o,
    input handshake_t icache2ifu_rsp_handshake_i,
    output logic [Cfg.VLEN-1:0] ifu2icache_req_addr_o,
    input  logic [Cfg.INSTR_PER_FETCH-1:0][Cfg.ILEN-1:0] icache2ifu_rsp_data_i,
    output logic flush_icache_o,

    //--- 3.Ibuffer响应接口 ---
    output logic ifu_ibuffer_rsp_valid_o,
    output logic [Cfg.PLEN-1:0] ifu_ibuffer_rsp_pc_o,
    input  logic                      ibuffer_ifu_rsp_ready_i,
    output logic [Cfg.INSTR_PER_FETCH-1:0][Cfg.ILEN-1:0] ifu_ibuffer_rsp_data_o,
    output logic [Cfg.INSTR_PER_FETCH-1:0] ifu_ibuffer_rsp_slot_valid_o,
    output logic [Cfg.INSTR_PER_FETCH-1:0][Cfg.PLEN-1:0] ifu_ibuffer_rsp_pred_npc_o,

    //--- 4.后端冲刷/重定向接口 ---
    input logic                flush_i,
    input logic [Cfg.PLEN-1:0] redirect_pc_i
);

  localparam int unsigned INSTR_BYTES = Cfg.ILEN / 8;
  localparam int unsigned SLOT_IDX_W = (Cfg.INSTR_PER_FETCH > 1) ? $clog2(Cfg.INSTR_PER_FETCH) : 1;
  localparam int unsigned FQ_DEPTH = (Cfg.INSTR_PER_FETCH >= 2) ? Cfg.INSTR_PER_FETCH : 2;
  localparam int unsigned FQ_PTR_W = (FQ_DEPTH > 1) ? $clog2(FQ_DEPTH) : 1;
  localparam int unsigned FQ_CNT_W = $clog2(FQ_DEPTH + 1);

  logic [Cfg.PLEN-1:0] pc_reg;

  logic req_inflight_q;
  logic [Cfg.PLEN-1:0] req_pc_q;
  logic req_pred_slot_valid_q;
  logic [SLOT_IDX_W-1:0] req_pred_slot_idx_q;
  logic [Cfg.PLEN-1:0] req_pred_target_q;

  logic [FQ_DEPTH-1:0][Cfg.PLEN-1:0] fq_pc_q;
  logic [FQ_DEPTH-1:0][Cfg.INSTR_PER_FETCH-1:0][Cfg.ILEN-1:0] fq_data_q;
  logic [FQ_DEPTH-1:0][Cfg.INSTR_PER_FETCH-1:0] fq_slot_valid_q;
  logic [FQ_DEPTH-1:0][Cfg.INSTR_PER_FETCH-1:0][Cfg.PLEN-1:0] fq_pred_npc_q;
  logic [FQ_PTR_W-1:0] fq_head_q;
  logic [FQ_PTR_W-1:0] fq_tail_q;
  logic [FQ_CNT_W-1:0] fq_count_q;

  logic [Cfg.INSTR_PER_FETCH-1:0] rsp_slot_valid_w;
  logic [Cfg.INSTR_PER_FETCH-1:0][Cfg.PLEN-1:0] rsp_pred_npc_w;

  logic fq_empty_w;
  logic fq_full_w;
  logic can_issue_req_w;
  logic req_issue_valid_w;
  logic req_issue_fire_w;
  logic rsp_capture_w;
  logic ibuf_pop_w;
  logic bypass_valid_w;
  logic bypass_fire_w;
  logic rsp_push_fq_w;

  function automatic [FQ_PTR_W-1:0] ptr_inc(input [FQ_PTR_W-1:0] ptr);
    if (ptr == FQ_PTR_W'(FQ_DEPTH - 1)) begin
      ptr_inc = '0;
    end else begin
      ptr_inc = ptr + FQ_PTR_W'(1);
    end
  endfunction

  assign fq_empty_w = (fq_count_q == FQ_CNT_W'(0));
  assign fq_full_w = (fq_count_q == FQ_CNT_W'(FQ_DEPTH));

  assign can_issue_req_w = !flush_i && !req_inflight_q && !fq_full_w;
  assign req_issue_valid_w = can_issue_req_w && bpu2ifu_handshake_i.valid;
  assign req_issue_fire_w = req_issue_valid_w && icache2ifu_rsp_handshake_i.ready;

  assign rsp_capture_w = req_inflight_q && icache2ifu_rsp_handshake_i.valid;
  assign ibuf_pop_w = !fq_empty_w && ibuffer_ifu_rsp_ready_i;
  assign bypass_valid_w = rsp_capture_w && fq_empty_w;
  assign bypass_fire_w = bypass_valid_w && ibuffer_ifu_rsp_ready_i;
  assign rsp_push_fq_w = rsp_capture_w && !bypass_fire_w;

  assign flush_icache_o = flush_i;
  assign ifu2bpu_pc_o = pc_reg;

  assign ifu2bpu_handshake_o.valid = can_issue_req_w;
  assign ifu2bpu_handshake_o.ready = req_issue_fire_w;

  assign ifu2icache_req_handshake_o.valid = req_issue_valid_w;
  assign ifu2icache_req_handshake_o.ready = 1'b1;
  assign ifu2icache_req_addr_o = pc_reg;

  always_comb begin
    for (int i = 0; i < Cfg.INSTR_PER_FETCH; i++) begin
      rsp_slot_valid_w[i] = 1'b1;
      rsp_pred_npc_w[i] = req_pc_q + Cfg.PLEN'(INSTR_BYTES * (i + 1));
      if (req_pred_slot_valid_q) begin
        rsp_slot_valid_w[i] = (i <= int'(req_pred_slot_idx_q));
        if (i > int'(req_pred_slot_idx_q)) begin
          rsp_pred_npc_w[i] = '0;
        end else if (i == int'(req_pred_slot_idx_q)) begin
          rsp_pred_npc_w[i] = req_pred_target_q;
        end
      end
    end
  end

  always_comb begin
    ifu_ibuffer_rsp_valid_o = 1'b0;
    ifu_ibuffer_rsp_pc_o = '0;
    ifu_ibuffer_rsp_data_o = '0;
    ifu_ibuffer_rsp_slot_valid_o = '0;
    ifu_ibuffer_rsp_pred_npc_o = '0;
    if (!fq_empty_w) begin
      ifu_ibuffer_rsp_valid_o = 1'b1;
      ifu_ibuffer_rsp_pc_o = fq_pc_q[fq_head_q];
      ifu_ibuffer_rsp_data_o = fq_data_q[fq_head_q];
      ifu_ibuffer_rsp_slot_valid_o = fq_slot_valid_q[fq_head_q];
      ifu_ibuffer_rsp_pred_npc_o = fq_pred_npc_q[fq_head_q];
    end else if (bypass_valid_w) begin
      ifu_ibuffer_rsp_valid_o = 1'b1;
      ifu_ibuffer_rsp_pc_o = req_pc_q;
      ifu_ibuffer_rsp_data_o = icache2ifu_rsp_data_i;
      ifu_ibuffer_rsp_slot_valid_o = rsp_slot_valid_w;
      ifu_ibuffer_rsp_pred_npc_o = rsp_pred_npc_w;
    end
  end

  always_ff @(posedge clk) begin
    if (rst) begin
      pc_reg <= 'h80000000;
      req_inflight_q <= 1'b0;
      req_pc_q <= '0;
      req_pred_slot_valid_q <= 1'b0;
      req_pred_slot_idx_q <= '0;
      req_pred_target_q <= '0;
      fq_head_q <= '0;
      fq_tail_q <= '0;
      fq_count_q <= '0;
      fq_pc_q <= '0;
      fq_data_q <= '0;
      fq_slot_valid_q <= '0;
      fq_pred_npc_q <= '0;
    end else begin
      if (flush_i) begin
        pc_reg <= redirect_pc_i;
        req_inflight_q <= 1'b0;
        req_pc_q <= redirect_pc_i;
        req_pred_slot_valid_q <= 1'b0;
        req_pred_slot_idx_q <= '0;
        req_pred_target_q <= '0;
        fq_head_q <= '0;
        fq_tail_q <= '0;
        fq_count_q <= '0;
      end else begin
        if (req_issue_fire_w) begin
          req_inflight_q <= 1'b1;
          req_pc_q <= pc_reg;
          req_pred_slot_valid_q <= bpu2ifu_pred_slot_valid_i;
          req_pred_slot_idx_q <= bpu2ifu_pred_slot_idx_i;
          req_pred_target_q <= bpu2ifu_pred_target_i;
          pc_reg <= bpu2ifu_predicted_pc_i;
        end

        if (rsp_push_fq_w) begin
          fq_pc_q[fq_tail_q] <= req_pc_q;
          fq_data_q[fq_tail_q] <= icache2ifu_rsp_data_i;
          fq_slot_valid_q[fq_tail_q] <= rsp_slot_valid_w;
          fq_pred_npc_q[fq_tail_q] <= rsp_pred_npc_w;
          fq_tail_q <= ptr_inc(fq_tail_q);
        end

        if (rsp_capture_w) begin
          req_inflight_q <= 1'b0;
        end

        if (ibuf_pop_w) begin
          fq_head_q <= ptr_inc(fq_head_q);
        end

        unique case ({rsp_push_fq_w, ibuf_pop_w})
          2'b10: fq_count_q <= fq_count_q + FQ_CNT_W'(1);
          2'b01: fq_count_q <= fq_count_q - FQ_CNT_W'(1);
          default: begin
          end
        endcase
      end
    end
`ifdef TRIATHLON_VERBOSE
    $display("pc_reg: %h", pc_reg);
    $display("ifu_req(v/r/fire): %0d/%0d/%0d", req_issue_valid_w,
             icache2ifu_rsp_handshake_i.ready, req_issue_fire_w);
    $display("ifu_rsp(v/cap/bypass/push): %0d/%0d/%0d/%0d",
             icache2ifu_rsp_handshake_i.valid, rsp_capture_w,
             bypass_fire_w, rsp_push_fq_w);
    $display("ifu_fq(cnt/full/empty): %0d/%0d/%0d", fq_count_q, fq_full_w, fq_empty_w);
    $display("ifu_ibuf(v/r/pop): %0d/%0d/%0d", ifu_ibuffer_rsp_valid_o,
             ibuffer_ifu_rsp_ready_i, ibuf_pop_w);
    $display("\n");
`endif
  end

endmodule : ifu
