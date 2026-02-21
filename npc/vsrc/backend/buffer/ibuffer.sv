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
    input  logic [Cfg.INSTR_PER_FETCH-1:0]               fe_slot_valid_i,
    input  logic [Cfg.INSTR_PER_FETCH-1:0][Cfg.PLEN-1:0] fe_pred_npc_i,
    input  logic [Cfg.INSTR_PER_FETCH-1:0][((Cfg.IFU_INF_DEPTH >= 2) ? $clog2(Cfg.IFU_INF_DEPTH) : 1)-1:0] fe_ftq_id_i,
    input  logic [Cfg.INSTR_PER_FETCH-1:0][2:0] fe_fetch_epoch_i,

    // 发往 decode 的接口：按 uop/指令粒度输出
    output logic                                  ibuf_valid_o,
    input  logic                                  ibuf_ready_i,
    output logic [DECODE_WIDTH-1:0][Cfg.ILEN-1:0] ibuf_instrs_o,
    output logic [DECODE_WIDTH-1:0][Cfg.PLEN-1:0] ibuf_pcs_o,
    output logic [DECODE_WIDTH-1:0]               ibuf_slot_valid_o,
    output logic [DECODE_WIDTH-1:0][Cfg.PLEN-1:0] ibuf_pred_npc_o,
    output logic [DECODE_WIDTH-1:0][((Cfg.IFU_INF_DEPTH >= 2) ? $clog2(Cfg.IFU_INF_DEPTH) : 1)-1:0] ibuf_ftq_id_o,
    output logic [DECODE_WIDTH-1:0][2:0] ibuf_fetch_epoch_o,

    // flush：来自后端（比如 ROB 或 commit）
    input logic flush_i
);
  import global_config_pkg::ibuf_entry_t;
  localparam int unsigned FETCH_WIDTH = Cfg.INSTR_PER_FETCH;
  localparam int unsigned INSTR_BYTES = Cfg.ILEN / 8;
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

  // 计算当前空间、输入有效条目数、可否接收
  logic [CNT_W-1:0] free_slots;
  logic [CNT_W-1:0] fe_valid_entry_count_w;
  assign free_slots = IB_DEPTH[CNT_W-1:0] - count_q;
  logic can_enq_group;
  assign can_enq_group = (free_slots >= fe_valid_entry_count_w);

  // 上游 ready：flush 时不接，空间不足时不接
  assign fe_ready_o = (!flush_i) && can_enq_group;

  logic [CNT_W-1:0] avail_count_w;
  logic [CNT_W-1:0] out_count_w;
  logic [CNT_W-1:0] pop_total_w;
  logic [CNT_W-1:0] pop_from_q_w;
  logic [CNT_W-1:0] consume_from_fe_w;
  logic [CNT_W-1:0] push_to_q_w;
  logic [CNT_W-1:0] fe_push_count_w;
  logic fe_fire_w;
  ibuf_entry_t [FETCH_WIDTH-1:0] fe_valid_entries_w;

  assign fe_fire_w = fe_valid_i && fe_ready_o;
  assign fe_push_count_w = fe_fire_w ? fe_valid_entry_count_w : CNT_W'(0);
  assign avail_count_w = count_q + fe_push_count_w;
  assign out_count_w = (avail_count_w >= DECODE_WIDTH[CNT_W-1:0]) ? DECODE_WIDTH[CNT_W-1:0] : avail_count_w;
  assign ibuf_valid_o = (!flush_i) && (out_count_w != CNT_W'(0));
  assign pop_total_w = (ibuf_valid_o && ibuf_ready_i) ? out_count_w : CNT_W'(0);
  assign pop_from_q_w = (pop_total_w >= count_q) ? count_q : pop_total_w;
  assign consume_from_fe_w = pop_total_w - pop_from_q_w;
  assign push_to_q_w = fe_push_count_w - consume_from_fe_w;

  // 压缩 FE 输入：只保留 slot_valid=1 的 entry
  always_comb begin
    int unsigned wr_idx;
    wr_idx = 0;
    fe_valid_entry_count_w = '0;
    for (int i = 0; i < FETCH_WIDTH; i++) begin
      fe_valid_entries_w[i].instr = '0;
      fe_valid_entries_w[i].pc = '0;
      fe_valid_entries_w[i].slot_valid = 1'b0;
      fe_valid_entries_w[i].pred_npc = '0;
      fe_valid_entries_w[i].ftq_id = '0;
      fe_valid_entries_w[i].fetch_epoch = '0;
    end
    if (fe_valid_i) begin
      for (int i = 0; i < FETCH_WIDTH; i++) begin
        if (fe_slot_valid_i[i]) begin
          fe_valid_entries_w[wr_idx].instr = fe_instrs_i[i];
          fe_valid_entries_w[wr_idx].pc = fe_pc_i + Cfg.PLEN'(INSTR_BYTES * i);
          fe_valid_entries_w[wr_idx].slot_valid = 1'b1;
          fe_valid_entries_w[wr_idx].pred_npc = fe_pred_npc_i[i];
          fe_valid_entries_w[wr_idx].ftq_id = fe_ftq_id_i[i];
          fe_valid_entries_w[wr_idx].fetch_epoch = fe_fetch_epoch_i[i];
          wr_idx++;
        end
      end
    end
    fe_valid_entry_count_w = CNT_W'(wr_idx);
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
      // 写入：仅写入未被当拍消费的 FE 有效条目
      if (push_to_q_w != CNT_W'(0)) begin : gen_enqueue
        for (int i = 0; i < FETCH_WIDTH; i++) begin
          if (CNT_W'(i) < push_to_q_w) begin
            fifo_d[PTR_W'(wr_ptr_q + PTR_W'(i))] =
                fe_valid_entries_w[consume_from_fe_w + CNT_W'(i)];
          end
        end

        wr_ptr_d = wr_ptr_q + PTR_W'(push_to_q_w);
      end : gen_enqueue

      if (pop_from_q_w != CNT_W'(0)) begin
        rd_ptr_d = rd_ptr_q + PTR_W'(pop_from_q_w);
      end

      count_d = count_q + push_to_q_w - pop_from_q_w;
    end
  end

  // 读出到下游（支持 partial bundle / elastic merge）
  always_comb begin
    for (int j = 0; j < DECODE_WIDTH; j++) begin
      logic [PTR_W-1:0] ridx;
      logic [CNT_W-1:0] fe_idx;
      ridx = '0;
      fe_idx = '0;
      ibuf_instrs_o[j] = '0;
      ibuf_pcs_o[j] = '0;
      ibuf_slot_valid_o[j] = 1'b0;
      ibuf_pred_npc_o[j] = '0;
      ibuf_ftq_id_o[j] = '0;
      ibuf_fetch_epoch_o[j] = '0;

      if (!flush_i && (CNT_W'(j) < out_count_w)) begin
        if (CNT_W'(j) < count_q) begin
          ridx = PTR_W'(rd_ptr_q + PTR_W'(j));
          ibuf_instrs_o[j] = fifo_q[ridx].instr;
          ibuf_pcs_o[j] = fifo_q[ridx].pc;
          ibuf_slot_valid_o[j] = fifo_q[ridx].slot_valid;
          ibuf_pred_npc_o[j] = fifo_q[ridx].pred_npc;
          ibuf_ftq_id_o[j] = fifo_q[ridx].ftq_id;
          ibuf_fetch_epoch_o[j] = fifo_q[ridx].fetch_epoch;
        end else begin
          fe_idx = CNT_W'(j) - count_q;
          ibuf_instrs_o[j] = fe_valid_entries_w[fe_idx].instr;
          ibuf_pcs_o[j] = fe_valid_entries_w[fe_idx].pc;
          ibuf_slot_valid_o[j] = fe_valid_entries_w[fe_idx].slot_valid;
          ibuf_pred_npc_o[j] = fe_valid_entries_w[fe_idx].pred_npc;
          ibuf_ftq_id_o[j] = fe_valid_entries_w[fe_idx].ftq_id;
          ibuf_fetch_epoch_o[j] = fe_valid_entries_w[fe_idx].fetch_epoch;
        end
      end
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
