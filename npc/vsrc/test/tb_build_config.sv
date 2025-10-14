import config_pkg::*;
import build_config_pkg::*;

module tb_build_config (
    // --- 输入端口  ---
    input int unsigned i_XLEN,
    input int unsigned i_VLEN,
    input int unsigned i_ICACHE_BYTE_SIZE,
    input int unsigned i_ICACHE_SET_ASSOC,
    input int unsigned i_ICACHE_LINE_WIDTH,

    // --- 输出端口  ---
    output int unsigned o_XLEN,
    output int unsigned o_VLEN,
    output int unsigned o_PLEN,
    output int unsigned o_GPLEN,
    output int unsigned o_FETCH_WIDTH,
    output int unsigned o_ICACHE_SET_ASSOC,
    output int unsigned o_ICACHE_SET_ASSOC_WIDTH,
    output int unsigned o_ICACHE_INDEX_WIDTH,
    output int unsigned o_ICACHE_TAG_WIDTH,
    output int unsigned o_ICACHE_LINE_WIDTH
);

  // 1. 在模块内部，将输入的扁平信号打包成 user_cfg_t 结构体
  user_cfg_t user_cfg_in;
  assign user_cfg_in.XLEN              = i_XLEN;
  assign user_cfg_in.VLEN              = i_VLEN;
  assign user_cfg_in.ICACHE_BYTE_SIZE  = i_ICACHE_BYTE_SIZE;
  assign user_cfg_in.ICACHE_SET_ASSOC  = i_ICACHE_SET_ASSOC;
  assign user_cfg_in.ICACHE_LINE_WIDTH = i_ICACHE_LINE_WIDTH;

  // 2. 调用函数
  cfg_t cfg_out = build_config(user_cfg_in);

  // 3. 将输出的 cfg_t 结构体解包到独立的输出端口
  assign o_XLEN                   = cfg_out.XLEN;
  assign o_VLEN                   = cfg_out.VLEN;
  assign o_PLEN                   = cfg_out.PLEN;
  assign o_GPLEN                  = cfg_out.GPLEN;
  assign o_FETCH_WIDTH            = cfg_out.FETCH_WIDTH;
  assign o_ICACHE_SET_ASSOC       = cfg_out.ICACHE_SET_ASSOC;
  assign o_ICACHE_SET_ASSOC_WIDTH = cfg_out.ICACHE_SET_ASSOC_WIDTH;
  assign o_ICACHE_INDEX_WIDTH     = cfg_out.ICACHE_INDEX_WIDTH;
  assign o_ICACHE_TAG_WIDTH       = cfg_out.ICACHE_TAG_WIDTH;
  assign o_ICACHE_LINE_WIDTH      = cfg_out.ICACHE_LINE_WIDTH;

endmodule
