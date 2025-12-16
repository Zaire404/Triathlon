// vsrc/include/test_config_pkg.sv
package test_config_pkg;

  import config_pkg::*;

  localparam config_pkg::user_cfg_t TestCfg = '{
      INSTR_PER_FETCH : unsigned'(4),
      XLEN          : unsigned'(32),
      VLEN          : unsigned'(32),
      ILEN          : unsigned'(32),
      RS_DEPTH     : unsigned'(16),
      ALU_COUNT    : unsigned'(2),
      ICACHE_BYTE_SIZE : unsigned'(4096),
      ICACHE_SET_ASSOC : unsigned'(4),
      ICACHE_LINE_WIDTH : unsigned'(256)
  };

endpackage : test_config_pkg
