// vsrc/frontend/ifu.sv
/*  Instruction Fetch Unit
    职责
    1.与BPU握手，管理PC寄存器，同时如果后端有冲刷以及重定向需求则更新PC寄存器，已重定向的更新为最高优先级
    2.使用PC向Icache请求指令
    3.处理Icache响应并将数据发送至Ibuffer
*/
import global_config_pkg::*;
module ifu #(
    parameter config_pkg::cfg_t Cfg = config_pkg::EmptyCfg
) (
    input logic clk,
    input logic rst,

    //--- 1.BPU握手接口 ---
    output handshake_t                ifu2bpu_handshake_o,    // IFU -> BPU: 握手信号
    input  handshake_t                bpu2ifu_handshake_i,    // BPU -> IFU: 握手信号
    output logic       [Cfg.PLEN-1:0] ifu2bpu_pc_o,           // IFU -> BPU: 当前的PC值
    input  logic       [Cfg.PLEN-1:0] bpu2ifu_predicted_pc_i, // BPU -> IFU: 预测的PC值

    //--- 2.ICache请求接口 ---
    output handshake_t ifu2icache_req_handshake_o,  // IFU -> ICache: 握手信号
    input handshake_t icache2ifu_rsp_handshake_i,  // ICache -> IFU: 握手信号
    output logic [Cfg.VLEN-1:0] ifu2icache_req_addr_o,  // IFU -> ICache: 请求的指令地址
    input  logic [Cfg.INSTR_PER_FETCH-1:0][Cfg.ILEN-1:0] icache2ifu_rsp_data_i, // ICache -> IFU: 响应的指令数据
    output logic flush_icache_o,  // IFU -> ICache: 冲刷信号

    //--- 3.Ibuffer响应接口 ---
    output logic ifu_ibuffer_rsp_valid_o,  // IFU -> IBuffer: "我有有效的指令数据"
    output logic [Cfg.PLEN-1:0] ifu_ibuffer_rsp_pc_o,  // IFU -> IBuffer: fetch group的pc
    input  logic                      ibuffer_ifu_rsp_ready_i, // IBuffer -> IFU: "我准备好接收你的指令数据了"
    output logic [Cfg.INSTR_PER_FETCH-1:0][Cfg.ILEN-1:0] ifu_ibuffer_rsp_data_o, // IFU -> IBuffer: "这是你请求的指令数据"

    //--- 4.后端冲刷/重定向接口 ---
    input logic                flush_i,       // 后端 -> IFU: 冲刷信号
    input logic [Cfg.PLEN-1:0] redirect_pc_i  // 后端 -> IFU: 重定向PC地址
);

  // =================================================================
  // 状态定义 (用于perf统计)
  // =================================================================
  typedef enum logic [1:0] {
    S_START = 2'd0,
    S_WAIT_ICACHE = 2'd1,
    S_WAIT_IBUFFER = 2'd2
  } state_t;

  state_t current_state;

  // =================================================================
  // PC 生成与 FTQ
  // =================================================================
  logic [Cfg.PLEN-1:0] pc_gen_q;

  logic                ftq_push_valid;
  logic                ftq_push_ready;
  logic [Cfg.PLEN-1:0] ftq_push_pc;

  logic                ftq_issue_valid;
  logic                ftq_issue_ready;
  logic [Cfg.PLEN-1:0] ftq_issue_pc;

  logic                ftq_complete_fire;
  logic [Cfg.PLEN-1:0] ftq_head_pc;
  logic                ftq_head_valid;
  logic                ftq_pending_issued;

  fetch_target_queue #(
      .Cfg(Cfg)
  ) u_ftq (
      .clk(clk),
      .rst(rst),
      .flush_i(flush_i),

      .push_valid(ftq_push_valid),
      .push_ready(ftq_push_ready),
      .push_pc(ftq_push_pc),

      .issue_valid(ftq_issue_valid),
      .issue_ready(ftq_issue_ready),
      .issue_pc(ftq_issue_pc),

      .complete_fire(ftq_complete_fire),
      .head_pc(ftq_head_pc),
      .head_valid(ftq_head_valid),
      .pending_issued_o(ftq_pending_issued)
  );

  always_ff @(posedge clk) begin
    if (rst) begin
      pc_gen_q <= 'h80000000;
    end else if (flush_i) begin
      pc_gen_q <= redirect_pc_i;
    end else if (ftq_push_valid && ftq_push_ready && bpu2ifu_handshake_i.valid) begin
      pc_gen_q <= bpu2ifu_predicted_pc_i;
    end
