package config_pkg;

  // ---------------
  // Global Config
  // ---------------
  // Instruction Length
  localparam int unsigned ILEN = 32;
  // Number of RETired instructions per cycle
  localparam int unsigned NRET = 4;


  typedef struct packed {
    // General Purpose Register Size (in bits)
    int unsigned XLEN;
    // Virtual address Size (in bits)
    int unsigned VLEN;
    // Instruction cache size (in bytes)
    int unsigned ICACHE_BYTE_SIZE;
    // Instruction cache associativity (number of ways)
    int unsigned ICACHE_SET_ASSOC;
    // Instruction cache line width
    int unsigned ICACHE_LINE_WIDTH;
  } user_cfg_t;

  typedef struct packed {
    // General Purpose Register Size (in bits)
    int unsigned XLEN;
    // Virtual address Size (in bits)
    int unsigned VLEN;
    // Physical address Size (in bits)
    int unsigned PLEN;
    // General Purpose Physical Register Size (in bits)
    int unsigned GPLEN;

    int unsigned FETCH_WIDTH;

    int unsigned ICACHE_BYTE_SIZE;
    int unsigned ICACHE_SET_ASSOC;
    int unsigned ICACHE_SET_ASSOC_WIDTH;
    int unsigned ICACHE_INDEX_WIDTH;
    int unsigned ICACHE_TAG_WIDTH;
    int unsigned ICACHE_LINE_WIDTH;
  } cfg_t;
  localparam cfg_t EmptyCfg = cfg_t'(0);
endpackage
