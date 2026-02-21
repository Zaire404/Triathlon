// vsrc/frontend/frontend.sv
import global_config_pkg::*;

module frontend #(
    parameter config_pkg::cfg_t Cfg = config_pkg::EmptyCfg
) (
    input logic clk_i,
    input logic rst_ni,

    // ============================================
    // 1. 后端/IBuffer 接口 (To Backend)
    // ============================================
    // IBuffer 握手与数据 (Output to IBuffer)
    output logic                                         ibuffer_valid_o,
    input  logic                                         ibuffer_ready_i,
    output logic [Cfg.INSTR_PER_FETCH-1:0][Cfg.ILEN-1:0] ibuffer_data_o,
    output logic [           Cfg.PLEN-1:0]               ibuffer_pc_o,     // Fetch Group 的 PC
    output logic [Cfg.INSTR_PER_FETCH-1:0]               ibuffer_slot_valid_o,
    output logic [Cfg.INSTR_PER_FETCH-1:0][Cfg.PLEN-1:0] ibuffer_pred_npc_o,
    output logic [Cfg.INSTR_PER_FETCH-1:0][((Cfg.IFU_INF_DEPTH >= 2) ? $clog2(Cfg.IFU_INF_DEPTH) : 1)-1:0] ibuffer_ftq_id_o,
    output logic [Cfg.INSTR_PER_FETCH-1:0][2:0] ibuffer_fetch_epoch_o,

    // 冲刷与重定向 (Input from Backend)
    input logic                flush_i,
    input logic [Cfg.PLEN-1:0] redirect_pc_i,
    input logic                bpu_update_valid_i,
    input logic [Cfg.PLEN-1:0] bpu_update_pc_i,
    input logic                bpu_update_is_cond_i,
    input logic                bpu_update_taken_i,
    input logic [Cfg.PLEN-1:0] bpu_update_target_i,
    input logic                bpu_update_is_call_i,
    input logic                bpu_update_is_ret_i,
    input logic [Cfg.NRET-1:0] bpu_ras_update_valid_i,
    input logic [Cfg.NRET-1:0] bpu_ras_update_is_call_i,
    input logic [Cfg.NRET-1:0] bpu_ras_update_is_ret_i,
    input logic [Cfg.NRET-1:0][Cfg.PLEN-1:0] bpu_ras_update_pc_i,

    // ============================================
    // 2. 存储器系统接口 (To Memory/L2/Bus)
    // ============================================
    // Miss Request (Output)
    output logic                                  miss_req_valid_o,
    input  logic                                  miss_req_ready_i,
    output logic [                  Cfg.PLEN-1:0] miss_req_paddr_o,
    output logic [Cfg.ICACHE_SET_ASSOC_WIDTH-1:0] miss_req_victim_way_o,
    output logic [    Cfg.ICACHE_INDEX_WIDTH-1:0] miss_req_index_o,

    // Refill (Input)
    input  logic                                  refill_valid_i,
    output logic                                  refill_ready_o,
    input  logic [                  Cfg.PLEN-1:0] refill_paddr_i,
    input  logic [Cfg.ICACHE_SET_ASSOC_WIDTH-1:0] refill_way_i,
    input  logic [     Cfg.ICACHE_LINE_WIDTH-1:0] refill_data_i
);

  // =================================================================
  // 内部信号定义
  // =================================================================

  // --- IFU <-> BPU 互联信号 ---
  handshake_t ifu2bpu_handshake;
  handshake_t bpu2ifu_handshake;
  logic [Cfg.PLEN-1:0] ifu2bpu_pc;
  logic [Cfg.PLEN-1:0] bpu2ifu_predicted_pc;
  logic bpu2ifu_pred_slot_valid;
  logic [$clog2(Cfg.INSTR_PER_FETCH)-1:0] bpu2ifu_pred_slot_idx;
  logic [Cfg.PLEN-1:0] bpu2ifu_pred_target;

  // BPU 接口结构体 (用于适配 BPU 端口定义)
  ifu_to_bpu_t ifu_to_bpu_struct;
  bpu_to_ifu_t bpu_to_ifu_struct;

  // --- IFU <-> ICache 互联信号 ---
  handshake_t ifu2icache_req_handshake;
  handshake_t icache2ifu_rsp_handshake;
  logic [Cfg.VLEN-1:0] ifu2icache_req_addr;
  logic [Cfg.INSTR_PER_FETCH-1:0][Cfg.ILEN-1:0] icache2ifu_rsp_data;
  logic flush_icache;

  // =================================================================
  // 逻辑连接与适配
  // =================================================================

  // 1. BPU 结构体适配
  // IFU 输出的扁平 PC -> 打包进 BPU 输入结构体
  assign ifu_to_bpu_struct.pc = ifu2bpu_pc;
  // BPU 输出的结构体 -> 解包给 IFU 的扁平 Predicted PC
  assign bpu2ifu_predicted_pc = bpu_to_ifu_struct.npc;
  assign bpu2ifu_pred_slot_valid = bpu_to_ifu_struct.pred_slot_valid;
  assign bpu2ifu_pred_slot_idx = bpu_to_ifu_struct.pred_slot_idx;
  assign bpu2ifu_pred_target = bpu_to_ifu_struct.pred_slot_target;

  // =================================================================
  // 模块实例化
  // =================================================================

  // -------------------
  // 1. Instruction Fetch Unit (IFU)
  // -------------------
  ifu #(
      .Cfg(Cfg)
  ) i_ifu (
      .clk(clk_i),
      .rst(~rst_ni), // IFU 使用高电平复位 (rst)，需取反

      // --- BPU Handshake ---
      .ifu2bpu_handshake_o   (ifu2bpu_handshake),
      .bpu2ifu_handshake_i   (bpu2ifu_handshake),
      .ifu2bpu_pc_o          (ifu2bpu_pc),
      .bpu2ifu_predicted_pc_i(bpu2ifu_predicted_pc),
      .bpu2ifu_pred_slot_valid_i(bpu2ifu_pred_slot_valid),
      .bpu2ifu_pred_slot_idx_i(bpu2ifu_pred_slot_idx),
      .bpu2ifu_pred_target_i(bpu2ifu_pred_target),

      // --- ICache Request Interface ---
      .ifu2icache_req_handshake_o(ifu2icache_req_handshake),
      .icache2ifu_rsp_handshake_i(icache2ifu_rsp_handshake),
      .ifu2icache_req_addr_o     (ifu2icache_req_addr),
      .icache2ifu_rsp_data_i     (icache2ifu_rsp_data),
      .flush_icache_o            (flush_icache),

      // --- IBuffer Response Interface (To Backend) ---
      .ifu_ibuffer_rsp_valid_o(ibuffer_valid_o),
      .ifu_ibuffer_rsp_pc_o   (ibuffer_pc_o),
      .ibuffer_ifu_rsp_ready_i(ibuffer_ready_i),
      .ifu_ibuffer_rsp_data_o (ibuffer_data_o),
      .ifu_ibuffer_rsp_slot_valid_o(ibuffer_slot_valid_o),
      .ifu_ibuffer_rsp_pred_npc_o(ibuffer_pred_npc_o),
      .ifu_ibuffer_rsp_ftq_id_o(ibuffer_ftq_id_o),
      .ifu_ibuffer_rsp_fetch_epoch_o(ibuffer_fetch_epoch_o),

      // --- Backend Control ---
      .flush_i      (flush_i),
      .redirect_pc_i(redirect_pc_i)
  );

  // -------------------
  // 2. Branch Prediction Unit (BPU)
  // -------------------
  bpu #(
      .Cfg(Cfg),
      .BTB_ENTRIES(Cfg.BPU_BTB_ENTRIES),
      .BHT_ENTRIES(Cfg.BPU_BHT_ENTRIES),
      .RAS_DEPTH(Cfg.BPU_RAS_DEPTH),
      .USE_GSHARE(Cfg.BPU_USE_GSHARE != 0),
      .USE_TAGE(Cfg.BPU_USE_TAGE != 0),
      .USE_SC_L(Cfg.BPU_USE_SC_L != 0),
      .USE_TOURNAMENT(Cfg.BPU_USE_TOURNAMENT != 0),
      .BTB_HASH_ENABLE(Cfg.BPU_BTB_HASH_ENABLE != 0),
      .BHT_HASH_ENABLE(Cfg.BPU_BHT_HASH_ENABLE != 0),
      .GHR_BITS(Cfg.BPU_GHR_BITS),
      .SC_L_ENTRIES(Cfg.BPU_SC_L_ENTRIES),
      .SC_L_CONF_THRESH(Cfg.BPU_SC_L_CONF_THRESH),
      .SC_L_REQUIRE_DISAGREE(Cfg.BPU_SC_L_REQUIRE_DISAGREE != 0),
      .SC_L_REQUIRE_BOTH_WEAK(Cfg.BPU_SC_L_REQUIRE_BOTH_WEAK != 0),
      .SC_L_BLOCK_ON_TAGE_HIT(Cfg.BPU_SC_L_BLOCK_ON_TAGE_HIT != 0),
      .USE_LOOP(Cfg.BPU_USE_LOOP != 0),
      .LOOP_ENTRIES(Cfg.BPU_LOOP_ENTRIES),
      .LOOP_TAG_BITS(Cfg.BPU_LOOP_TAG_BITS),
      .LOOP_CONF_THRESH(Cfg.BPU_LOOP_CONF_THRESH),
      .USE_ITTAGE(Cfg.BPU_USE_ITTAGE != 0),
      .ITTAGE_ENTRIES(Cfg.BPU_ITTAGE_ENTRIES),
      .ITTAGE_TAG_BITS(Cfg.BPU_ITTAGE_TAG_BITS),
      .TAGE_OVERRIDE_MIN_PROVIDER(Cfg.BPU_TAGE_OVERRIDE_MIN_PROVIDER),
      .TAGE_OVERRIDE_REQUIRE_LEGACY_WEAK(Cfg.BPU_TAGE_OVERRIDE_REQUIRE_LEGACY_WEAK != 0)
  ) i_bpu (
      .clk_i(clk_i),
      .rst_i(~rst_ni), // 高电平复位

      .ifu_to_bpu_i          (ifu_to_bpu_struct),
      .ifu_to_bpu_handshake_i(ifu2bpu_handshake),
      .update_valid_i        (bpu_update_valid_i),
      .update_pc_i           (bpu_update_pc_i),
      .update_is_cond_i      (bpu_update_is_cond_i),
      .update_taken_i        (bpu_update_taken_i),
      .update_target_i       (bpu_update_target_i),
      .update_is_call_i      (bpu_update_is_call_i),
      .update_is_ret_i       (bpu_update_is_ret_i),
      .ras_update_valid_i    (bpu_ras_update_valid_i),
      .ras_update_is_call_i  (bpu_ras_update_is_call_i),
      .ras_update_is_ret_i   (bpu_ras_update_is_ret_i),
      .ras_update_pc_i       (bpu_ras_update_pc_i),
      .flush_i               (flush_i),
      .bpu_to_ifu_handshake_o(bpu2ifu_handshake),
      .bpu_to_ifu_o          (bpu_to_ifu_struct)
  );

  // -------------------
  // 3. Instruction Cache (ICache)
  // -------------------
  icache #(
      .Cfg(Cfg),
      .HIT_PIPELINE_EN(Cfg.ICACHE_HIT_PIPELINE_EN != 0)
  ) i_icache (
      .clk_i (clk_i),
      .rst_ni(rst_ni), // 低电平复位

      // --- IFU Interface ---
      .ifu_req_handshake_i(ifu2icache_req_handshake),
      .ifu_rsp_handshake_o(icache2ifu_rsp_handshake),
      .ifu_req_pc_i       (ifu2icache_req_addr),
      .ifu_rsp_instrs_o   (icache2ifu_rsp_data),
      .ifu_req_flush_i    (flush_icache),

      // --- Miss / Refill Interface (To Memory) ---
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

endmodule : frontend
