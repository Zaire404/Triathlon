// 2R1W Tag Array Module
module tag_array #(
    parameter int unsigned NUM_WAYS = 4,
    parameter int unsigned NUM_BANKS = 4,
    parameter int unsigned SETS_PER_BANK_WIDTH = 8,  // 每个Bank的Set数量的log2, 比如 256组/Bank -> 8
    parameter int unsigned TAG_WIDTH = 20,  // Tag的位宽
    parameter int unsigned VALID_WIDTH = 1  // 有效位的位宽 (可以扩展为 Dirty+Valid 等元数据)
) (
    input logic clk_i,
    input logic rst_ni,

    // --- 读端口 A (用于 Line 1) ---
    input logic [SETS_PER_BANK_WIDTH-1:0] bank_addr_ra_i,  // Bank内读地址 A (Index)
    input logic [$clog2(NUM_BANKS)-1:0] bank_sel_ra_i,  // Bank选择 A
    output logic [NUM_WAYS-1:0][TAG_WIDTH-1:0] rdata_tag_a_o,  // 读出的Tag A
    output logic [NUM_WAYS-1:0][VALID_WIDTH-1:0] rdata_valid_a_o,  // 读出的Valid A

    // --- 读端口 B (用于 Line 2) ---
    input logic [SETS_PER_BANK_WIDTH-1:0] bank_addr_rb_i,  // Bank内读地址 B (Index)
    input logic [$clog2(NUM_BANKS)-1:0] bank_sel_rb_i,  // Bank选择 B
    output logic [NUM_WAYS-1:0][TAG_WIDTH-1:0] rdata_tag_b_o,  // 读出的Tag B
    output logic [NUM_WAYS-1:0][VALID_WIDTH-1:0] rdata_valid_b_o,  // 读出的Valid B

    // --- 写端口 (用于 Refill) ---
    input logic [SETS_PER_BANK_WIDTH-1:0] w_bank_addr_i,   // Bank内写地址 (Index)
    input logic [  $clog2(NUM_BANKS)-1:0] w_bank_sel_i,    // Bank选择 (写)
    input logic [   NUM_WAYS-1:0] we_way_mask_i,   // 写使能掩码
    input logic [TAG_WIDTH-1:0] wdata_tag_i,  // 要写入的Tag
    input logic [VALID_WIDTH-1:0] wdata_valid_i  // 要写入的Valid
);

  // 每个SRAM存储的数据 = Tag + Valids
  localparam int unsigned SRAM_DATA_WIDTH = TAG_WIDTH + VALID_WIDTH;

  // 内部连线
  logic [SRAM_DATA_WIDTH-1:0] sram_wdata;
  logic [SRAM_DATA_WIDTH-1:0] sram_rdata_a[NUM_WAYS][NUM_BANKS];
  logic [SRAM_DATA_WIDTH-1:0] sram_rdata_b[NUM_WAYS][NUM_BANKS];
  logic                       sram_we     [NUM_WAYS][NUM_BANKS];

  // 待写入的数据
  assign sram_wdata = {wdata_tag_i, wdata_valid_i};

  // --- 实例化 NUM_WAYS * NUM_BANKS 个 2R1W SRAM ---
  genvar i, j;
  generate
    for (i = 0; i < NUM_WAYS; i = i + 1) begin : gen_ways
      for (j = 0; j < NUM_BANKS; j = j + 1) begin : gen_banks

        // 写使能逻辑
        assign sram_we[i][j] = we_way_mask_i[i] && (w_bank_sel_i == j);

        sram #(
            .DATA_WIDTH(SRAM_DATA_WIDTH),
            .ADDR_WIDTH(SETS_PER_BANK_WIDTH)
        ) tag_sram_inst (
            .clk_i (clk_i),
            .rst_ni(rst_ni),

            // 写端口
            .we_i   (sram_we[i][j]),
            .waddr_i(w_bank_addr_i),
            .wdata_i(sram_wdata),

            // 读端口 A
            .addr_ra_i (bank_addr_ra_i),
            .rdata_ra_o(sram_rdata_a[i][j]),

            // 读端口 B
            .addr_rb_i (bank_addr_rb_i),
            .rdata_rb_o(sram_rdata_b[i][j])
        );
      end
    end
  endgenerate

  // --- 读数据选择 (Mux) A ---
  always_comb begin
    for (int i = 0; i < NUM_WAYS; i++) begin
      // 从 `bank_sel_ra_i` 对应的Bank选择数据
      {rdata_tag_a_o[i], rdata_valid_a_o[i]} = sram_rdata_a[i][bank_sel_ra_i];
      // 从 `bank_sel_rb_i` 对应的Bank选择数据
      {rdata_tag_b_o[i], rdata_valid_b_o[i]} = sram_rdata_b[i][bank_sel_rb_i];
    end
  end

endmodule : tag_array
