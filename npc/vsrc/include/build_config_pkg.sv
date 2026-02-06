// vsrc/include/build_config_pkg.sv
package build_config_pkg;

  import config_pkg::*;

  function automatic config_pkg::cfg_t build_config(config_pkg::user_cfg_t user_cfg);
    // TODO
    config_pkg::cfg_t cfg;
    // Global
    cfg.NRET = user_cfg.NRET;
    cfg.INSTR_PER_FETCH = user_cfg.INSTR_PER_FETCH;
    cfg.XLEN = user_cfg.XLEN;
    cfg.VLEN = user_cfg.VLEN;
    cfg.PLEN = user_cfg.VLEN;  // 假设物理地址大小等于虚拟地址大小
    cfg.ILEN = user_cfg.ILEN;
    cfg.FETCH_WIDTH = user_cfg.INSTR_PER_FETCH * user_cfg.ILEN / 8;

    // ICache 配置
    cfg.ICACHE_BYTE_SIZE = user_cfg.ICACHE_BYTE_SIZE;
    cfg.ICACHE_SET_ASSOC = user_cfg.ICACHE_SET_ASSOC;
    cfg.ICACHE_LINE_WIDTH = user_cfg.ICACHE_LINE_WIDTH;
    cfg.ICACHE_SET_ASSOC_WIDTH = user_cfg.ICACHE_SET_ASSOC > 1 ? $clog2(user_cfg.ICACHE_SET_ASSOC) :
        user_cfg.ICACHE_SET_ASSOC;
    cfg.ICACHE_INDEX_WIDTH = $clog2(
        user_cfg.ICACHE_BYTE_SIZE * 8 / user_cfg.ICACHE_SET_ASSOC / user_cfg.ICACHE_LINE_WIDTH);
    cfg.ICACHE_OFFSET_WIDTH = $clog2(user_cfg.ICACHE_LINE_WIDTH / 8);
    cfg.ICACHE_TAG_WIDTH = cfg.PLEN - cfg.ICACHE_INDEX_WIDTH - cfg.ICACHE_OFFSET_WIDTH;
    cfg.ICACHE_NUM_BANKS = 4;  // 固定为4个Bank
    cfg.ICACHE_BANK_SEL_WIDTH = $clog2(cfg.ICACHE_NUM_BANKS);
    cfg.ICACHE_NUM_SETS = (user_cfg.ICACHE_BYTE_SIZE * 8) / user_cfg.ICACHE_SET_ASSOC / user_cfg.ICACHE_LINE_WIDTH;

    // DCache 配置
    cfg.DCACHE_BYTE_SIZE = user_cfg.DCACHE_BYTE_SIZE;
    cfg.DCACHE_SET_ASSOC = user_cfg.DCACHE_SET_ASSOC;
    cfg.DCACHE_LINE_WIDTH = user_cfg.DCACHE_LINE_WIDTH;
    cfg.DCACHE_SET_ASSOC_WIDTH = user_cfg.DCACHE_SET_ASSOC > 1 ? $clog2(user_cfg.DCACHE_SET_ASSOC) :
        user_cfg.DCACHE_SET_ASSOC;
    cfg.DCACHE_INDEX_WIDTH = $clog2(
        user_cfg.DCACHE_BYTE_SIZE * 8 / user_cfg.DCACHE_SET_ASSOC / user_cfg.DCACHE_LINE_WIDTH);
    cfg.DCACHE_OFFSET_WIDTH = $clog2(user_cfg.DCACHE_LINE_WIDTH / 8);
    cfg.DCACHE_TAG_WIDTH = cfg.PLEN - cfg.DCACHE_INDEX_WIDTH - cfg.DCACHE_OFFSET_WIDTH;
    cfg.DCACHE_NUM_BANKS = 4;  // 固定为4个Bank（后续可参数化）
    cfg.DCACHE_BANK_SEL_WIDTH = $clog2(cfg.DCACHE_NUM_BANKS);
    cfg.DCACHE_NUM_SETS = (user_cfg.DCACHE_BYTE_SIZE * 8) / user_cfg.DCACHE_SET_ASSOC / user_cfg.DCACHE_LINE_WIDTH;

    // RS 配置
    cfg.RS_DEPTH = user_cfg.RS_DEPTH;

    // ALU 配置
    cfg.ALU_COUNT = user_cfg.ALU_COUNT;

    // FTQ 配置
    cfg.FTQ_DEPTH = user_cfg.FTQ_DEPTH;
    return cfg;
  endfunction
endpackage
