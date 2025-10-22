// Testbench wrapper for the tag_array module.

module tb_tag_array #(
    // --- Parameters for this test instance ---
    parameter int unsigned NUM_WAYS_TEST = 4,
    parameter int unsigned NUM_BANKS_TEST = 4,
    parameter int unsigned SETS_PER_BANK_WIDTH_TEST = 8,
    parameter int unsigned TAG_WIDTH_TEST = 20,
    parameter int unsigned VALID_WIDTH_TEST = 1
) (
    // --- Top-level ports for C++ access ---
    input logic clk_i,
    input logic rst_ni,

    // Address ports
    input logic [SETS_PER_BANK_WIDTH_TEST-1:0] bank_addr_i,  // [3:0]
    input logic [  $clog2(NUM_BANKS_TEST)-1:0] bank_sel_i,   // [0:0] (logic)

    // Write ports
    input logic [   NUM_WAYS_TEST-1:0] we_way_mask_i,  // [1:0]
    input logic [  TAG_WIDTH_TEST-1:0] wdata_tag_i,    // [11:0]
    input logic [VALID_WIDTH_TEST-1:0] wdata_valid_i,  // [0:0] (logic)

    // Read ports
    output logic [NUM_WAYS_TEST-1:0][  TAG_WIDTH_TEST-1:0] rdata_tag_o,   // [1:0][11:0]
    output logic [NUM_WAYS_TEST-1:0][VALID_WIDTH_TEST-1:0] rdata_valid_o  // [1:0][0:0]
);

  // --- Instantiate the Device Under Test (DUT) ---
  tag_array #(
      .NUM_WAYS(NUM_WAYS_TEST),
      .NUM_BANKS(NUM_BANKS_TEST),
      .SETS_PER_BANK_WIDTH(SETS_PER_BANK_WIDTH_TEST),
      .TAG_WIDTH(TAG_WIDTH_TEST),
      .VALID_WIDTH(VALID_WIDTH_TEST)
  ) DUT (
      // Connect DUT ports directly to the testbench ports
      .clk_i(clk_i),
      .rst_ni(rst_ni),
      .bank_addr_i(bank_addr_i),
      .bank_sel_i(bank_sel_i),
      .we_way_mask_i(we_way_mask_i),
      .wdata_tag_i(wdata_tag_i),
      .wdata_valid_i(wdata_valid_i),
      .rdata_tag_o(rdata_tag_o),
      .rdata_valid_o(rdata_valid_o)
  );

endmodule
