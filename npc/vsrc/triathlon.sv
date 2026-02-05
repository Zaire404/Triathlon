import global_config_pkg::*;

module triathlon #(
    // Config
    parameter config_pkg::cfg_t Cfg = global_config_pkg::Cfg
) (
    // Subsystem Clock
    input logic clk_i,
    // Asynchronous reset active low
    input logic rst_ni,

    // -----------------------------
    // I-Cache miss/refill interface
    // -----------------------------
    output logic                                  icache_miss_req_valid_o,
    input  logic                                  icache_miss_req_ready_i,
    output logic [                  Cfg.PLEN-1:0] icache_miss_req_paddr_o,
    output logic [Cfg.ICACHE_SET_ASSOC_WIDTH-1:0] icache_miss_req_victim_way_o,
    output logic [    Cfg.ICACHE_INDEX_WIDTH-1:0] icache_miss_req_index_o,

    input  logic                                  icache_refill_valid_i,
    output logic                                  icache_refill_ready_o,
    input  logic [                  Cfg.PLEN-1:0] icache_refill_paddr_i,
    input  logic [Cfg.ICACHE_SET_ASSOC_WIDTH-1:0] icache_refill_way_i,
    input  logic [     Cfg.ICACHE_LINE_WIDTH-1:0] icache_refill_data_i,

    // -----------------------------
    // D-Cache miss/refill/writeback
    // -----------------------------
    output logic                                  dcache_miss_req_valid_o,
    input  logic                                  dcache_miss_req_ready_i,
    output logic [                  Cfg.PLEN-1:0] dcache_miss_req_paddr_o,
    output logic [Cfg.DCACHE_SET_ASSOC_WIDTH-1:0] dcache_miss_req_victim_way_o,
    output logic [    Cfg.DCACHE_INDEX_WIDTH-1:0] dcache_miss_req_index_o,

    input  logic                                  dcache_refill_valid_i,
    output logic                                  dcache_refill_ready_o,
    input  logic [                  Cfg.PLEN-1:0] dcache_refill_paddr_i,
    input  logic [Cfg.DCACHE_SET_ASSOC_WIDTH-1:0] dcache_refill_way_i,
    input  logic [     Cfg.DCACHE_LINE_WIDTH-1:0] dcache_refill_data_i,

    output logic                             dcache_wb_req_valid_o,
    input  logic                             dcache_wb_req_ready_i,
    output logic [             Cfg.PLEN-1:0] dcache_wb_req_paddr_o,
    output logic [Cfg.DCACHE_LINE_WIDTH-1:0] dcache_wb_req_data_o
);

  // --------------
  // Frontend
  // --------------
  logic fe_ibuf_valid;
  logic fe_ibuf_ready;
  logic [Cfg.INSTR_PER_FETCH-1:0][Cfg.ILEN-1:0] fe_ibuf_instrs;
  logic [Cfg.PLEN-1:0] fe_ibuf_pc;

  logic backend_flush;
  logic [Cfg.PLEN-1:0] backend_redirect_pc;

  frontend #(
      .Cfg(Cfg)
  ) u_frontend (
      .clk_i,
      .rst_ni,

      .ibuffer_valid_o(fe_ibuf_valid),
      .ibuffer_ready_i(fe_ibuf_ready),
      .ibuffer_data_o (fe_ibuf_instrs),
      .ibuffer_pc_o   (fe_ibuf_pc),

      .flush_i      (backend_flush),
      .redirect_pc_i(backend_redirect_pc),

      .miss_req_valid_o     (icache_miss_req_valid_o),
      .miss_req_ready_i     (icache_miss_req_ready_i),
      .miss_req_paddr_o     (icache_miss_req_paddr_o),
      .miss_req_victim_way_o(icache_miss_req_victim_way_o),
      .miss_req_index_o     (icache_miss_req_index_o),

      .refill_valid_i(icache_refill_valid_i),
      .refill_ready_o(icache_refill_ready_o),
      .refill_paddr_i(icache_refill_paddr_i),
      .refill_way_i  (icache_refill_way_i),
      .refill_data_i (icache_refill_data_i)
  );

  // --------------
  // Backend
  // --------------
  backend #(
      .Cfg(Cfg)
  ) u_backend (
      .clk_i,
      .rst_ni,
      .flush_from_backend(1'b0),

      .frontend_ibuf_valid (fe_ibuf_valid),
      .frontend_ibuf_ready (fe_ibuf_ready),
      .frontend_ibuf_instrs(fe_ibuf_instrs),
      .frontend_ibuf_pc    (fe_ibuf_pc),

      .backend_flush_o      (backend_flush),
      .backend_redirect_pc_o(backend_redirect_pc),

      .dcache_miss_req_valid_o(dcache_miss_req_valid_o),
      .dcache_miss_req_ready_i(dcache_miss_req_ready_i),
      .dcache_miss_req_paddr_o(dcache_miss_req_paddr_o),
      .dcache_miss_req_victim_way_o(dcache_miss_req_victim_way_o),
      .dcache_miss_req_index_o(dcache_miss_req_index_o),

      .dcache_refill_valid_i(dcache_refill_valid_i),
      .dcache_refill_ready_o(dcache_refill_ready_o),
      .dcache_refill_paddr_i(dcache_refill_paddr_i),
      .dcache_refill_way_i  (dcache_refill_way_i),
      .dcache_refill_data_i (dcache_refill_data_i),

      .dcache_wb_req_valid_o(dcache_wb_req_valid_o),
      .dcache_wb_req_ready_i(dcache_wb_req_ready_i),
      .dcache_wb_req_paddr_o(dcache_wb_req_paddr_o),
      .dcache_wb_req_data_o (dcache_wb_req_data_o)
  );
endmodule : triathlon
