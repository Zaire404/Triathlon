// vsrc/test/tb_frontend.sv
import config_pkg::*;
import global_config_pkg::*;

module tb_frontend (
    input logic clk_i,
    input logic rst_ni,

    // ============================================
    // 1. 后端/IBuffer 接口 (To Backend)
    // ============================================
    output logic                                    ibuffer_valid_o,
    input  logic                                    ibuffer_ready_i,
    // 将 packed array 展平以便 C++ 访问 (4 * 32 = 128 bit)
    output logic [Cfg.INSTR_PER_FETCH*Cfg.ILEN-1:0] ibuffer_data_o,
    output logic [                    Cfg.PLEN-1:0] ibuffer_pc_o,
    output logic [Cfg.INSTR_PER_FETCH-1:0]          ibuffer_slot_valid_o,
    output logic [Cfg.INSTR_PER_FETCH*Cfg.PLEN-1:0] ibuffer_pred_npc_o,

    input logic                flush_i,
    input logic [Cfg.PLEN-1:0] redirect_pc_i,
    input logic                bpu_update_valid_i,
    input logic [Cfg.PLEN-1:0] bpu_update_pc_i,
    input logic                bpu_update_is_cond_i,
    input logic                bpu_update_taken_i,
    input logic [Cfg.PLEN-1:0] bpu_update_target_i,

    // ============================================
    // 2. 存储器系统接口 (To Memory/L2/Bus)
    // ============================================
    output logic                                  miss_req_valid_o,
    input  logic                                  miss_req_ready_i,
    output logic [                  Cfg.PLEN-1:0] miss_req_paddr_o,
    output logic [Cfg.ICACHE_SET_ASSOC_WIDTH-1:0] miss_req_victim_way_o,
    output logic [    Cfg.ICACHE_INDEX_WIDTH-1:0] miss_req_index_o,

    input  logic                                  refill_valid_i,
    output logic                                  refill_ready_o,
    input  logic [                  Cfg.PLEN-1:0] refill_paddr_i,
    input  logic [Cfg.ICACHE_SET_ASSOC_WIDTH-1:0] refill_way_i,
    input  logic [     Cfg.ICACHE_LINE_WIDTH-1:0] refill_data_i
);

  // 内部信号转换：将展平的 ibuffer_data_o 转回 frontend 需要的 packed 格式 (如果需要的话，或者直接连接)
  // frontend 的输出是 logic [Cfg.INSTR_PER_FETCH-1:0][Cfg.ILEN-1:0]
  // SystemVerilog 的 packed array 和展平的 vector 在 bit 布局上通常是兼容的，可以直接 assign

  frontend #(
      .Cfg(Cfg)
  ) DUT (
      .clk_i (clk_i),
      .rst_ni(rst_ni),

      .ibuffer_valid_o(ibuffer_valid_o),
      .ibuffer_ready_i(ibuffer_ready_i),
      .ibuffer_data_o (ibuffer_data_o),
      .ibuffer_pc_o   (ibuffer_pc_o),
      .ibuffer_slot_valid_o(ibuffer_slot_valid_o),
      .ibuffer_pred_npc_o(ibuffer_pred_npc_o),

      .flush_i      (flush_i),
      .redirect_pc_i(redirect_pc_i),
      .bpu_update_valid_i(bpu_update_valid_i),
      .bpu_update_pc_i(bpu_update_pc_i),
      .bpu_update_is_cond_i(bpu_update_is_cond_i),
      .bpu_update_taken_i(bpu_update_taken_i),
      .bpu_update_target_i(bpu_update_target_i),

      .miss_req_valid_o     (miss_req_valid_o),
      .miss_req_ready_i     (miss_req_ready_i),
      .miss_req_paddr_o     (miss_req_paddr_o),
      .miss_req_victim_way_o(miss_req_victim_way_o),
      .miss_req_index_o     (miss_req_index_o),

      .refill_valid_i(refill_valid_i),
      .refill_ready_o(refill_ready_o),
      .refill_paddr_i(refill_paddr_i),
      .refill_way_i  (refill_way_i),
      .refill_data_i (refill_data_i)
  );

endmodule
