import config_pkg::*;
import build_config_pkg::*;

module tb_BPU (
    // --- 输入端口  ---
	input logic clk_i,
	input logic rst_i,
	input logic ifu_ready_i,
	input logic ifu_vaild_i,
	input logic[Cfg.XLEN - 1:0] pc_i,
    // --- 输出端口  ---
	input handshake_t bpu_to_ifu_handshake_o,
	output logic [Cfg.XLEN-1:0] npc_o
);
    handshake_t ifu_to_bpu_handshake_i;
	handshake_t bpu_to_ifu_handshake_o,
	bpu_to_ifu_t ifu_to_bpu_i;
	ifu_to_bpu_t bpu_to_ifu_o;
	assign ifu_to_bpu_i.pc = pc;
  bpu #(
      .Cfg(Cfg)
  ) i_BPU (
	.clk_i (clk_i),
	.rst_i (rst_i),
	.ifu_to_bpu_handshake_i (ifu_to_bpu_handshake_i),
    .ifu_to_bpu_i (ifu_to_bpu_i),

	.bpu_to_ifu_handshake_o (bpu_to_ifu_handshake_o),
	.bpu_to_ifu_o (bpu_to_ifu_o)
  );
	assign npc = bpu_to_ifu_o.npc;
endmodule
