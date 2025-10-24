module data_array #(
    parameter int unsigned NUM_WAYS = 4,
    parameter int unsigned NUM_BANKS = 4,
    parameter int unsigned SETS_PER_BANK_WIDTH = 8,  // 每个Bank的Set数量的log2
    parameter int unsigned BLOCK_WIDTH = 512  // 缓存块的位宽 (例如 64 Bytes * 8 bits)
) (
    input logic clk_i,
    input logic rst_ni,

    // --- 读端口 A (用于 Line 1) ---
    input logic [SETS_PER_BANK_WIDTH-1:0] bank_addr_ra_i,  // Bank内读地址 A (Index)
    input logic [$clog2(NUM_BANKS)-1:0] bank_sel_ra_i,  // Bank选择 A
    output logic [NUM_WAYS-1:0][BLOCK_WIDTH-1:0] rdata_a_o,  // 读数据 A (所有Way)

    // --- 读端口 B (用于 Line 2) ---
    input logic [SETS_PER_BANK_WIDTH-1:0] bank_addr_rb_i,  // Bank内读地址 B (Index)
    input logic [$clog2(NUM_BANKS)-1:0] bank_sel_rb_i,  // Bank选择 B
    output logic [NUM_WAYS-1:0][BLOCK_WIDTH-1:0] rdata_b_o,  // 读数据 B (所有Way)

    // --- 写端口 (用于 Refill) ---
    input logic [SETS_PER_BANK_WIDTH-1:0] w_bank_addr_i,  // Bank内写地址 (Index)
    input logic [  $clog2(NUM_BANKS)-1:0] w_bank_sel_i,   // Bank选择 (写)
    input logic [           NUM_WAYS-1:0] we_way_mask_i,  // 写使能掩码, 决定写哪一路
    input logic [        BLOCK_WIDTH-1:0] wdata_i         // 要写入的数据块
);

  localparam int unsigned SRAM_DATA_WIDTH = BLOCK_WIDTH;

  // 内部连线: 每个Way/Bank都需要两组SRAM读数据输出
  logic [SRAM_DATA_WIDTH-1:0] sram_rdata_a[NUM_WAYS][NUM_BANKS];
  logic [SRAM_DATA_WIDTH-1:0] sram_rdata_b[NUM_WAYS][NUM_BANKS];
  logic                       sram_we     [NUM_WAYS][NUM_BANKS];

  // --- 实例化 NUM_WAYS * NUM_BANKS 个 2R1W SRAM ---
  genvar i, j;
  generate
    for (i = 0; i < NUM_WAYS; i = i + 1) begin : gen_ways
      for (j = 0; j < NUM_BANKS; j = j + 1) begin : gen_banks

        // 写使能逻辑: 当 (1) 这一路被选中 且 (2) 这一个Bank被选中时
        assign sram_we[i][j] = we_way_mask_i[i] && (w_bank_sel_i == j);

        sram #(
            .DATA_WIDTH(SRAM_DATA_WIDTH),
            .ADDR_WIDTH(SETS_PER_BANK_WIDTH)
        ) data_sram_inst (
            .clk_i (clk_i),
            .rst_ni(rst_ni),

            // 写端口
            .we_i   (sram_we[i][j]),
            .waddr_i(w_bank_addr_i),  // 所有SRAM共享同一个写地址
            .wdata_i(wdata_i),        // 所有SRAM共享同一个写数据

            // 读端口 A
            .addr_ra_i(bank_addr_ra_i),  // 共享读地址 A
            .rdata_ra_o(sram_rdata_a[i][j]),

            // 读端口 B
            .addr_rb_i(bank_addr_rb_i),  // 共享读地址 B
            .rdata_rb_o(sram_rdata_b[i][j])
        );
      end
    end
  endgenerate

  // --- 读数据选择 (Mux) ---
  always_comb begin
    for (int i = 0; i < NUM_WAYS; i++) begin
      // 从正确的Bank为Port A选择数据
      rdata_a_o[i] = sram_rdata_a[i][bank_sel_ra_i];
      // 从正确的Bank为Port B选择数据
      rdata_b_o[i] = sram_rdata_b[i][bank_sel_rb_i];
    end
  end

endmodule : data_array
