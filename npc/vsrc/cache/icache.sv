import config_pkg::*;
import global_config_pkg::*;

module icache #(
    parameter config_pkg::cfg_t Cfg = config_pkg::EmptyCfg
) (
    input logic clk_i,
    input logic rst_ni,

    // IFU Interface
    input  global_config_pkg::ifu2icache_req_t ifu_req_i,
    output global_config_pkg::icache2ifu_rsp_t ifu_rsp_o,

    //FTQ Interface
    input  global_config_pkg::ftq2icache_req_t ftq_req_i,
    output global_config_pkg::icache2ftq_rsp_t ftq_rsp_o,

    // Memory Interface
    input  global_config_pkg::mem2icache_rsp_t mem_rsp_i,
    output global_config_pkg::icache2mem_req_t mem_req_o
);
  // --- Refill 逻辑信号 ---
  logic [                               Cfg.ICACHE_SET_ASSOC-1:0] refill_way_mask;
  logic [                             Cfg.ICACHE_INDEX_WIDTH-1:0] refill_index;
  logic [Cfg.ICACHE_INDEX_WIDTH-$clog2(Cfg.ICACHE_NUM_BANKS)-1:0] refill_bank_addr;
  logic [                       $clog2(Cfg.ICACHE_NUM_BANKS)-1:0] refill_bank_sel;
  logic [                               Cfg.ICACHE_TAG_WIDTH-1:0] refill_tag;
  logic                                                           refill_valid;

  logic [Cfg.ICACHE_SET_ASSOC-1:0][Cfg.ICACHE_TAG_WIDTH-1:0] line1_tags_data, line2_tags_data;
  logic [Cfg.ICACHE_SET_ASSOC-1:0] line1_tags_valid, line2_tags_valid;
  tag_array #(
      .NUM_WAYS(Cfg.ICACHE_SET_ASSOC),
      .NUM_BANKS(Cfg.ICACHE_NUM_BANKS),
      .SETS_PER_BANK_WIDTH($clog2(Cfg.ICACHE_NUM_SETS / Cfg.ICACHE_NUM_BANKS)),
      .TAG_WIDTH(Cfg.ICACHE_TAG_WIDTH)
  ) i_tag_array (
      .clk_i (clk_i),
      .rst_ni(rst_ni),

      // 读端口 A (用于 Line 1)
      .bank_addr_ra_i (addr1_bank_addr),
      .bank_sel_ra_i  (addr1_bank_sel),
      .rdata_tag_a_o  (line1_tags_data),
      .rdata_valid_a_o(line1_tags_valid),

      // 读端口 B (用于 Line 2)
      .bank_addr_rb_i (addr2_bank_addr),
      .bank_sel_rb_i  (addr2_bank_sel),
      .rdata_tag_b_o  (line2_tags_data),
      .rdata_valid_b_o(line2_tags_valid),

      // 写端口 (用于 Refill)
      .we_way_mask_i(refill_way_mask),
      .w_bank_addr_i(refill_bank_addr),
      .w_bank_sel_i (refill_bank_sel),
      .wdata_tag_i  (refill_tag),
      .wdata_valid_i(refill_valid)
  );

  logic [Cfg.ICACHE_SET_ASSOC-1:0][Cfg.ICACHE_LINE_WIDTH-1:0]
      line1_data_all_ways, line2_data_all_ways;

  assign refill_bank_addr = refill_index[Cfg.ICACHE_INDEX_WIDTH-1 : $clog2(Cfg.ICACHE_NUM_BANKS)];
  assign refill_bank_sel  = refill_index[$clog2(Cfg.ICACHE_NUM_BANKS)-1:0];
  data_array #(
      .NUM_WAYS(Cfg.ICACHE_SET_ASSOC),
      .NUM_BANKS(Cfg.ICACHE_NUM_BANKS),
      .SETS_PER_BANK_WIDTH($clog2(Cfg.ICACHE_NUM_SETS / Cfg.ICACHE_NUM_BANKS)),
      .BLOCK_WIDTH(Cfg.ICACHE_LINE_WIDTH)
  ) i_data_array (
      .clk_i (clk_i),
      .rst_ni(rst_ni),

      // 读端口 A (用于 Line 1)
      .bank_addr_ra_i(addr1_bank_addr),
      .bank_sel_ra_i(addr1_bank_sel),
      .rdata_a_o(line1_data_all_ways),  // [NUM_WAYS-1:0][LINE_WIDTH-1:0]

      // 读端口 B (用于 Line 2)
      .bank_addr_rb_i(addr2_bank_addr),
      .bank_sel_rb_i(addr2_bank_sel),
      .rdata_b_o(line2_data_all_ways),

      // 写端口 (用于 Refill)
      .we_way_mask_i(refill_way_mask),
      .w_bank_addr_i(refill_bank_addr),
      .w_bank_sel_i(refill_bank_sel),
      .wdata_i(mem_rsp_i.data)
  );

  // --- LFSR 替换策略信号 ---
  logic                                    lfsr_en;
  logic [$clog2(Cfg.ICACHE_SET_ASSOC)-1:0] replace_way_index;

  // LFSR 替换策略
  lfsr #(
      .LfsrWidth(4),
      .OutWidth ($clog2(Cfg.ICACHE_SET_ASSOC))
  ) i_lfsr (
      .clk_i(clk_i),
      .rst_ni(rst_ni),
      .en_i(lfsr_en),  // 当需要替换时
      .out_o(replace_way_index)
  );

  // =================================================================
  //  地址分解与跨行检测 (Address Decomposition & Cross-Line Detection)
  // =================================================================

  // 如果本次fetch请求跨越了两个cache line，则需要特殊处理
  logic cross_line_fetch;
  // 在不同cache line的指令地址
  logic [Cfg.VLEN-1:0] addr1_vaddr, addr2_vaddr;
  logic [Cfg.ICACHE_INDEX_WIDTH-1:0] addr1_index, addr2_index;
  logic [Cfg.ICACHE_TAG_WIDTH-1:0] addr1_tag, addr2_tag;
  logic [Cfg.ICACHE_INDEX_WIDTH-$clog2(Cfg.ICACHE_NUM_BANKS)-1:0] addr1_bank_addr, addr2_bank_addr;
  logic [$clog2(Cfg.ICACHE_NUM_BANKS)-1:0] addr1_bank_sel, addr2_bank_sel;

  logic [Cfg.ICACHE_TAG_WIDTH-1:0] ifu_tag[Cfg.INSTR_PER_FETCH];
  logic [Cfg.ICACHE_INDEX_WIDTH-1:0] ifu_index[Cfg.INSTR_PER_FETCH];
  logic [Cfg.ICACHE_OFFSET_WIDTH-1:0] ifu_offset[Cfg.INSTR_PER_FETCH];

  always_comb begin
    addr1_vaddr = ifu_req_i.vaddr[0];
    addr2_vaddr = '0;
    cross_line_fetch = 1'b0;

    for (int i = 0; i < Cfg.INSTR_PER_FETCH; i++) begin
      ifu_tag[i] = ifu_req_i.vaddr[i][Cfg.PLEN-1-:Cfg.ICACHE_TAG_WIDTH];
      ifu_index[i] = ifu_req_i.vaddr[i][Cfg.PLEN-Cfg.ICACHE_TAG_WIDTH-1-:Cfg.ICACHE_INDEX_WIDTH];
      ifu_offset[i] = ifu_req_i.vaddr[i][Cfg.ICACHE_OFFSET_WIDTH-1:0];
      if (ifu_index[i] != ifu_index[0] && !cross_line_fetch) begin
        cross_line_fetch = 1'b1;
        addr2_vaddr = ifu_req_i.vaddr[i];
      end
    end
  end

  assign addr1_tag = addr1_vaddr[Cfg.PLEN-1-:Cfg.ICACHE_TAG_WIDTH];
  assign addr1_index = addr1_vaddr[Cfg.PLEN-Cfg.ICACHE_TAG_WIDTH-1-:Cfg.ICACHE_INDEX_WIDTH];
  assign addr1_bank_addr = addr1_index[Cfg.ICACHE_INDEX_WIDTH-1 : $clog2(Cfg.ICACHE_NUM_BANKS)];
  assign addr1_bank_sel = addr1_index[$clog2(Cfg.ICACHE_NUM_BANKS)-1:0];
  // 仅当跨行fetch时才使用addr2_vaddr
  assign addr2_tag = addr2_vaddr[Cfg.PLEN-1-:Cfg.ICACHE_TAG_WIDTH];
  assign addr2_index = addr2_vaddr[Cfg.PLEN-Cfg.ICACHE_TAG_WIDTH-1-:Cfg.ICACHE_INDEX_WIDTH];
  assign addr2_bank_addr = addr2_index[Cfg.ICACHE_INDEX_WIDTH-1 : $clog2(Cfg.ICACHE_NUM_BANKS)];
  assign addr2_bank_sel = addr2_index[$clog2(Cfg.ICACHE_NUM_BANKS)-1:0];

  // =================================================================
  //  hit/miss检测 (Hit/Miss Detection)
  // =================================================================

  logic [Cfg.ICACHE_SET_ASSOC-1:0] line1_hit_ways, line2_hit_ways;
  logic line1_hit, line2_hit, ifu_all_hit;
  logic [Cfg.ICACHE_SET_ASSOC_WIDTH-1:0] line1_hit_way, line2_hit_way;

  priority_encoder #(
      .WIDTH(Cfg.ICACHE_SET_ASSOC)
  ) line1_pe (
      .in (line1_hit_ways),
      .out(line1_hit_way)
  );
  priority_encoder #(
      .WIDTH(Cfg.ICACHE_SET_ASSOC)
  ) line2_pe (
      .in (line2_hit_ways),
      .out(line2_hit_way)
  );

  always_comb begin
    line1_hit_ways = '0;
    line2_hit_ways = '0;
    for (int i = 0; i < Cfg.ICACHE_SET_ASSOC; i++) begin
      line1_hit_ways[i] = line1_tags_valid[i] && (line1_tags_data[i] == addr1_tag);
      line2_hit_ways[i] = line2_tags_valid[i] && (line2_tags_data[i] == addr2_tag);
    end

    line1_hit   = |line1_hit_ways;
    line2_hit   = |line2_hit_ways;

    // 最终的Hit判断
    ifu_all_hit = line1_hit && (!cross_line_fetch || line2_hit);
    // $display("ICache Lookup: Cross_line_fetch=%b, line1_hit=%b, line2_hit=%b, ifu_all_hit=%b",
    //  cross_line_fetch, line1_hit, line2_hit, ifu_all_hit);
  end

  // =================================================================
  //  指令数据组装 (Instruction Data Assembly)
  // =================================================================
  logic [Cfg.ICACHE_LINE_WIDTH-1:0] line1_data, line2_data;

  assign line1_data = line1_data_all_ways[line1_hit_way];
  assign line2_data = line2_data_all_ways[line2_hit_way];

  function automatic logic [Cfg.ILEN-1:0] select_from_line(
      input logic [Cfg.ICACHE_LINE_WIDTH-1:0] line_data,
      input logic [Cfg.ICACHE_OFFSET_WIDTH-1:0] instr_offset);
    localparam int unsigned BIT_OFFSET_WIDTH = $clog2(Cfg.ICACHE_LINE_WIDTH);
    logic [BIT_OFFSET_WIDTH - 1:0] bit_offset = instr_offset * 8;
    select_from_line = line_data[bit_offset+:Cfg.ILEN];
  endfunction

  always_comb begin
    ifu_rsp_o.data = '0;
    for (int i = 0; i < Cfg.INSTR_PER_FETCH; i++) begin
      // 判断这条指令地址属于 Line 1 还是 Line 2
      if (!cross_line_fetch || (ifu_index[i] == addr1_index)) begin
        // 从 Line 1 数据中提取
        ifu_rsp_o.data[i] = select_from_line(line1_data, ifu_offset[i]);
      end else begin
        // 从 Line 2 数据中提取
        ifu_rsp_o.data[i] = select_from_line(line2_data, ifu_offset[i]);
      end
    end
  end

  // =================================================================
  //  主状态机(FSM)
  // =================================================================
  typedef enum logic [2:0] {
    IDLE,
    LOOKUP,
    MISS_WAIT,
    REFILL
  } state_t;

  state_t state_q, state_d;
  // 保存 Miss 上下文的寄存器
  logic [Cfg.PLEN-1:0] miss_addr1_q, miss_addr1_d;
  logic [Cfg.PLEN-1:0] miss_addr2_q, miss_addr2_d;
  logic miss_line1_pending_q, miss_line1_pending_d;
  logic miss_line2_pending_q, miss_line2_pending_d;
  logic is_prefetch_miss_q, is_prefetch_miss_d;

  // 时序逻辑：所有状态寄存器
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      state_q <= IDLE;
      miss_addr1_q <= '0;
      miss_addr2_q <= '0;
      miss_line1_pending_q <= 1'b0;
      miss_line2_pending_q <= 1'b0;
      is_prefetch_miss_q <= 1'b0;
    end else begin
      state_q <= state_d;
      miss_addr1_q <= miss_addr1_d;
      miss_addr2_q <= miss_addr2_d;
      miss_line1_pending_q <= miss_line1_pending_d;
      miss_line2_pending_q <= miss_line2_pending_d;
      is_prefetch_miss_q <= is_prefetch_miss_d;
    end
    $display("ICache State: %0d", state_q);
  end

  always_comb begin
    // --- 默认输出 和 默认状态保持 ---
    state_d = state_q;  // 默认保持当前状态
    // 默认保持所有状态寄存器
    miss_addr1_d = miss_addr1_q;
    miss_addr2_d = miss_addr2_q;
    miss_line1_pending_d = miss_line1_pending_q;
    miss_line2_pending_d = miss_line2_pending_q;
    is_prefetch_miss_d = is_prefetch_miss_q;

    // 默认接口信号
    ifu_rsp_o.ready = 1'b0;
    ftq_rsp_o.ready = 1'b0;
    mem_req_o.valid = 1'b0;
    lfsr_en = 1'b0;

    // Refill 信号清零
    refill_way_mask = '0;
    refill_valid = 1'b0;
    refill_tag = '0;
    refill_index = '0;

    // --- FTQ 预取请求处理 ---
    if (ftq_req_i.valid && (state_q == IDLE)) begin
      ftq_rsp_o.ready = 1'b1;
      // TODO:需要一个MSHR来处理FTQ的Miss，这里暂时省略
    end

    case (state_q)
      IDLE: begin
        ifu_rsp_o.ready = 1'b0;  // 默认不响应IFU
        ftq_rsp_o.ready = 1'b1;  // 空闲时，接收FTQ预取

        if (ifu_req_i.valid) begin
          state_d = LOOKUP;
        end
        // (注意: mem_rsp_i.valid 也可能在 IDLE 时到达，如果是预取完成)
        if (mem_rsp_i.valid && mem_rsp_i.is_prefetch) begin
          // (这是一个预取数据的返回)
          is_prefetch_miss_d = 1'b1;
          // 需要保存预取的地址信息才能填充
          // TODO: ... 假设 prefetch MSHR 提供了地址
          state_d = REFILL;  // 去填充预取的数据
        end
      end

      LOOKUP: begin
        if (ifu_all_hit) begin
          $display("ICache Hit! Cross_line_fetch=%b, line1_hit=%b, line2_hit=%b", cross_line_fetch,
                   line1_hit, line2_hit);
          ifu_rsp_o.ready = 1'b1;

          if (ifu_req_i.valid) begin
            state_d = LOOKUP;
          end else begin
            state_d = IDLE;
          end
        end else begin
          // Miss
          ifu_rsp_o.ready = 1'b0;

          // 保存 Miss 请求信息
          miss_line1_pending_d = !line1_hit;
          miss_line2_pending_d = cross_line_fetch && !line2_hit;
          miss_addr1_d = addr1_vaddr;
          miss_addr2_d = addr2_vaddr;
          is_prefetch_miss_d = 1'b0;  // 这是来自IFU的Miss

          // 发起内存请求
          mem_req_o.valid = 1'b1;
          // 总是先请求 Line 1 (如果L1 Miss), 否则请求 Line 2
          mem_req_o.addr = (!line1_hit) ? addr1_vaddr : addr2_vaddr;
          mem_req_o.is_prefetch = 1'b0;

          $display("Requesting memory Addr: 0x%h, Valid=%b", mem_req_o.addr, mem_req_o.valid);
          if (mem_rsp_i.ready) begin  // 假设内存总线接受了
            state_d = MISS_WAIT;
            $display("mem_req_o: Valid=%b, Addr=0x%h", mem_req_o.valid, mem_req_o.addr);
            $display("mem_rsp_i: ready=%b, Valid=%b", mem_rsp_i.ready, mem_rsp_i.valid);
          end else begin
            state_d = LOOKUP;  // 等待内存响应
          end
        end
      end

      MISS_WAIT: begin
        if (mem_rsp_i.valid) begin
          // 数据返回
          // (注意: 我们假设这不是一个乱序的预取返回)
          if (mem_rsp_i.is_prefetch == is_prefetch_miss_q) begin
            state_d = REFILL;
          end else begin
            // 收到意外的响应 (例如，一个预取响应)
            // 保持 MISS_WAIT，等待我们正在等待的数据
            state_d = MISS_WAIT;
          end
        end
      end

      REFILL: begin
        // --- 1. 驱动SRAM/TagArray的写端口 ---
        // 此时 `mem_rsp_i.valid` 为高, `mem_rsp_i.data` 包含数据
        lfsr_en = 1'b1;  // 触发LFSR，得到 replace_way_index
        refill_way_mask = (1 << replace_way_index);
        refill_valid = 1'b1;  // 写入有效位

        // 确定我们刚刚填充的是哪一行
        if (miss_line1_pending_q) begin
          // 我们刚刚接收了 Line 1 的数据
          refill_tag   = miss_addr1_q[Cfg.PLEN-1-:Cfg.ICACHE_TAG_WIDTH];
          refill_index = miss_addr1_q[Cfg.PLEN-Cfg.ICACHE_TAG_WIDTH-1-:Cfg.ICACHE_INDEX_WIDTH];
        end else if (miss_line2_pending_q) begin
          // 我们刚刚接收了 Line 2 的数据 (Line 1 肯定命中了)
          refill_tag   = miss_addr2_q[Cfg.PLEN-1-:Cfg.ICACHE_TAG_WIDTH];
          refill_index = miss_addr2_q[Cfg.PLEN-Cfg.ICACHE_TAG_WIDTH-1-:Cfg.ICACHE_INDEX_WIDTH];
        end

        // --- 2. 决定下一个状态 ---
        if (is_prefetch_miss_q) begin
          // 如果这是一个预取 (Prefetch)
          state_d = IDLE;
          miss_line1_pending_d = 1'b0;
          miss_line2_pending_d = 1'b0;
        end else begin
          // 这是一个 IFU Miss

          if (miss_line1_pending_q && miss_line2_pending_q) begin
            // --- Case A: 跨行Miss，刚收到 Line 1 ---
            // 我们刚填充了 Line 1, 但 Line 2 仍然 pending.

            // 立即发起 Line 2 的请求
            mem_req_o.valid = 1'b1;
            mem_req_o.addr = miss_addr2_q;  // 请求 Line 2
            mem_req_o.is_prefetch = 1'b0;

            if (mem_rsp_i.ready) begin  // 检查内存是否能接受新请求
              state_d = MISS_WAIT;  // 回到 MISS_WAIT, 等待 Line 2
              miss_line1_pending_d = 1'b0;  // Line 1 已处理
              miss_line2_pending_d = 1'b1;  // Line 2 仍在处理 (状态保持)
            end else begin
              // 内存忙，停在 REFILL 状态，下一拍重试 L2 请求
              state_d = REFILL;
              // 保持 pending 标志不变 (d = q)
            end
          end else begin
            // --- Case B: 单行Miss, 或 跨行Miss的Line 2 刚收到 ---
            // 所有的 Miss 都已处理完毕。

            state_d = LOOKUP;  // 返回 LOOKUP 状态
            // `ifu_req_i` 仍然是 valid (被`ready=0`反压)
            // 下一拍，LOOKUP 状态会重新评估，此时 `ifu_all_hit` 将为真
            // 然后 `ifu_rsp_o.ready` 会被置1，完成IFU请求。

            // 清空所有 pending 标志
            miss_line1_pending_d = 1'b0;
            miss_line2_pending_d = 1'b0;
          end
        end
      end
      default: begin
        $display("ICache State: ILLEGAL (%h)! Back to IDLE", state_q);
        state_d = IDLE;
      end
    endcase
  end

endmodule : icache

