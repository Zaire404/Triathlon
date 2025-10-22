module tag_array #(
    parameter int unsigned NUM_WAYS = 4,
    parameter int unsigned NUM_BANKS = 4,
    parameter int unsigned SETS_PER_BANK_WIDTH = 8,  // 每个Bank的Set数量的log2, 比如 256组/Bank -> 8
    parameter int unsigned TAG_WIDTH = 20,  // Tag的位宽
    parameter int unsigned VALID_WIDTH = 1  // 有效位的位宽 (可以扩展为 Dirty+Valid 等元数据)
) (
    input logic clk_i,
    input logic rst_ni,

    // 读/写共用的地址端口 (来自CPU的Index)
    input logic [SETS_PER_BANK_WIDTH-1:0] bank_addr_i,  // Bank内的地址 (Index的高位)
    input logic [  $clog2(NUM_BANKS)-1:0] bank_sel_i,   // Bank选择 (Index的低位)

    // 写端口 (用于Cache Fill)
    input logic [   NUM_WAYS-1:0] we_way_mask_i,  // 写使能掩码, 决定写哪一路
    input logic [  TAG_WIDTH-1:0] wdata_tag_i,    // 要写入的Tag
    input logic [VALID_WIDTH-1:0] wdata_valid_i,  // 要写入的Valid

    // 读端口 (用于Cache Lookup, 组合读)
    output logic [NUM_WAYS-1:0][  TAG_WIDTH-1:0] rdata_tag_o,   // 读出的Tag (所有Way)
    output logic [NUM_WAYS-1:0][VALID_WIDTH-1:0] rdata_valid_o  // 读出的Valid (所有Way)
);

  // 每个SRAM存储的数据 = Tag + Valid
  localparam int unsigned SRAM_DATA_WIDTH = TAG_WIDTH + VALID_WIDTH;

  // 内部连线
  logic [SRAM_DATA_WIDTH-1:0] sram_wdata;
  logic [SRAM_DATA_WIDTH-1:0] sram_rdata [NUM_WAYS][NUM_BANKS];
  logic                       sram_we    [NUM_WAYS][NUM_BANKS];

  // 待写入的数据
  assign sram_wdata = {wdata_tag_i, wdata_valid_i};

  // --- 实例化 NUM_WAYS * NUM_BANKS 个 SRAM ---
  genvar i, j;
  generate
    for (i = 0; i < NUM_WAYS; i = i + 1) begin : gen_ways
      for (j = 0; j < NUM_BANKS; j = j + 1) begin : gen_banks

        // 写使能逻辑：
        // 当 (1) 这一路(Way)被选中 且 (2) 这一个Bank被选中时，才使能SRAM的写
        assign sram_we[i][j] = we_way_mask_i[i] && (bank_sel_i == j);

        sram #(
            .DATA_WIDTH(SRAM_DATA_WIDTH),
            .ADDR_WIDTH(SETS_PER_BANK_WIDTH)
        ) tag_sram_inst (
            .clk_i  (clk_i),
            .rst_ni (rst_ni),
            .we_i   (sram_we[i][j]),
            .addr_i (bank_addr_i),      // 所有的SRAM都使用相同的Bank内地址
            .wdata_i(sram_wdata),       // 所有的SRAM都连接到相同的写数据
            .rdata_o(sram_rdata[i][j])
        );
      end
    end
  endgenerate

  // --- 读数据选择 (Mux) ---
  // 读操作是组合的。`bank_addr_i`会使所有Bank的SRAM都读出数据。
  // 我们需要根据 `bank_sel_i` 来选择正确的Bank的数据作为输出。
  always_comb begin
    for (int i = 0; i < NUM_WAYS; i++) begin
      // sram_rdata[i] 是一个 [NUM_BANKS-1:0] 的数组
      // 我们只选择 `bank_sel_i` 对应的那个Bank的数据
      {rdata_tag_o[i], rdata_valid_o[i]} = sram_rdata[i][bank_sel_i];
    end
  end

endmodule : tag_array
