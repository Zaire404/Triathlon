import global_config_pkg::*;
module bpu #(
    parameter config_pkg::cfg_t Cfg = config_pkg::EmptyCfg
) (
    input logic clk_i,
    input logic rst_i,
    
    input ifu_to_bpu_t ifu_to_bpu_i,
    input handshake_t ifu_to_bpu_handshake_i,
    // from IFU
    output handshake_t bpu_to_ifu_handshake_o,
    output bpu_to_ifu_t bpu_to_ifu_o
);
    assign bpu_to_ifu_o.npc = ifu_to_bpu_i.pc + Cfg.FETCH_WIDTH;
    assign bpu_to_ifu_handshake_o.ready = 1'b1;
    assign bpu_to_ifu_handshake_o.valid = 1'b1;
endmodule : bpu
