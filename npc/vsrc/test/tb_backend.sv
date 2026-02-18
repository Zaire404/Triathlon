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
    output logic                               dbg_lsu_req_ready_o,
    output logic                               dbg_lsu_issue_fire_o,
    output logic [3:0]                         dbg_lsu_grp_lane_busy_o
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
  assign dbg_lsu_req_ready_o = dut.lsu_req_ready;
  assign dbg_lsu_issue_fire_o = dut.lsu_en & dut.lsu_req_ready;
  assign dbg_lsu_grp_lane_busy_o = {2'b0, dut.u_lsu_group.dbg_lane_busy};

endmodule
