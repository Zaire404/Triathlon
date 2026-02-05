// vsrc/backend/buffer/ibuffer.sv
module ibuffer #(
    parameter config_pkg::cfg_t Cfg          = config_pkg::EmptyCfg,
    // IBuffer 深度（存多少“单条指令”条目，而不是 fetch group 数）
    parameter int unsigned      IB_DEPTH     = 32,
    // 解码宽度（每拍给 decode 多少条）
    parameter int unsigned      DECODE_WIDTH = Cfg.INSTR_PER_FETCH
) (
    input logic clk_i,
    input logic rst_ni,

    // 来自 frontend（取指前端）的接口：fetch group
    input  logic                                         fe_valid_i,
    output logic                                         fe_ready_o,
    input  logic [Cfg.INSTR_PER_FETCH-1:0][Cfg.ILEN-1:0] fe_instrs_i,
    input  logic [           Cfg.PLEN-1:0]               fe_pc_i,      // 该组第 0 条的 PC

    // 发往 decode 的接口：按 uop/指令粒度输出
    output logic                                  ibuf_valid_o,
    input  logic                                  ibuf_ready_i,
    output logic [DECODE_WIDTH-1:0][Cfg.ILEN-1:0] ibuf_instrs_o,
    output logic [DECODE_WIDTH-1:0][Cfg.PLEN-1:0] ibuf_pcs_o,

    // flush：来自后端（比如 ROB 或 commit）
    input logic flush_i
);
  import global_config_pkg::ibuf_entry_t;
  localparam int unsigned FETCH_WIDTH = Cfg.INSTR_PER_FETCH;
  localparam int unsigned PTR_W = $clog2(IB_DEPTH);
  localparam int unsigned CNT_W = $clog2(IB_DEPTH + 1);
  initial
    assert (IB_DEPTH > 0 && (IB_DEPTH & (IB_DEPTH - 1)) == 0)
    else $fatal(1, "IB_DEPTH must be a power of two.");

  // 存储单条指令的 FIFO
  ibuf_entry_t [IB_DEPTH-1:0] fifo_q;
  ibuf_entry_t [IB_DEPTH-1:0] fifo_d;

  logic [PTR_W-1:0] wr_ptr_q, wr_ptr_d;
  logic [PTR_W-1:0] rd_ptr_q, rd_ptr_d;
  logic [CNT_W-1:0] count_q, count_d;

  // 计算当前空间、是否可一次性接收完整 fetch group
  logic [CNT_W-1:0] free_slots;
  assign free_slots = IB_DEPTH[CNT_W-1:0] - count_q;
  logic can_enq_group;
  assign can_enq_group = (free_slots >= FETCH_WIDTH[CNT_W-1:0]);

  // 上游 ready：flush 时不接，空间不足时不接
  assign fe_ready_o = (!flush_i) && can_enq_group;

  // 下游 valid：只有队列里条目数 >= DECODE_WIDTH 才发一个完整 bundle
  logic can_deq_group;
  assign can_deq_group = (count_q >= DECODE_WIDTH[CNT_W-1:0]);

  assign ibuf_valid_o  = (!flush_i) && can_deq_group;

  // 计算这拍实际 push/pop 数量
  int unsigned push_n;
  int unsigned pop_n;

  always_comb begin
    push_n = (fe_valid_i && fe_ready_o) ? FETCH_WIDTH : 0;
    pop_n  = (ibuf_valid_o && ibuf_ready_i) ? DECODE_WIDTH : 0;
  end

  // FIFO 控制逻辑
  always_comb begin
    fifo_d   = fifo_q;
    wr_ptr_d = wr_ptr_q;
    rd_ptr_d = rd_ptr_q;
    count_d  = count_q;

    if (flush_i) begin
      // flush：清空队列
      wr_ptr_d = '0;
      rd_ptr_d = '0;
      count_d  = '0;
    end else begin
      // 写入：把 fetch group 拆成若干 entry 写进 FIFO
      if (push_n != 0) begin : gen_enqueue
        for (int i = 0; i < FETCH_WIDTH; i++) begin
          // 写指针位置 = wr_ptr_q + i（环形）
          fifo_d[PTR_W'(wr_ptr_q + i)].instr = fe_instrs_i[i];
          // 这里假设固定 4 字节指令：pc = base_pc + 4*i
          fifo_d[PTR_W'(wr_ptr_q + i)].pc    = fe_pc_i + (Cfg.ILEN / 8 * i);
        end

        wr_ptr_d = wr_ptr_q + FETCH_WIDTH[PTR_W-1:0];
        count_d  = count_q + FETCH_WIDTH[CNT_W-1:0];
      end : gen_enqueue

      // 读出：只在成功发出一个完整 decode bundle 时移动 rd_ptr/count
      if (pop_n != 0) begin
        rd_ptr_d = rd_ptr_q + DECODE_WIDTH[PTR_W-1:0];
        count_d  = count_d - DECODE_WIDTH[CNT_W-1:0];
      end
    end
  end

  // 读出到下游（组合读，靠 valid 控制）
  always_comb begin
    for (int j = 0; j < DECODE_WIDTH; j++) begin
      logic [  PTR_W:0] idx = rd_ptr_q + j[PTR_W-1:0];
      logic [PTR_W-1:0] ridx = idx[PTR_W-1:0];

      ibuf_instrs_o[j] = fifo_q[ridx].instr;
      ibuf_pcs_o[j]    = fifo_q[ridx].pc;
    end
  end

  // 寄存器更新
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      wr_ptr_q <= '0;
      rd_ptr_q <= '0;
      count_q  <= '0;
    end else begin
      wr_ptr_q <= wr_ptr_d;
      rd_ptr_q <= rd_ptr_d;
      count_q  <= count_d;
      // TODO: 优化为只写入被更新的那些位置
      fifo_q   <= fifo_d;
    end
  end

endmodule
