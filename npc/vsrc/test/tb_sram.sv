module tb_sram #(
    // --- Parameters for this test instance ---
    parameter int unsigned DATA_WIDTH = 32,
    parameter int unsigned ADDR_WIDTH = 8
) (
    // These ports will be directly accessible from the C++ testbench
    input logic clk_i,
    input logic rst_ni,
    input logic we_i,
    input logic [ADDR_WIDTH-1:0] addr_i,  // Corresponds to ADDR_WIDTH=8
    input logic [DATA_WIDTH-1:0] wdata_i,  // Corresponds to DATA_WIDTH=32
    output logic [DATA_WIDTH-1:0] rdata_o  // Corresponds to DATA_WIDTH=32
);

  // --- Instantiate the SRAM module (Device Under Test) ---
  sram #(
      .DATA_WIDTH(DATA_WIDTH),
      .ADDR_WIDTH(ADDR_WIDTH)
  ) DUT (
      // Connect the DUT's ports directly to the testbench's ports
      .clk_i,
      .rst_ni,
      .we_i,
      .addr_i,
      .wdata_i,
      .rdata_o
  );

endmodule
