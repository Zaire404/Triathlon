import global_config_pkg::*;

module triathlon #(
    // Config
    parameter config_pkg::cfg_t Cfg = global_config_pkg::Cfg
) (
    // Subsystem Clock
    input logic clk_i,
    // Asynchronous reset active low
    input logic rst_ni
);

  // --------------
  // Frontend
  // --------------
  frontend #(
      .Cfg(Cfg)
  ) i_frontend (
      .clk_i (clk_i),
      .rst_ni(rst_ni)
  );
endmodule : triathlon
