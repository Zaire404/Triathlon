module tb_sram #(
    parameter int unsigned DATA_WIDTH = 32,
    parameter int unsigned ADDR_WIDTH = 8
) (
    input logic clk_i,
    input logic rst_ni,

    // --- 写端口 ---
    input logic we_i,
    input logic [ADDR_WIDTH-1:0] waddr_i,  // 写地址
    input logic [DATA_WIDTH-1:0] wdata_i,  // 写数据

    // --- 读端口 A ---
    input  logic [ADDR_WIDTH-1:0] addr_ra_i,  // 读地址 A
    output logic [DATA_WIDTH-1:0] rdata_ra_o, // 读数据 A

    // --- 读端口 B ---
    input  logic [ADDR_WIDTH-1:0] addr_rb_i,  // 读地址 B
    output logic [DATA_WIDTH-1:0] rdata_rb_o  // 读数据 B
);

  // --- 实例化 2R1W SRAM (DUT) ---
  sram #(
      .DATA_WIDTH(DATA_WIDTH),
      .ADDR_WIDTH(ADDR_WIDTH)
  ) DUT (
      .clk_i,
      .rst_ni,

      // 写端口
      .we_i,
      .waddr_i,
      .wdata_i,

      // 读端口 A
      .addr_ra_i,
      .rdata_ra_o,

      // 读端口 B
      .addr_rb_i,
      .rdata_rb_o
  );
endmodule
