module backend #(
    parameter config_pkg::cfg_t Cfg = config_pkg::EmptyCfg
) (
    input logic clk,
    input logic rst_ni,
    input logic flush_from_backend,
    input logic frontend_ibuf_valid,
    output logic frontend_ibuf_ready,
    input logic [Cfg.INSTR_PER_FETCH-1:0][Cfg.ILEN-1:0] frontend_ibuf_instrs,
    input logic [Cfg.PLEN-1:0] frontend_ibuf_pc
);

  logic decode_ibuf_valid;
  logic decode_ibuf_ready;
  logic [Cfg.INSTR_PER_FETCH-1:0][Cfg.ILEN-1:0] decode_ibuf_instrs;
  logic [Cfg.INSTR_PER_FETCH-1:0][Cfg.PLEN-1:0] decode_ibuf_pcs;
  ibuffer #(
      .Cfg         (Cfg),
      .IB_DEPTH    (16),
      .DECODE_WIDTH(Cfg.INSTR_PER_FETCH)  // 先等于 fetch 宽度
  ) u_ibuffer (
      .clk_i (clk_i),
      .rst_ni(rst_ni),

      .fe_valid_i (frontend_ibuf_valid),
      .fe_ready_o (frontend_ibuf_ready),
      .fe_instrs_i(frontend_ibuf_instrs),
      .fe_pc_i    (frontend_ibuf_pc),

      .ibuf_valid_o (decode_ibuf_valid),
      .ibuf_ready_i (decode_ibuf_ready),
      .ibuf_instrs_o(decode_ibuf_instrs),
      .ibuf_pcs_o   (decode_ibuf_pcs),

      .flush_i(flush_from_backend)
  );


endmodule