`ifdef TRIATHLON_VERBOSE
    $display("pc_gen: %h", pc_gen_q);
    $display("ftq_push_valid: %b", ftq_push_valid);
    $display("ftq_issue_valid: %b", ftq_issue_valid);
    $display("ftq_issue_ready: %b", ftq_issue_ready);
    $display("ftq_head_pc: %h", ftq_head_pc);
    $display("inflight_count: %0d", inflight_count_q);
    $display("resp_count: %0d", resp_count_q);
    $display("icache_resp_valid: %b", icache_resp_valid);
    $display("resp_out_valid: %b", resp_out_valid);
    $display("resp_out_pc: %h", resp_out_pc);
    $display("ibuffer_ready: %b", ibuffer_ifu_rsp_ready_i);
    $display("ifu_ibuffer_valid: %b", ifu_ibuffer_rsp_valid_o);
    $display("current_state: %d", current_state);
    $display("\n");
`endif
  end

  // =================================================================
  // BPU 接口
  // =================================================================
  assign ifu2bpu_pc_o = pc_gen_q;
  assign ftq_push_pc = pc_gen_q;
  assign ftq_push_valid = !flush_i && bpu2ifu_handshake_i.valid;

  assign ifu2bpu_handshake_o.valid = ftq_push_valid;
  assign ifu2bpu_handshake_o.ready = ftq_push_ready;

  // =================================================================
  // ICache 请求
  // =================================================================
  assign flush_icache_o = flush_i;
  assign ifu2icache_req_addr_o = ftq_issue_pc;
  assign ifu2icache_req_handshake_o.valid = ftq_issue_valid && ftq_issue_ready && !flush_i;
  assign ifu2icache_req_handshake_o.ready = ftq_issue_ready;

  logic icache_resp_valid;
  assign icache_resp_valid = icache2ifu_rsp_handshake_i.valid && !flush_i;

  // =================================================================
  // In-flight 请求队列 (追踪请求对应 PC)
  // =================================================================
  localparam int unsigned INFLIGHT_DEPTH = (Cfg.FTQ_DEPTH > 1) ? Cfg.FTQ_DEPTH : 2;
  localparam int unsigned INFLIGHT_PTR_W = (INFLIGHT_DEPTH > 1) ? $clog2(INFLIGHT_DEPTH) : 1;

  logic [INFLIGHT_DEPTH-1:0][Cfg.PLEN-1:0] inflight_pc_q;
  logic [INFLIGHT_PTR_W-1:0] inflight_head_q;
  logic [INFLIGHT_PTR_W-1:0] inflight_tail_q;
  logic [INFLIGHT_PTR_W:0] inflight_count_q;

  logic inflight_enq;
  logic inflight_deq;

  logic [INFLIGHT_PTR_W-1:0] inflight_head_next;
  logic [INFLIGHT_PTR_W-1:0] inflight_tail_next;

  assign inflight_head_next = (inflight_head_q == INFLIGHT_DEPTH - 1) ? '0 : (inflight_head_q + 1'b1);
  assign inflight_tail_next = (inflight_tail_q == INFLIGHT_DEPTH - 1) ? '0 : (inflight_tail_q + 1'b1);

  // =================================================================
  // 响应 FIFO (2-entry, fall-through)
  // =================================================================
  localparam int unsigned RESP_DEPTH = INFLIGHT_DEPTH;
  localparam int unsigned RESP_PTR_W = (RESP_DEPTH > 1) ? $clog2(RESP_DEPTH) : 1;

  logic [RESP_DEPTH-1:0][Cfg.PLEN-1:0] resp_pc_q;
  logic [RESP_DEPTH-1:0][Cfg.INSTR_PER_FETCH-1:0][Cfg.ILEN-1:0] resp_data_q;
  logic [RESP_PTR_W-1:0] resp_head_q;
  logic [RESP_PTR_W-1:0] resp_tail_q;
  logic [RESP_PTR_W:0] resp_count_q;

  logic resp_enq;
  logic resp_deq;

  logic [RESP_PTR_W-1:0] resp_head_next;
  logic [RESP_PTR_W-1:0] resp_tail_next;

  assign resp_head_next = (resp_head_q == RESP_DEPTH - 1) ? '0 : (resp_head_q + 1'b1);
  assign resp_tail_next = (resp_tail_q == RESP_DEPTH - 1) ? '0 : (resp_tail_q + 1'b1);

  // =================================================================
  // Issue / Response 控制
  // =================================================================
  logic [RESP_PTR_W:0] resp_free;
  logic can_issue;
  logic issue_fire;

  assign resp_free = RESP_DEPTH - resp_count_q;
  assign can_issue = (inflight_count_q < resp_free);
  assign ftq_issue_ready = icache2ifu_rsp_handshake_i.ready && can_issue && !flush_i;
  assign issue_fire = ftq_issue_valid && ftq_issue_ready;

  assign inflight_enq = issue_fire;
  assign inflight_deq = icache_resp_valid;

  // PC for incoming response
  logic [Cfg.PLEN-1:0] resp_in_pc;
  assign resp_in_pc = inflight_pc_q[inflight_head_q];

  // =================================================================
  // 响应输出 (fall-through)
  // =================================================================
  logic resp_fifo_empty;
  logic resp_fifo_full;
  logic resp_out_valid;
  logic [Cfg.PLEN-1:0] resp_out_pc;
  logic [Cfg.INSTR_PER_FETCH-1:0][Cfg.ILEN-1:0] resp_out_data;
  logic ibuffer_fire;
  assign resp_fifo_empty = (resp_count_q == 0);
  assign resp_fifo_full = (resp_count_q == RESP_DEPTH);

  assign resp_out_valid = resp_fifo_empty ? icache_resp_valid : 1'b1;
  assign resp_out_pc = resp_fifo_empty ? resp_in_pc : resp_pc_q[resp_head_q];
  assign resp_out_data = resp_fifo_empty ? icache2ifu_rsp_data_i : resp_data_q[resp_head_q];

  assign ifu_ibuffer_rsp_valid_o = resp_out_valid;
  assign ifu_ibuffer_rsp_pc_o = resp_out_pc;
  assign ifu_ibuffer_rsp_data_o = resp_out_data;

  assign ibuffer_fire = resp_out_valid && ibuffer_ifu_rsp_ready_i;
  assign ftq_complete_fire = ibuffer_fire && ftq_head_valid;

  // Enqueue/dequeue control for response FIFO
  assign resp_enq = icache_resp_valid && !(resp_fifo_empty && ibuffer_ifu_rsp_ready_i);
  assign resp_deq = (!resp_fifo_empty) && ibuffer_ifu_rsp_ready_i;

  // =================================================================
  // Sequential: inflight queue
  // =================================================================
  always_ff @(posedge clk) begin
    if (rst) begin
      inflight_head_q <= '0;
      inflight_tail_q <= '0;
      inflight_count_q <= '0;
      inflight_pc_q <= '0;
    end else if (flush_i) begin
      inflight_head_q <= '0;
      inflight_tail_q <= '0;
      inflight_count_q <= '0;
    end else begin
      if (inflight_enq) begin
        inflight_pc_q[inflight_tail_q] <= ftq_issue_pc;
        inflight_tail_q <= inflight_tail_next;
      end
      if (inflight_deq && (inflight_count_q != 0)) begin
        inflight_head_q <= inflight_head_next;
      end
      unique case ({inflight_enq, inflight_deq})
        2'b10: inflight_count_q <= inflight_count_q + 1'b1;
        2'b01: inflight_count_q <= inflight_count_q - 1'b1;
        default: inflight_count_q <= inflight_count_q;
      endcase
    end
  end

  // =================================================================
  // Sequential: response FIFO
  // =================================================================
  always_ff @(posedge clk) begin
    if (rst) begin
      resp_head_q <= '0;
      resp_tail_q <= '0;
      resp_count_q <= '0;
      resp_pc_q <= '0;
      resp_data_q <= '0;
    end else if (flush_i) begin
      resp_head_q <= '0;
      resp_tail_q <= '0;
      resp_count_q <= '0;
    end else begin
      if (resp_enq && !resp_fifo_full) begin
        resp_pc_q[resp_tail_q] <= resp_in_pc;
        resp_data_q[resp_tail_q] <= icache2ifu_rsp_data_i;
        resp_tail_q <= resp_tail_next;
      end
      if (resp_deq && !resp_fifo_empty) begin
        resp_head_q <= resp_head_next;
      end
      unique case ({resp_enq, resp_deq})
        2'b10: resp_count_q <= resp_count_q + 1'b1;
        2'b01: resp_count_q <= resp_count_q - 1'b1;
        default: resp_count_q <= resp_count_q;
      endcase
    end
  end

  // =================================================================
  // perf 状态
  // =================================================================
  always_comb begin
    if (resp_out_valid && !ibuffer_ifu_rsp_ready_i) begin
      current_state = S_WAIT_IBUFFER;
    end else if (inflight_count_q != 0) begin
      current_state = S_WAIT_ICACHE;
    end else begin
      current_state = S_START;
    end
  end
endmodule : ifu
