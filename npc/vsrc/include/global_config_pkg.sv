// vsrc/include/global_config_pkg.sv
// Global types for Triathlon
package global_config_pkg;

  import test_config_pkg::*;
  import config_pkg::*;
  import build_config_pkg::*;

  localparam config_pkg::cfg_t Cfg = build_config_pkg::build_config(test_config_pkg::TestCfg);

<<<<<<< HEAD
  typedef struct packed {
    logic                                         ready;
    logic                                         valid;  // request is valid
  } handshake_t;
  

=======
>>>>>>> main
  typedef struct packed {
    logic valid;
    logic ready;
  } handshake_t;
endpackage : global_config_pkg
