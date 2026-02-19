// vsrc/include/config_pkg.sv
package config_pkg;

  // ---------------
  // Global Config
  // ---------------
  // Instruction Length
  localparam int unsigned ILEN = 32;
  // Number of RETired instructions per cycle
  localparam int unsigned NRET = 4;


  typedef struct packed {
    // Number of instructions retired per cycle
    int unsigned NRET;
    // Number of instructions fetched per cycle
    int unsigned INSTR_PER_FETCH;
    // General Purpose Register Size (in bits)
    int unsigned XLEN;
    // Virtual address Size (in bits)
    int unsigned VLEN;
    // Instruction Length (in bits)
    int unsigned ILEN;
    // Branch predictor mode: 1 enables gshare, 0 uses PC-only index
    int unsigned BPU_USE_GSHARE;

    // ICache configuration
    // Instruction cache size (in bytes)
    int unsigned ICACHE_BYTE_SIZE;
    // Instruction cache associativity (number of ways)
    int unsigned ICACHE_SET_ASSOC;
    // Instruction cache line width
    int unsigned ICACHE_LINE_WIDTH;

    // DCache configuration
    // Data cache size (in bytes)
    int unsigned DCACHE_BYTE_SIZE;
    // Data cache associativity (number of ways)
    int unsigned DCACHE_SET_ASSOC;
    // Data cache line width (in bits)
    int unsigned DCACHE_LINE_WIDTH;

    int unsigned RS_DEPTH;

    int unsigned ALU_COUNT;

  } user_cfg_t;

  typedef struct packed {
    // Number of instructions retired per cycle
    int unsigned NRET;
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
    // Fetch width (in bits)
    int unsigned FETCH_WIDTH;
    // Branch predictor mode: 1 enables gshare, 0 uses PC-only index
    int unsigned BPU_USE_GSHARE;

    // ICache configuration
    int unsigned ICACHE_BYTE_SIZE;
    int unsigned ICACHE_SET_ASSOC;
    int unsigned ICACHE_SET_ASSOC_WIDTH;
    int unsigned ICACHE_INDEX_WIDTH;
    int unsigned ICACHE_TAG_WIDTH;
    int unsigned ICACHE_LINE_WIDTH;
    int unsigned ICACHE_OFFSET_WIDTH;
    int unsigned ICACHE_NUM_BANKS;
    int unsigned ICACHE_BANK_SEL_WIDTH;
    int unsigned ICACHE_NUM_SETS;

    // DCache configuration
    int unsigned DCACHE_BYTE_SIZE;
    int unsigned DCACHE_SET_ASSOC;
    int unsigned DCACHE_SET_ASSOC_WIDTH;
    int unsigned DCACHE_INDEX_WIDTH;
    int unsigned DCACHE_TAG_WIDTH;
    int unsigned DCACHE_LINE_WIDTH;
    int unsigned DCACHE_OFFSET_WIDTH;
    int unsigned DCACHE_NUM_BANKS;
    int unsigned DCACHE_BANK_SEL_WIDTH;
    int unsigned DCACHE_NUM_SETS;

    // Reservation Station configuration
    int unsigned RS_DEPTH;

    // Execute Station configuration
    int unsigned ALU_COUNT;
  } cfg_t;
  localparam cfg_t EmptyCfg = cfg_t'(0);
endpackage
