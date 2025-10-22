module tb_data_array #(
    // --- Parameters for this test instance ---
    parameter int unsigned NUM_WAYS_TEST = 4,
    parameter int unsigned NUM_BANKS_TEST = 4,
    parameter int unsigned SETS_PER_BANK_WIDTH_TEST = 8,
    parameter int unsigned BLOCK_WIDTH_TEST = 512  // 假设 64 字节块 = 512 位
) (
    // --- Top-level ports for C++ access ---
    input logic clk_i,
    input logic rst_ni,

    // Address ports
    input logic [SETS_PER_BANK_WIDTH_TEST-1:0] bank_addr_i,
    input logic [  $clog2(NUM_BANKS_TEST)-1:0] bank_sel_i,

    // Write ports
    input logic [   NUM_WAYS_TEST-1:0] we_way_mask_i,
    input logic [BLOCK_WIDTH_TEST-1:0] wdata_i,

    // Read ports
    output logic [NUM_WAYS_TEST-1:0][BLOCK_WIDTH_TEST-1:0] rdata_o
);

  // --- Instantiate the Device Under Test (DUT) ---
  data_array #(
      .NUM_WAYS(NUM_WAYS_TEST),
      .NUM_BANKS(NUM_BANKS_TEST),
      .SETS_PER_BANK_WIDTH(SETS_PER_BANK_WIDTH_TEST),
      .BLOCK_WIDTH(BLOCK_WIDTH_TEST)
  ) DUT (
      // Connect DUT ports directly to the testbench ports
      .clk_i(clk_i),
      .rst_ni(rst_ni),
      .bank_addr_i(bank_addr_i),
      .bank_sel_i(bank_sel_i),
      .we_way_mask_i(we_way_mask_i),
      .wdata_i(wdata_i),
      .rdata_o(rdata_o)
  );

endmodule
