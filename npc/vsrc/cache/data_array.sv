module data_array #(
    parameter int unsigned NUM_WAYS = 4,
    parameter int unsigned NUM_BANKS = 4,
    parameter int unsigned SETS_PER_BANK_WIDTH = 8,  // 每个Bank的Set数量的log2
    parameter int unsigned BLOCK_WIDTH = 512  // 缓存块的位宽 (例如 64 Bytes * 8 bits)
) (
    input logic clk_i,
    input logic rst_ni,

    // 读/写共用的地址端口
    input logic [SETS_PER_BANK_WIDTH-1:0] bank_addr_i,  // Bank内的地址 (Index的高位)
    input logic [  $clog2(NUM_BANKS)-1:0] bank_sel_i,   // Bank选择 (Index的低位)

    // 写端口 (用于Cache Fill 或 Store Hit)
    input logic [   NUM_WAYS-1:0] we_way_mask_i,  // 写使能掩码, 决定写哪一路
    input logic [BLOCK_WIDTH-1:0] wdata_i,        // 要写入的数据块

    // 读端口 (组合读)
    output logic [NUM_WAYS-1:0][BLOCK_WIDTH-1:0] rdata_o  // 读出的数据块 (所有Way)
);

  localparam int unsigned SRAM_DATA_WIDTH = BLOCK_WIDTH;

  // 内部连线
  logic [SRAM_DATA_WIDTH-1:0] sram_rdata[NUM_WAYS][NUM_BANKS];
  logic                       sram_we   [NUM_WAYS][NUM_BANKS];

  // --- 实例化 NUM_WAYS * NUM_BANKS 个 SRAM ---
  genvar i, j;
  generate
    for (i = 0; i < NUM_WAYS; i = i + 1) begin : gen_ways
      for (j = 0; j < NUM_BANKS; j = j + 1) begin : gen_banks

        // 写使能逻辑
        assign sram_we[i][j] = we_way_mask_i[i] && (bank_sel_i == j);

        sram #(
            .DATA_WIDTH(SRAM_DATA_WIDTH),
            .ADDR_WIDTH(SETS_PER_BANK_WIDTH)
        ) data_sram_inst (
            .clk_i  (clk_i),
            .rst_ni (rst_ni),
            .we_i   (sram_we[i][j]),
            .addr_i (bank_addr_i),
            .wdata_i(wdata_i),
            .rdata_o(sram_rdata[i][j])
        );
      end
    end
  endgenerate

  // --- 读数据选择 (Mux) ---
  always_comb begin
    for (int i = 0; i < NUM_WAYS; i++) begin
      // 从正确的Bank选择数据
      rdata_o[i] = sram_rdata[i][bank_sel_i];
    end
  end

endmodule : data_array
