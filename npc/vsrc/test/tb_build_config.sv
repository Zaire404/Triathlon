// vsrc/test/tb_build_config.sv
import config_pkg::*;
import build_config_pkg::*;
import decode_pkg::*;
import global_config_pkg::*;

module tb_build_config (
    // --- 输入端口  ---
    input int unsigned i_INSTR_PER_FETCH,
    input int unsigned i_XLEN,
    input int unsigned i_VLEN,
    input int unsigned i_ILEN,
    input int unsigned i_BPU_USE_GSHARE,
    input int unsigned i_BPU_USE_TOURNAMENT,
    input int unsigned i_BPU_BTB_HASH_ENABLE,
    input int unsigned i_BPU_BHT_HASH_ENABLE,
    input int unsigned i_ICACHE_HIT_PIPELINE_EN,
    input int unsigned i_IFU_FETCHQ_BYPASS_EN,
    input int unsigned i_IFU_REQ_DEPTH,
    input int unsigned i_IFU_INF_DEPTH,
    input int unsigned i_IFU_FQ_DEPTH,
    input int unsigned i_ENABLE_COMMIT_RAS_UPDATE,
    input int unsigned i_DCACHE_MSHR_SIZE,
    input int unsigned i_RENAME_PENDING_DEPTH,
    input int unsigned i_ICACHE_BYTE_SIZE,
    input int unsigned i_ICACHE_SET_ASSOC,
    input int unsigned i_ICACHE_LINE_WIDTH,

    // --- 输出端口  ---
    output int unsigned o_XLEN,
    output int unsigned o_VLEN,
    output int unsigned o_ILEN,
    output int unsigned o_PLEN,
    output int unsigned o_GPLEN,
    output int unsigned o_INSTR_PER_FETCH,
    output int unsigned o_BPU_USE_GSHARE,
    output int unsigned o_BPU_USE_TOURNAMENT,
    output int unsigned o_BPU_BTB_HASH_ENABLE,
    output int unsigned o_BPU_BHT_HASH_ENABLE,
    output int unsigned o_ICACHE_HIT_PIPELINE_EN,
    output int unsigned o_IFU_FETCHQ_BYPASS_EN,
    output int unsigned o_IFU_REQ_DEPTH,
    output int unsigned o_IFU_INF_DEPTH,
    output int unsigned o_IFU_FQ_DEPTH,
    output int unsigned o_ENABLE_COMMIT_RAS_UPDATE,
    output int unsigned o_DCACHE_MSHR_SIZE,
    output int unsigned o_RENAME_PENDING_DEPTH,
    output int unsigned o_ICACHE_BYTE_SIZE,
    output int unsigned o_ICACHE_SET_ASSOC,
    output int unsigned o_ICACHE_SET_ASSOC_WIDTH,
    output int unsigned o_ICACHE_INDEX_WIDTH,
    output int unsigned o_ICACHE_TAG_WIDTH,
    output int unsigned o_ICACHE_LINE_WIDTH,
    output int unsigned o_ICACHE_OFFSET_WIDTH,

    // Metadata field existence checks
    output logic [31:0] o_UOP_PRED_NPC,
    output logic        o_IBUF_SLOT_VALID,
    output logic [31:0] o_IBUF_PRED_NPC
);

  // 1. 在模块内部，将输入的扁平信号打包成 user_cfg_t 结构体
  user_cfg_t user_cfg_in;
  assign user_cfg_in.XLEN              = i_XLEN;
  assign user_cfg_in.VLEN              = i_VLEN;
  assign user_cfg_in.ILEN              = i_ILEN;
  assign user_cfg_in.BPU_USE_GSHARE    = i_BPU_USE_GSHARE;
  assign user_cfg_in.BPU_USE_TOURNAMENT = i_BPU_USE_TOURNAMENT;
  assign user_cfg_in.BPU_BTB_HASH_ENABLE = i_BPU_BTB_HASH_ENABLE;
  assign user_cfg_in.BPU_BHT_HASH_ENABLE = i_BPU_BHT_HASH_ENABLE;
  assign user_cfg_in.ICACHE_HIT_PIPELINE_EN = i_ICACHE_HIT_PIPELINE_EN;
  assign user_cfg_in.IFU_FETCHQ_BYPASS_EN = i_IFU_FETCHQ_BYPASS_EN;
  assign user_cfg_in.IFU_REQ_DEPTH = i_IFU_REQ_DEPTH;
  assign user_cfg_in.IFU_INF_DEPTH = i_IFU_INF_DEPTH;
  assign user_cfg_in.IFU_FQ_DEPTH = i_IFU_FQ_DEPTH;
  assign user_cfg_in.ENABLE_COMMIT_RAS_UPDATE = i_ENABLE_COMMIT_RAS_UPDATE;
  assign user_cfg_in.DCACHE_MSHR_SIZE = i_DCACHE_MSHR_SIZE;
  assign user_cfg_in.RENAME_PENDING_DEPTH = i_RENAME_PENDING_DEPTH;
  assign user_cfg_in.INSTR_PER_FETCH   = i_INSTR_PER_FETCH;
  assign user_cfg_in.ICACHE_BYTE_SIZE  = i_ICACHE_BYTE_SIZE;
  assign user_cfg_in.ICACHE_SET_ASSOC  = i_ICACHE_SET_ASSOC;
  assign user_cfg_in.ICACHE_LINE_WIDTH = i_ICACHE_LINE_WIDTH;

  // 2. 调用函数
  cfg_t cfg_out;
  assign cfg_out                  = build_config(user_cfg_in);

  // Compile-time field existence checks for new metadata plumbing.
  decode_pkg::uop_t uop_probe;
  global_config_pkg::ibuf_entry_t ibuf_probe;

  // 3. 将输出的 cfg_t 结构体解包到独立的输出端口
  assign o_XLEN                   = cfg_out.XLEN;
  assign o_VLEN                   = cfg_out.VLEN;
  assign o_ILEN                   = cfg_out.ILEN;
  assign o_PLEN                   = cfg_out.PLEN;
  assign o_GPLEN                  = cfg_out.GPLEN;
  assign o_INSTR_PER_FETCH        = cfg_out.INSTR_PER_FETCH;
  assign o_BPU_USE_GSHARE         = cfg_out.BPU_USE_GSHARE;
  assign o_BPU_USE_TOURNAMENT     = cfg_out.BPU_USE_TOURNAMENT;
  assign o_BPU_BTB_HASH_ENABLE    = cfg_out.BPU_BTB_HASH_ENABLE;
  assign o_BPU_BHT_HASH_ENABLE    = cfg_out.BPU_BHT_HASH_ENABLE;
  assign o_ICACHE_HIT_PIPELINE_EN = cfg_out.ICACHE_HIT_PIPELINE_EN;
  assign o_IFU_FETCHQ_BYPASS_EN   = cfg_out.IFU_FETCHQ_BYPASS_EN;
  assign o_IFU_REQ_DEPTH          = cfg_out.IFU_REQ_DEPTH;
  assign o_IFU_INF_DEPTH          = cfg_out.IFU_INF_DEPTH;
  assign o_IFU_FQ_DEPTH           = cfg_out.IFU_FQ_DEPTH;
  assign o_ENABLE_COMMIT_RAS_UPDATE = cfg_out.ENABLE_COMMIT_RAS_UPDATE;
  assign o_DCACHE_MSHR_SIZE         = cfg_out.DCACHE_MSHR_SIZE;
  assign o_RENAME_PENDING_DEPTH     = cfg_out.RENAME_PENDING_DEPTH;
  assign o_ICACHE_BYTE_SIZE       = cfg_out.ICACHE_BYTE_SIZE;
  assign o_ICACHE_SET_ASSOC       = cfg_out.ICACHE_SET_ASSOC;
  assign o_ICACHE_SET_ASSOC_WIDTH = cfg_out.ICACHE_SET_ASSOC_WIDTH;
  assign o_ICACHE_INDEX_WIDTH     = cfg_out.ICACHE_INDEX_WIDTH;
  assign o_ICACHE_TAG_WIDTH       = cfg_out.ICACHE_TAG_WIDTH;
  assign o_ICACHE_LINE_WIDTH      = cfg_out.ICACHE_LINE_WIDTH;
  assign o_ICACHE_OFFSET_WIDTH    = cfg_out.ICACHE_OFFSET_WIDTH;
  assign o_UOP_PRED_NPC           = uop_probe.pred_npc;
  assign o_IBUF_SLOT_VALID        = ibuf_probe.slot_valid;
  assign o_IBUF_PRED_NPC          = ibuf_probe.pred_npc;

endmodule
