// vsrc/include/global_config_pkg.sv
// Global types for Triathlon
package global_config_pkg;

  import test_config_pkg::*;
  import config_pkg::*;
  import build_config_pkg::*;

  localparam config_pkg::cfg_t Cfg = build_config_pkg::build_config(test_config_pkg::TestCfg);

  typedef struct packed {
    logic valid;
    logic ready;
  } handshake_t;

  typedef struct packed {logic [Cfg.PLEN-1:0] pc;} ifu_to_bpu_t;

  typedef struct packed {logic [Cfg.PLEN-1:0] npc;} bpu_to_ifu_t;

  typedef struct packed {
    logic [Cfg.ILEN-1:0] instr;
    logic [Cfg.PLEN-1:0] pc;
  } ibuf_entry_t;

endpackage : global_config_pkg
