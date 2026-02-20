// vsrc/include/test_config_pkg.sv
package test_config_pkg;

  import config_pkg::*;

  localparam config_pkg::user_cfg_t TestCfg = '{
      NRET          : unsigned'(4),
      INSTR_PER_FETCH : unsigned'(4),
      XLEN          : unsigned'(32),
      VLEN          : unsigned'(32),
      ILEN          : unsigned'(32),
      BPU_USE_GSHARE : unsigned'(1),
      BPU_USE_TOURNAMENT : unsigned'(1),
      BPU_BTB_HASH_ENABLE : unsigned'(1),
      BPU_BHT_HASH_ENABLE : unsigned'(1),
      ICACHE_HIT_PIPELINE_EN : unsigned'(1),
      IFU_FETCHQ_BYPASS_EN : unsigned'(1),
      IFU_REQ_DEPTH : unsigned'(8),
      IFU_INF_DEPTH : unsigned'(8),
      IFU_FQ_DEPTH : unsigned'(8),
      ENABLE_COMMIT_RAS_UPDATE : unsigned'(1),
      DCACHE_MSHR_SIZE : unsigned'(4),
      RENAME_PENDING_DEPTH : unsigned'(16),
      RS_DEPTH     : unsigned'(16),
      ALU_COUNT    : unsigned'(2),
      ICACHE_BYTE_SIZE : unsigned'(4096),
      ICACHE_SET_ASSOC : unsigned'(4),
      ICACHE_LINE_WIDTH : unsigned'(256),

      // DCache (默认与 ICache 同行宽，方便复用 AXI beat 聚合)
      DCACHE_BYTE_SIZE : unsigned'(4096),
      DCACHE_SET_ASSOC : unsigned'(4),
      DCACHE_LINE_WIDTH : unsigned'(256)
  };

endpackage : test_config_pkg
