// Global types for Triathlon
package global_config_pkg;

  import test_config_pkg::*;
  import config_pkg::*;
  import build_config_pkg::*;

  localparam config_pkg::cfg_t Cfg = build_config_pkg::build_config(test_config_pkg::TestCfg);



  // IFU <-> ICache
  typedef struct packed {
    logic                                         valid;  // request is valid
    logic [Cfg.INSTR_PER_FETCH-1:0][Cfg.VLEN-1:0] vaddr;  // virtual address to fetch
  } ifu2icache_req_t;

  typedef struct packed {
    logic                                         ready;
    logic [Cfg.INSTR_PER_FETCH-1:0][Cfg.ILEN-1:0] data;
  } icache2ifu_rsp_t;

  typedef struct packed {
    logic valid;
    logic [Cfg.VLEN-1:0] vaddr;
  } ftq2icache_req_t;

  typedef struct packed {logic ready;} icache2ftq_rsp_t;

  typedef struct packed {
    logic valid;
    logic [Cfg.PLEN-1:0] addr;
    logic is_prefetch;
  } icache2mem_req_t;

  typedef struct packed {
    logic valid;  // 数据有效
    logic ready;  // 接收到信号
    logic [Cfg.ICACHE_LINE_WIDTH-1:0] data;
    logic is_prefetch;
  } mem2icache_rsp_t;
endpackage : global_config_pkg
