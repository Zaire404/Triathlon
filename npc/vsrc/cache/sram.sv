module sram #(
    parameter int unsigned DATA_WIDTH = 64,
    parameter int unsigned ADDR_WIDTH = 10
) (
    input logic clk_i,
    input logic rst_ni,
    input logic we_i,
    input logic [ADDR_WIDTH-1:0] addr_i,
    input logic [DATA_WIDTH-1:0] wdata_i,
    output logic [DATA_WIDTH-1:0] rdata_o
);

  // The Verilator will automatically initialize memory to zeros by default,
  // but for synthesizable code, memory starts up as unknown (X).
  reg [DATA_WIDTH-1:0] mem[(1<<ADDR_WIDTH)];

  // Read logic is combinational to provide data on the same cycle as the address
  // Note: This is a synchronous-read SRAM model.
  assign rdata_o = mem[addr_i];

  // Write logic is synchronous
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      // Optional: Initialize memory to zero on reset
      // for (int i = 0; i < (1 << ADDR_WIDTH); i++) begin
      //   mem[i] <= '0;
      // end
    end else if (we_i) begin
      mem[addr_i] <= wdata_i;
    end
  end

endmodule : sram
