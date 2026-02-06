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

  localparam int unsigned PEND_CNT_W = $clog2(FETCH_WIDTH + 1);
  localparam int unsigned PEND_PTR_W = (FETCH_WIDTH > 1) ? $clog2(FETCH_WIDTH) : 1;

  logic [FETCH_WIDTH-1:0][Cfg.ILEN-1:0] pending_instrs_q, pending_instrs_d;
  logic [Cfg.PLEN-1:0] pending_pc_q, pending_pc_d;
  logic [PEND_CNT_W-1:0] pending_count_q, pending_count_d;
  logic [PEND_PTR_W-1:0] pending_rd_ptr_q, pending_rd_ptr_d;

  logic pending_empty;
  logic fe_fire;

  // 计算当前空间
  logic [CNT_W-1:0] free_slots;
  logic [CNT_W-1:0] effective_free;
  assign free_slots = IB_DEPTH[CNT_W-1:0] - count_q;

  // 上游 ready：flush 时不接，pending 未清空时不接
  assign pending_empty = (pending_count_q == '0);
  assign fe_ready_o = (!flush_i) && pending_empty;
  assign fe_fire = fe_valid_i && fe_ready_o;

  // 下游 valid：只有队列里条目数 >= DECODE_WIDTH 才发一个完整 bundle
  logic can_deq_group;
  assign can_deq_group = (count_q >= DECODE_WIDTH[CNT_W-1:0]);

  assign ibuf_valid_o  = (!flush_i) && can_deq_group;

  // 计算这拍实际 push/pop 数量
  int unsigned push_n;
  int unsigned pop_n;

  logic [PEND_CNT_W-1:0] pending_count_src;
  logic [PEND_PTR_W-1:0] pending_rd_ptr_src;
  logic [FETCH_WIDTH-1:0][Cfg.ILEN-1:0] pending_instrs_src;
  logic [Cfg.PLEN-1:0] pending_pc_src;

  always_comb begin
    int unsigned pending_count_int;
    int unsigned effective_free_int;

    pop_n = (ibuf_valid_o && ibuf_ready_i) ? DECODE_WIDTH : 0;

    pending_count_src = pending_count_q;
    pending_rd_ptr_src = pending_rd_ptr_q;
    pending_instrs_src = pending_instrs_q;
    pending_pc_src = pending_pc_q;
    if (fe_fire) begin
      pending_count_src = FETCH_WIDTH[PEND_CNT_W-1:0];
      pending_rd_ptr_src = '0;
      pending_instrs_src = fe_instrs_i;
      pending_pc_src = fe_pc_i;
    end

    effective_free = free_slots + CNT_W'(pop_n);
    pending_count_int = pending_count_src;
    effective_free_int = effective_free;
    if (pending_count_int <= effective_free_int) begin
      push_n = pending_count_int;
    end else begin
      push_n = effective_free_int;
    end
  end

  // FIFO 控制逻辑
  always_comb begin
    fifo_d   = fifo_q;
    wr_ptr_d = wr_ptr_q;
    rd_ptr_d = rd_ptr_q;
    count_d  = count_q;

    pending_instrs_d = pending_instrs_q;
    pending_pc_d = pending_pc_q;
    pending_count_d = pending_count_q;
    pending_rd_ptr_d = pending_rd_ptr_q;

    if (flush_i) begin
      // flush：清空队列
      wr_ptr_d = '0;
      rd_ptr_d = '0;
      count_d  = '0;
      pending_count_d = '0;
      pending_rd_ptr_d = '0;
    end else begin
      // Load new pending group
      if (fe_fire) begin
        pending_instrs_d = fe_instrs_i;
        pending_pc_d = fe_pc_i;
        pending_count_d = FETCH_WIDTH[PEND_CNT_W-1:0];
        pending_rd_ptr_d = '0;
      end

      // 写入：从 pending 缓冲搬运到 FIFO
      for (int i = 0; i < FETCH_WIDTH; i++) begin
        if (i < push_n) begin
          // 写指针位置 = wr_ptr_q + i（环形）
          fifo_d[PTR_W'(wr_ptr_q + i)].instr = pending_instrs_src[
              ((pending_rd_ptr_src + i) >= FETCH_WIDTH) ?
              (pending_rd_ptr_src + i - FETCH_WIDTH) :
              (pending_rd_ptr_src + i)
          ];
          // 这里假设固定 4 字节指令：pc = base_pc + 4*i
          fifo_d[PTR_W'(wr_ptr_q + i)].pc    = pending_pc_src + (Cfg.ILEN / 8 *
              (((pending_rd_ptr_src + i) >= FETCH_WIDTH) ?
              (pending_rd_ptr_src + i - FETCH_WIDTH) :
              (pending_rd_ptr_src + i))
          );
        end
      end

      if (push_n != 0) begin
        wr_ptr_d = wr_ptr_q + PTR_W'(push_n);
        count_d  = count_d + CNT_W'(push_n);
        pending_rd_ptr_d = pending_rd_ptr_src + PEND_PTR_W'(push_n);
        pending_count_d = pending_count_src - PEND_CNT_W'(push_n);
      end

      // 读出：只在成功发出一个完整 decode bundle 时移动 rd_ptr/count
      if (pop_n != 0) begin
        rd_ptr_d = rd_ptr_q + DECODE_WIDTH[PTR_W-1:0];
        count_d  = count_d - CNT_W'(pop_n);
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
      pending_instrs_q <= '0;
      pending_pc_q <= '0;
      pending_count_q <= '0;
      pending_rd_ptr_q <= '0;
    end else begin
      wr_ptr_q <= wr_ptr_d;
      rd_ptr_q <= rd_ptr_d;
      count_q  <= count_d;
      pending_instrs_q <= pending_instrs_d;
      pending_pc_q <= pending_pc_d;
      pending_count_q <= pending_count_d;
      pending_rd_ptr_q <= pending_rd_ptr_d;
      // TODO: 优化为只写入被更新的那些位置
      fifo_q   <= fifo_d;
    end
  end

endmodule
