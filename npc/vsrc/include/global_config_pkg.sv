// Global types for Triathlon
package global_config_pkg;

  import test_config_pkg::*;
  import config_pkg::*;

  localparam config_pkg::cfg_t Cfg = config_pkg::build_config(test_config_pkg::TestCfg);



  // For Example

  // Exception information
  typedef struct packed {
    logic [Cfg.XLEN-1:0] cause;  // cause of exception
    logic [Cfg.XLEN-1:0] tval;  // additional information of causing exception
    logic [Cfg.GPLEN-1:0] tval2;  // additional info when a guest exception occurs
    logic [31:0] tinst;  // transformed instruction information
    logic gva;  // signals when a guest virtual address is written to tval
    logic valid;
  } exception_t;

  // cache request ports
  // I$ address translation responses
  typedef struct packed {
    logic                fetch_valid;      // address translation valid
    logic [Cfg.PLEN-1:0] fetch_paddr;      // physical address in
    exception_t          fetch_exception;  // exception occurred during fetch
  } icache_arsp_t;

  // I$ address translation requests
  typedef struct packed {
    logic                fetch_req;    // address translation request
    logic [Cfg.VLEN-1:0] fetch_vaddr;  // virtual address out
  } icache_areq_t;

  // I$ data fetch requests
  typedef struct packed {
    logic                req;      // we request a new word
    logic                kill_s1;  // kill the current request
    logic                kill_s2;  // kill the last request
    logic                spec;     // request is speculative
    logic [Cfg.VLEN-1:0] vaddr;    // 1st cycle: index is taken for lookup
  } icache_dreq_t;

  // I$ data fetch responses
  typedef struct packed {
    logic                       ready;  // icache is ready
    logic                       valid;  // signals a valid read
    logic [Cfg.FETCH_WIDTH-1:0] data;   // 2+ cycle out: tag
    logic [Cfg.VLEN-1:0]        vaddr;  // virtual address out
    exception_t                 ex;     // we've encountered an exception
  } icache_drsp_t;

endpackage : global_config_pkg
