// vsrc/frontend/ifu.sv
/*
  Instruction Fetch Unit (decoupled)
  1. 与 BPU 握手产生下一拍请求 PC
  2. 用 request FIFO 将 BPU 预测与 ICache 请求解耦
  3. 用 inflight FIFO 跟踪已发射请求 metadata（替换单 inflight）
  4. 用可复用 bundle FIFO 将 ICache 响应与 IBuffer 消费解耦
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
  localparam int unsigned EPOCH_W = 3;

  // Pending request FIFO (BPU generated).
  localparam int unsigned REQ_DEPTH = (Cfg.INSTR_PER_FETCH >= 2) ? Cfg.INSTR_PER_FETCH : 2;
  localparam int unsigned REQ_PTR_W = (REQ_DEPTH > 1) ? $clog2(REQ_DEPTH) : 1;
  localparam int unsigned REQ_CNT_W = $clog2(REQ_DEPTH + 1);

  // Inflight request FIFO (issued to ICache, waiting for response).
  localparam int unsigned INF_DEPTH = REQ_DEPTH;
  localparam int unsigned INF_PTR_W = (INF_DEPTH > 1) ? $clog2(INF_DEPTH) : 1;
  localparam int unsigned INF_CNT_W = $clog2(INF_DEPTH + 1);

  // Fetch response queue to decouple ICache and IBuffer.
  localparam int unsigned FQ_DEPTH = (Cfg.INSTR_PER_FETCH >= 2) ? Cfg.INSTR_PER_FETCH : 2;
  localparam int unsigned FQ_CNT_W = $clog2(FQ_DEPTH + 1);
  localparam int unsigned FQ_DATA_W = Cfg.PLEN + (Cfg.INSTR_PER_FETCH * Cfg.ILEN) +
                                      Cfg.INSTR_PER_FETCH + (Cfg.INSTR_PER_FETCH * Cfg.PLEN);

  logic [Cfg.PLEN-1:0] pc_reg;
  logic [EPOCH_W-1:0] fetch_epoch_q;

  // Pending FIFO metadata
  logic [REQ_DEPTH-1:0][Cfg.PLEN-1:0] req_pc_fifo_q;
  logic [REQ_DEPTH-1:0] req_pred_slot_valid_fifo_q;
  logic [REQ_DEPTH-1:0][SLOT_IDX_W-1:0] req_pred_slot_idx_fifo_q;
  logic [REQ_DEPTH-1:0][Cfg.PLEN-1:0] req_pred_target_fifo_q;
  logic [REQ_DEPTH-1:0][EPOCH_W-1:0] req_epoch_fifo_q;
  logic [REQ_PTR_W-1:0] req_head_q;
  logic [REQ_PTR_W-1:0] req_tail_q;
  logic [REQ_CNT_W-1:0] req_count_q;

  // Inflight FIFO metadata
  logic [INF_DEPTH-1:0][Cfg.PLEN-1:0] inf_pc_fifo_q;
  logic [INF_DEPTH-1:0] inf_pred_slot_valid_fifo_q;
  logic [INF_DEPTH-1:0][SLOT_IDX_W-1:0] inf_pred_slot_idx_fifo_q;
  logic [INF_DEPTH-1:0][Cfg.PLEN-1:0] inf_pred_target_fifo_q;
  logic [INF_DEPTH-1:0][EPOCH_W-1:0] inf_epoch_fifo_q;
  logic [INF_PTR_W-1:0] inf_head_q;
  logic [INF_PTR_W-1:0] inf_tail_q;
  logic [INF_CNT_W-1:0] inf_count_q;

  // Fetch response queue state exported from bundle FIFO instance.
  logic [FQ_CNT_W-1:0] fq_count_q;
  logic [FQ_DATA_W-1:0] fq_enq_data_w;
  logic [FQ_DATA_W-1:0] fq_deq_data_w;
  logic fq_enq_valid_w;
  logic fq_enq_ready_w;
  logic fq_deq_valid_w;
  logic fq_deq_ready_w;

  logic [Cfg.PLEN-1:0] inf_head_pc_w;
  logic inf_head_pred_slot_valid_w;
  logic [SLOT_IDX_W-1:0] inf_head_pred_slot_idx_w;
  logic [Cfg.PLEN-1:0] inf_head_pred_target_w;
  logic [EPOCH_W-1:0] inf_head_epoch_w;

  logic [Cfg.INSTR_PER_FETCH-1:0] rsp_slot_valid_w;
  logic [Cfg.INSTR_PER_FETCH-1:0][Cfg.PLEN-1:0] rsp_pred_npc_w;

  logic req_fifo_empty_w;
  logic req_fifo_full_w;
  logic inf_fifo_empty_w;
  logic inf_fifo_full_w;
  logic fq_empty_w;
  logic fq_full_w;

  logic can_accept_bpu_w;
  logic req_enq_fire_w;

  logic can_issue_req_w;
  logic req_issue_valid_w;
  logic req_issue_fire_w;

  logic rsp_capture_w;
  logic drop_stale_rsp_w;
  logic rsp_epoch_match_w;
  logic ibuf_pop_w;
  logic rsp_push_fq_w;

  logic [REQ_CNT_W:0] req_outstanding_w;
  logic [FQ_CNT_W:0] storage_budget_w;

  function automatic [REQ_PTR_W-1:0] req_ptr_inc(input [REQ_PTR_W-1:0] ptr);
    if (ptr == REQ_PTR_W'(REQ_DEPTH - 1)) begin
      req_ptr_inc = '0;
    end else begin
      req_ptr_inc = ptr + REQ_PTR_W'(1);
    end
  endfunction

  function automatic [INF_PTR_W-1:0] inf_ptr_inc(input [INF_PTR_W-1:0] ptr);
    if (ptr == INF_PTR_W'(INF_DEPTH - 1)) begin
      inf_ptr_inc = '0;
    end else begin
      inf_ptr_inc = ptr + INF_PTR_W'(1);
    end
  endfunction

  assign req_fifo_empty_w = (req_count_q == REQ_CNT_W'(0));
  assign req_fifo_full_w = (req_count_q == REQ_CNT_W'(REQ_DEPTH));
  assign inf_fifo_empty_w = (inf_count_q == INF_CNT_W'(0));
  assign inf_fifo_full_w = (inf_count_q == INF_CNT_W'(INF_DEPTH));

  assign inf_head_pc_w = inf_pc_fifo_q[inf_head_q];
  assign inf_head_pred_slot_valid_w = inf_pred_slot_valid_fifo_q[inf_head_q];
  assign inf_head_pred_slot_idx_w = inf_pred_slot_idx_fifo_q[inf_head_q];
  assign inf_head_pred_target_w = inf_pred_target_fifo_q[inf_head_q];
  assign inf_head_epoch_w = inf_epoch_fifo_q[inf_head_q];

  always_comb begin
    req_outstanding_w = {1'b0, req_count_q} + {{(REQ_CNT_W + 1 - (INF_CNT_W)){1'b0}}, inf_count_q};
    storage_budget_w = {1'b0, fq_count_q} + {{(FQ_CNT_W + 1 - (INF_CNT_W)){1'b0}}, inf_count_q};
  end

  // BPU side: enqueue requests into pending FIFO when space is available.
  assign can_accept_bpu_w = !flush_i && (!req_fifo_full_w || req_issue_fire_w);
  assign ifu2bpu_pc_o = pc_reg;
  assign ifu2bpu_handshake_o.valid = can_accept_bpu_w;
  assign ifu2bpu_handshake_o.ready = can_accept_bpu_w && bpu2ifu_handshake_i.valid;
  assign req_enq_fire_w = ifu2bpu_handshake_o.valid && ifu2bpu_handshake_o.ready;

  // ICache side: issue oldest pending request.
  assign rsp_epoch_match_w = !inf_fifo_empty_w && (inf_head_epoch_w == fetch_epoch_q);
  assign rsp_capture_w = !inf_fifo_empty_w && icache2ifu_rsp_handshake_i.valid && rsp_epoch_match_w;
  assign drop_stale_rsp_w = icache2ifu_rsp_handshake_i.valid && (!rsp_epoch_match_w);

  // Conservative safety gate:
  // fq_count + inflight_count tracks worst-case buffered responses pressure.
  assign can_issue_req_w = !flush_i && !req_fifo_empty_w && !inf_fifo_full_w &&
                           (storage_budget_w < (FQ_CNT_W + 1)'(FQ_DEPTH));
  assign req_issue_valid_w = can_issue_req_w;
  assign req_issue_fire_w = req_issue_valid_w && icache2ifu_rsp_handshake_i.ready;

  assign flush_icache_o = flush_i;
  assign ifu2icache_req_handshake_o.valid = req_issue_valid_w;
  assign ifu2icache_req_handshake_o.ready = 1'b1;
  assign ifu2icache_req_addr_o = req_pc_fifo_q[req_head_q];

  // IBuffer dequeue and response push decisions via bundle FIFO.
  assign fq_enq_valid_w = rsp_capture_w;
  assign rsp_push_fq_w = fq_enq_valid_w && fq_enq_ready_w;
  assign fq_deq_ready_w = ibuffer_ifu_rsp_ready_i;
  assign ibuf_pop_w = !fq_empty_w && fq_deq_valid_w && fq_deq_ready_w;

  always_comb begin
    for (int i = 0; i < Cfg.INSTR_PER_FETCH; i++) begin
      rsp_slot_valid_w[i] = 1'b1;
      rsp_pred_npc_w[i] = inf_head_pc_w + Cfg.PLEN'(INSTR_BYTES * (i + 1));
      if (inf_head_pred_slot_valid_w) begin
        rsp_slot_valid_w[i] = (i <= int'(inf_head_pred_slot_idx_w));
        if (i > int'(inf_head_pred_slot_idx_w)) begin
          rsp_pred_npc_w[i] = '0;
        end else if (i == int'(inf_head_pred_slot_idx_w)) begin
          rsp_pred_npc_w[i] = inf_head_pred_target_w;
        end
      end
    end
  end

  assign fq_enq_data_w = {inf_head_pc_w, icache2ifu_rsp_data_i, rsp_slot_valid_w, rsp_pred_npc_w};
  assign {ifu_ibuffer_rsp_pc_o, ifu_ibuffer_rsp_data_o, ifu_ibuffer_rsp_slot_valid_o,
          ifu_ibuffer_rsp_pred_npc_o} = fq_deq_data_w;
  assign ifu_ibuffer_rsp_valid_o = fq_deq_valid_w;

  bundle_fifo #(
      .DATA_W(FQ_DATA_W),
      .DEPTH(FQ_DEPTH),
      .BYPASS_EN(1'b1)
  ) u_fetch_queue (
      .clk_i(clk),
      .rst_ni(~rst),
      .flush_i(flush_i),
      .enq_valid_i(fq_enq_valid_w),
      .enq_ready_o(fq_enq_ready_w),
      .enq_data_i(fq_enq_data_w),
      .deq_valid_o(fq_deq_valid_w),
      .deq_ready_i(fq_deq_ready_w),
      .deq_data_o(fq_deq_data_w),
      .count_o(fq_count_q),
      .full_o(fq_full_w),
      .empty_o(fq_empty_w)
  );

  always_ff @(posedge clk) begin
    if (rst) begin
      pc_reg <= 'h80000000;
      fetch_epoch_q <= '0;

      req_pc_fifo_q <= '0;
      req_pred_slot_valid_fifo_q <= '0;
      req_pred_slot_idx_fifo_q <= '0;
      req_pred_target_fifo_q <= '0;
      req_epoch_fifo_q <= '0;
      req_head_q <= '0;
      req_tail_q <= '0;
      req_count_q <= '0;

      inf_pc_fifo_q <= '0;
      inf_pred_slot_valid_fifo_q <= '0;
      inf_pred_slot_idx_fifo_q <= '0;
      inf_pred_target_fifo_q <= '0;
      inf_epoch_fifo_q <= '0;
      inf_head_q <= '0;
      inf_tail_q <= '0;
      inf_count_q <= '0;

    end else begin
      if (flush_i) begin
        pc_reg <= redirect_pc_i;
        fetch_epoch_q <= fetch_epoch_q + EPOCH_W'(1);

        req_head_q <= '0;
        req_tail_q <= '0;
        req_count_q <= '0;

        inf_head_q <= '0;
        inf_tail_q <= '0;
        inf_count_q <= '0;
      end else begin
        if (req_enq_fire_w) begin
          req_pc_fifo_q[req_tail_q] <= pc_reg;
          req_pred_slot_valid_fifo_q[req_tail_q] <= bpu2ifu_pred_slot_valid_i;
          req_pred_slot_idx_fifo_q[req_tail_q] <= bpu2ifu_pred_slot_idx_i;
          req_pred_target_fifo_q[req_tail_q] <= bpu2ifu_pred_target_i;
          req_epoch_fifo_q[req_tail_q] <= fetch_epoch_q;
          req_tail_q <= req_ptr_inc(req_tail_q);
          pc_reg <= bpu2ifu_predicted_pc_i;
        end

        if (req_issue_fire_w) begin
          inf_pc_fifo_q[inf_tail_q] <= req_pc_fifo_q[req_head_q];
          inf_pred_slot_valid_fifo_q[inf_tail_q] <= req_pred_slot_valid_fifo_q[req_head_q];
          inf_pred_slot_idx_fifo_q[inf_tail_q] <= req_pred_slot_idx_fifo_q[req_head_q];
          inf_pred_target_fifo_q[inf_tail_q] <= req_pred_target_fifo_q[req_head_q];
          inf_epoch_fifo_q[inf_tail_q] <= req_epoch_fifo_q[req_head_q];
          inf_tail_q <= inf_ptr_inc(inf_tail_q);
          req_head_q <= req_ptr_inc(req_head_q);
        end

        if (rsp_capture_w) begin
          inf_head_q <= inf_ptr_inc(inf_head_q);
        end

        unique case ({req_enq_fire_w, req_issue_fire_w})
          2'b10: req_count_q <= req_count_q + REQ_CNT_W'(1);
          2'b01: req_count_q <= req_count_q - REQ_CNT_W'(1);
          default: begin
          end
        endcase

        unique case ({req_issue_fire_w, rsp_capture_w})
          2'b10: inf_count_q <= inf_count_q + INF_CNT_W'(1);
          2'b01: inf_count_q <= inf_count_q - INF_CNT_W'(1);
          default: begin
          end
        endcase
      end
    end
`ifdef TRIATHLON_VERBOSE
    $display("pc_reg: %h", pc_reg);
    $display("ifu_bpu(enq_v/enq_r/enq_fire): %0d/%0d/%0d", ifu2bpu_handshake_o.valid,
             ifu2bpu_handshake_o.ready, req_enq_fire_w);
    $display("ifu_req(v/r/fire): %0d/%0d/%0d", req_issue_valid_w,
             icache2ifu_rsp_handshake_i.ready, req_issue_fire_w);
    $display("ifu_rsp(v/cap/drop): %0d/%0d/%0d",
             icache2ifu_rsp_handshake_i.valid, rsp_capture_w, drop_stale_rsp_w);
    $display("ifu_epoch(fetch/head/match): %0d/%0d/%0d",
             fetch_epoch_q, inf_head_epoch_w, rsp_epoch_match_w);
    $display("ifu_reqq(pending/inflight/outstanding): %0d/%0d/%0d", req_count_q,
             inf_count_q, req_outstanding_w);
    $display("ifu_fq(cnt/full/empty): %0d/%0d/%0d", fq_count_q, fq_full_w, fq_empty_w);
    $display("ifu_ibuf(v/r/pop): %0d/%0d/%0d", ifu_ibuffer_rsp_valid_o,
             ibuffer_ifu_rsp_ready_i, ibuf_pop_w);
    $display("\n");
`endif
  end

endmodule : ifu
