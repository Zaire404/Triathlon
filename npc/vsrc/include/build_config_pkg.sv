package build_config_pkg;

  function automatic config_pkg::cfg_t build_config(config_pkg::user_cfg_t user_cfg);
    // TODO
    config_pkg::cfg_t cfg;
    cfg.GPLEN = 32;
    cfg.FETCH_WIDTH = 128;
    cfg.frontedn_hash_LEN = user_cfg.frontedn_hash_LEN;
    cfg.frontend_predict_LEN = user_cfg.frontend_predict_LEN;
    cfg.XLEN = user_cfg.XLEN;
    cfg.VLEN = user_cfg.VLEN;
    cfg.PLEN = user_cfg.VLEN;  // 假设物理地址大小等于虚拟地址大小
    cfg.ICACHE_BYTE_SIZE = user_cfg.ICACHE_BYTE_SIZE;
    cfg.ICACHE_SET_ASSOC = user_cfg.ICACHE_SET_ASSOC;
    cfg.ICACHE_LINE_WIDTH = user_cfg.ICACHE_LINE_WIDTH;
    cfg.ICACHE_SET_ASSOC_WIDTH = user_cfg.ICACHE_SET_ASSOC > 1 ? $clog2(user_cfg.ICACHE_SET_ASSOC) :
        user_cfg.ICACHE_SET_ASSOC;
    cfg.ICACHE_INDEX_WIDTH = $clog2(user_cfg.ICACHE_BYTE_SIZE / user_cfg.ICACHE_SET_ASSOC);
    cfg.ICACHE_TAG_WIDTH = cfg.PLEN - cfg.ICACHE_INDEX_WIDTH;
    return cfg;
  endfunction
endpackage
