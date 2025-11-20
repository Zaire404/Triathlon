import config_pkg::*;

package test_config_pkg;

  localparam config_pkg::user_cfg_t TestCfg = '{
      XLEN          : unsigned'(32),
      VLEN          : unsigned'(64),
      ICACHE_BYTE_SIZE : unsigned'(4096),
      ICACHE_SET_ASSOC : unsigned'(4),
      ICACHE_LINE_WIDTH : unsigned'(32), 
      frontedn_hash_LEN : unsigned'(5),
      frontend_predict_LEN : unsigned'(10)
      // frontedn_predict 必须是frontedn_hash的倍数
  };

endpackage : test_config_pkg
