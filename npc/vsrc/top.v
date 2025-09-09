module cpu(
  input clk,
  input rst
);
  wire [`ysyx_25050141_IF_TO_DE_WIDTH - 1:0] IF_to_DE_bus;
  wire [`ysyx_25050141_DE_TO_EX_WIDTH - 1:0] DE_to_EX_bus;
  wire [`ysyx_25050141_EX_TO_IF_WIDTH - 1:0] EX_to_IF_bus;
  wire [`ysyx_25050141_EX_TO_ME_WIDTH - 1:0] EX_to_ME_bus;
  wire [`ysyx_25050141_ME_TO_DE_WIDTH - 1:0] ME_to_DE_bus;
  ysyx_25050141_IF IF(
    .clk(clk),
    .rst(rst),
    .IF_to_DE_bus(IF_to_DE_bus),
    .EX_to_IF_bus(EX_to_IF_bus)
  );
  ysyx_25050141_DE DE(
    .clk(clk),
    .rst(rst),
    .IF_to_DE_bus(IF_to_DE_bus),
    .ME_to_DE_bus(ME_to_DE_bus),
    .DE_to_EX_bus(DE_to_EX_bus)
  );
  ysyx_25050141_EX EX(
    .DE_to_EX_bus(DE_to_EX_bus),
    .EX_to_ME_bus(EX_to_ME_bus),
    .EX_to_IF_bus(EX_to_IF_bus)
  );
  ysyx_25050141_ME ME(
    .clk(clk),
    .EX_to_ME_bus(EX_to_ME_bus),
    .ME_to_DE_bus(ME_to_DE_bus)
  );
endmodule
