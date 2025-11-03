import global_config_pkg::*;

// 使用全局配置 (假设它导入了 test_config_pkg 并构建了 Cfg)
module tb_icache (
    input logic clk_i,
    input logic rst_ni,

    // --- IFU 请求 (输入) ---
    input logic                                         ifu_req_valid_i,
    input logic [Cfg.INSTR_PER_FETCH-1:0][Cfg.VLEN-1:0] ifu_req_vaddr_i,

    // --- IFU 响应 (输出) ---
    output logic                                         ifu_rsp_ready_o,
    output logic [Cfg.INSTR_PER_FETCH-1:0][Cfg.ILEN-1:0] ifu_rsp_data_o,

    // --- FTQ 请求 (输入) ---
    input logic                ftq_req_valid_i,
    input logic [Cfg.VLEN-1:0] ftq_req_vaddr_i,

    // --- FTQ 响应 (输出) ---
    output logic ftq_rsp_ready_o,

    // --- 内存请求 (输出) ---
    output logic                mem_req_valid_o,
    output logic [Cfg.PLEN-1:0] mem_req_addr_o,
    output logic                mem_req_is_prefetch_o,

    // --- 内存响应 (输入) ---
    input logic                             mem_rsp_valid_i,
    input logic                             mem_rsp_ready_i,
    input logic [Cfg.ICACHE_LINE_WIDTH-1:0] mem_rsp_data_i,
    input logic                             mem_rsp_is_prefetch_i
);

  localparam config_pkg::cfg_t Cfg = global_config_pkg::Cfg;

  // 2. 将扁平化的 I/O 打包进 struct
  global_config_pkg::ifu2icache_req_t ifu_req_s;
  global_config_pkg::icache2ifu_rsp_t ifu_rsp_s;
  global_config_pkg::ftq2icache_req_t ftq_req_s;
  global_config_pkg::icache2ftq_rsp_t ftq_rsp_s;
  global_config_pkg::icache2mem_req_t mem_req_s;
  global_config_pkg::mem2icache_rsp_t mem_rsp_s;

  // --- 输入打包 ---
  assign ifu_req_s.valid       = ifu_req_valid_i;
  assign ifu_req_s.vaddr       = ifu_req_vaddr_i;

  assign ftq_req_s.valid       = ftq_req_valid_i;
  assign ftq_req_s.vaddr       = ftq_req_vaddr_i;

  assign mem_rsp_s.valid       = mem_rsp_valid_i;
  assign mem_rsp_s.ready       = mem_rsp_ready_i;
  assign mem_rsp_s.data        = mem_rsp_data_i;
  assign mem_rsp_s.is_prefetch = mem_rsp_is_prefetch_i;


  // --- 输出解包 ---
  assign ifu_rsp_ready_o       = ifu_rsp_s.ready;
  assign ifu_rsp_data_o        = ifu_rsp_s.data;

  assign ftq_rsp_ready_o       = ftq_rsp_s.ready;

  assign mem_req_valid_o       = mem_req_s.valid;
  assign mem_req_addr_o        = mem_req_s.addr;
  assign mem_req_is_prefetch_o = mem_req_s.is_prefetch;


  // 3. 实例化 DUT (Device Under Test)
  icache #(
      .Cfg(Cfg)
  ) DUT (
      .clk_i (clk_i),
      .rst_ni(rst_ni),

      .ifu_req_i(ifu_req_s),
      .ifu_rsp_o(ifu_rsp_s),

      .ftq_req_i(ftq_req_s),
      .ftq_rsp_o(ftq_rsp_s),

      .mem_req_o(mem_req_s),
      .mem_rsp_i(mem_rsp_s)
  );

endmodule : tb_icache
