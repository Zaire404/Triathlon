// vsrc/test/tb_backend.sv
import config_pkg::*;
import decode_pkg::*;
import global_config_pkg::*;

module tb_backend (
    input logic clk_i,
    input logic rst_ni,
    input logic flush_from_backend,

    // Frontend -> backend
    input  logic                                         frontend_ibuf_valid,
    output logic                                         frontend_ibuf_ready,
    input  logic [Cfg.INSTR_PER_FETCH-1:0][Cfg.ILEN-1:0] frontend_ibuf_instrs,
    input  logic [           Cfg.PLEN-1:0]               frontend_ibuf_pc,
    input  logic [Cfg.INSTR_PER_FETCH-1:0]               frontend_ibuf_slot_valid,
    input  logic [Cfg.INSTR_PER_FETCH-1:0][Cfg.PLEN-1:0] frontend_ibuf_pred_npc,
    input  logic [Cfg.INSTR_PER_FETCH-1:0][((Cfg.IFU_INF_DEPTH >= 2) ? $clog2(Cfg.IFU_INF_DEPTH) : 1)-1:0] frontend_ibuf_ftq_id,
    input  logic [Cfg.INSTR_PER_FETCH-1:0][2:0] frontend_ibuf_fetch_epoch,

    // D-Cache miss/refill/writeback interface
    output logic                                  dcache_miss_req_valid_o,
    input  logic                                  dcache_miss_req_ready_i,
    output logic [                  Cfg.PLEN-1:0] dcache_miss_req_paddr_o,
    output logic [Cfg.DCACHE_SET_ASSOC_WIDTH-1:0] dcache_miss_req_victim_way_o,
    output logic [    Cfg.DCACHE_INDEX_WIDTH-1:0] dcache_miss_req_index_o,

    input  logic                                  dcache_refill_valid_i,
    output logic                                  dcache_refill_ready_o,
    input  logic [                  Cfg.PLEN-1:0] dcache_refill_paddr_i,
    input  logic [Cfg.DCACHE_SET_ASSOC_WIDTH-1:0] dcache_refill_way_i,
    input  logic [     Cfg.DCACHE_LINE_WIDTH-1:0] dcache_refill_data_i,

    output logic                             dcache_wb_req_valid_o,
    input  logic                             dcache_wb_req_ready_i,
    output logic [             Cfg.PLEN-1:0] dcache_wb_req_paddr_o,
    output logic [Cfg.DCACHE_LINE_WIDTH-1:0] dcache_wb_req_data_o,

    // Expose commit/flush for test
    output logic [Cfg.NRET-1:0]                commit_valid_o,
    output logic [Cfg.NRET-1:0]                commit_we_o,
    output logic [Cfg.NRET-1:0][4:0]           commit_areg_o,
    output logic [Cfg.NRET-1:0][Cfg.XLEN-1:0]  commit_wdata_o,
    output logic                               bpu_update_valid_o,
    output logic [Cfg.PLEN-1:0]                bpu_update_pc_o,
    output logic                               bpu_update_is_cond_o,
    output logic                               bpu_update_taken_o,
    output logic [Cfg.PLEN-1:0]                bpu_update_target_o,
    output logic                               bpu_update_is_call_o,
    output logic                               bpu_update_is_ret_o,
    output logic [Cfg.NRET-1:0]                bpu_ras_update_valid_o,
    output logic [Cfg.NRET-1:0]                bpu_ras_update_is_call_o,
    output logic [Cfg.NRET-1:0]                bpu_ras_update_is_ret_o,
    output logic [Cfg.NRET-1:0][Cfg.PLEN-1:0]  bpu_ras_update_pc_o,
    output logic                               rob_flush_o,
    output logic [Cfg.PLEN-1:0]                rob_flush_pc_o,
    output logic                               dbg_dec_ready_o,
    output logic                               dbg_dec_valid_o,
    output logic [((Cfg.IFU_INF_DEPTH >= 2) ? $clog2(Cfg.IFU_INF_DEPTH) : 1)-1:0] dbg_dec_uop0_ftq_id_o,
    output logic [2:0]                         dbg_dec_uop0_fetch_epoch_o,
    output logic [((Cfg.IFU_INF_DEPTH >= 2) ? $clog2(Cfg.IFU_INF_DEPTH) : 1)-1:0] dbg_bpu_update_ftq_id_o,
    output logic [2:0]                         dbg_bpu_update_fetch_epoch_o,
    output logic [7:0]                         dbg_cfg_ftq_id_bits_o,
    output logic [7:0]                         dbg_cfg_fetch_epoch_bits_o,
    output logic [((Cfg.NRET > 1) ? $clog2(Cfg.NRET) : 1)-1:0] dbg_bpu_update_sel_idx_o,
    output logic                               dbg_ren_src_from_pending_o,
    output logic [2:0]                         dbg_ren_src_count_o,
    output logic                               dbg_lsu_req_ready_o,
    output logic                               dbg_lsu_issue_fire_o,
    output logic [3:0]                         dbg_lsu_grp_lane_busy_o,
    output logic                               dbg_mem_dep_replay_o,
    output logic [7:0]                         dbg_completion_q_count_o
);

  logic backend_flush_unused;
  logic [Cfg.PLEN-1:0] backend_redirect_pc_unused;
  backend #(
      .Cfg(global_config_pkg::Cfg)
  ) dut (
      .clk_i,
      .rst_ni,
      .flush_from_backend,
      .frontend_ibuf_valid,
      .frontend_ibuf_ready,
      .frontend_ibuf_instrs,
      .frontend_ibuf_pc,
      .frontend_ibuf_slot_valid,
      .frontend_ibuf_pred_npc,
      .frontend_ibuf_ftq_id(frontend_ibuf_ftq_id),
      .frontend_ibuf_fetch_epoch(frontend_ibuf_fetch_epoch),
      .backend_flush_o(backend_flush_unused),
      .backend_redirect_pc_o(backend_redirect_pc_unused),
      .bpu_update_valid_o(bpu_update_valid_o),
      .bpu_update_pc_o(bpu_update_pc_o),
      .bpu_update_is_cond_o(bpu_update_is_cond_o),
      .bpu_update_taken_o(bpu_update_taken_o),
      .bpu_update_target_o(bpu_update_target_o),
      .bpu_update_is_call_o(bpu_update_is_call_o),
      .bpu_update_is_ret_o(bpu_update_is_ret_o),
      .bpu_ras_update_valid_o(bpu_ras_update_valid_o),
      .bpu_ras_update_is_call_o(bpu_ras_update_is_call_o),
      .bpu_ras_update_is_ret_o(bpu_ras_update_is_ret_o),
      .bpu_ras_update_pc_o(bpu_ras_update_pc_o),

      .dcache_miss_req_valid_o,
      .dcache_miss_req_ready_i,
      .dcache_miss_req_paddr_o,
      .dcache_miss_req_victim_way_o,
      .dcache_miss_req_index_o,

      .dcache_refill_valid_i,
      .dcache_refill_ready_o,
      .dcache_refill_paddr_i,
      .dcache_refill_way_i,
      .dcache_refill_data_i,

      .dcache_wb_req_valid_o,
      .dcache_wb_req_ready_i,
      .dcache_wb_req_paddr_o,
      .dcache_wb_req_data_o
  );

  // Expose internal signals
  assign commit_valid_o = dut.commit_valid;
  assign commit_we_o    = dut.commit_we;
  assign commit_areg_o  = dut.commit_areg;
  assign commit_wdata_o = dut.commit_wdata;
  assign rob_flush_o    = dut.rob_flush;
  assign rob_flush_pc_o = dut.rob_flush_pc;
  assign dbg_dec_ready_o = dut.decode_backend_ready;
  assign dbg_dec_valid_o = dut.dec_valid;
  assign dbg_dec_uop0_ftq_id_o = dut.dec_uops[0].ftq_id;
  assign dbg_dec_uop0_fetch_epoch_o = dut.dec_uops[0].fetch_epoch;
  assign dbg_bpu_update_ftq_id_o = dut.bpu_update_ftq_id_dbg;
  assign dbg_bpu_update_fetch_epoch_o = dut.bpu_update_fetch_epoch_dbg;
  assign dbg_cfg_ftq_id_bits_o = 8'(((Cfg.IFU_INF_DEPTH >= 2) ? $clog2(Cfg.IFU_INF_DEPTH) : 1));
  assign dbg_cfg_fetch_epoch_bits_o = 8'(3);
  assign dbg_bpu_update_sel_idx_o = dut.bpu_update_sel_idx_dbg;
  assign dbg_ren_src_from_pending_o = dut.rename_src_from_pending;
  always_comb begin
    dbg_ren_src_count_o = '0;
    for (int i = 0; i < Cfg.INSTR_PER_FETCH; i++) begin
      if (dut.rename_src_valid[i]) begin
        dbg_ren_src_count_o++;
      end
    end
  end
  assign dbg_lsu_req_ready_o = dut.lsu_req_ready;
  assign dbg_lsu_issue_fire_o = dut.lsu_en & dut.lsu_req_ready;
  assign dbg_lsu_grp_lane_busy_o = {2'b0, dut.u_lsu_group.dbg_lane_busy};
  assign dbg_mem_dep_replay_o = dut.mem_dep_replay_valid;
  assign dbg_completion_q_count_o = dut.completion_q_count;

endmodule
