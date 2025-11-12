package config_pkg;

  // ---------------
  // Global Config
  // ---------------
  // Instruction Length
  localparam int unsigned ILEN = 32;
  // Number of RETired instructions per cycle
  localparam int unsigned NRET = 4;


  typedef struct packed {
    // Number of instructions fetched per cycle
    int unsigned INSTR_PER_FETCH;
    // General Purpose Register Size (in bits)
    int unsigned XLEN;
    // Virtual address Size (in bits)
    int unsigned VLEN;
    // Instruction Length (in bits)
    int unsigned ILEN;
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
    // Instruction Length (in bits)
    int unsigned ILEN;
    // Physical address Size (in bits)
    int unsigned PLEN;
    // General Purpose Physical Register Size (in bits)
    int unsigned GPLEN;
    // Number of instructions fetched per cycle
    int unsigned INSTR_PER_FETCH;

    int unsigned ICACHE_BYTE_SIZE;
    int unsigned ICACHE_SET_ASSOC;
    int unsigned ICACHE_SET_ASSOC_WIDTH;
    int unsigned ICACHE_INDEX_WIDTH;
    int unsigned ICACHE_TAG_WIDTH;
    int unsigned ICACHE_LINE_WIDTH;
    int unsigned ICACHE_OFFSET_WIDTH;
    int unsigned ICACHE_NUM_BANKS;
    int unsigned ICACHE_NUM_SETS;
  } cfg_t;
  localparam cfg_t EmptyCfg = cfg_t'(0);
endpackage
