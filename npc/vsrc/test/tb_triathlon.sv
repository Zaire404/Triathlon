// vsrc/test/tb_triathlon.sv
import config_pkg::*;
import decode_pkg::*;
import global_config_pkg::*;

module tb_triathlon #(
    parameter int unsigned ROB_DEPTH = 64,
    parameter int unsigned ROB_IDX_W = $clog2(ROB_DEPTH),
    parameter int unsigned SB_DEPTH  = 16,
    parameter int unsigned SB_IDX_W  = $clog2(SB_DEPTH)
) (
    input logic clk_i,
    input logic rst_ni,

    // I-Cache miss/refill interface
    output logic                                  icache_miss_req_valid_o,
    input  logic                                  icache_miss_req_ready_i,
    output logic [                  Cfg.PLEN-1:0] icache_miss_req_paddr_o,
    output logic [Cfg.ICACHE_SET_ASSOC_WIDTH-1:0] icache_miss_req_victim_way_o,
    output logic [    Cfg.ICACHE_INDEX_WIDTH-1:0] icache_miss_req_index_o,

    input  logic                                  icache_refill_valid_i,
    output logic                                  icache_refill_ready_o,
    input  logic [                  Cfg.PLEN-1:0] icache_refill_paddr_i,
    input  logic [Cfg.ICACHE_SET_ASSOC_WIDTH-1:0] icache_refill_way_i,
    input  logic [     Cfg.ICACHE_LINE_WIDTH-1:0] icache_refill_data_i,

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

    // Expose commit signals for test
    output logic [Cfg.NRET-1:0]                commit_valid_o,
    output logic [Cfg.NRET-1:0]                commit_we_o,
    output logic [Cfg.NRET-1:0][4:0]           commit_areg_o,
    output logic [Cfg.NRET-1:0][Cfg.XLEN-1:0]  commit_wdata_o,
    output logic [Cfg.NRET-1:0][Cfg.PLEN-1:0]  commit_pc_o,
    output logic [Cfg.XLEN-1:0]                dbg_csr_mtvec_o,
    output logic [Cfg.XLEN-1:0]                dbg_csr_mepc_o,
    output logic [Cfg.XLEN-1:0]                dbg_csr_mstatus_o,
    output logic [Cfg.XLEN-1:0]                dbg_csr_mcause_o,
    output logic                               backend_flush_o,
    output logic [Cfg.PLEN-1:0]                backend_redirect_pc_o,
    output logic                               dbg_rob_flush_o,
    output logic [4:0]                         dbg_rob_flush_cause_o,
    output logic                               dbg_rob_flush_is_mispred_o,
    output logic                               dbg_rob_flush_is_exception_o,
    output logic                               dbg_rob_flush_is_branch_o,
    output logic                               dbg_rob_flush_is_jump_o,
    output logic [Cfg.PLEN-1:0]                dbg_rob_flush_src_pc_o,

    // Debug (frontend/backend handshakes)
    output logic                               dbg_fe_valid_o,
    output logic                               dbg_fe_ready_o,
    output logic [Cfg.PLEN-1:0]                dbg_fe_pc_o,
    output logic [Cfg.INSTR_PER_FETCH-1:0][Cfg.ILEN-1:0] dbg_fe_instrs_o,
    output logic [Cfg.INSTR_PER_FETCH-1:0]     dbg_fe_slot_valid_o,
    output logic [Cfg.INSTR_PER_FETCH-1:0][Cfg.PLEN-1:0] dbg_fe_pred_npc_o,
    output logic                               dbg_ifu_req_valid_o,
    output logic                               dbg_ifu_req_ready_o,
    output logic                               dbg_ifu_req_fire_o,
    output logic                               dbg_ifu_req_inflight_o,
    output logic                               dbg_ifu_rsp_valid_o,
    output logic                               dbg_ifu_rsp_capture_o,
    output logic [2:0]                         dbg_icache_state_o,
    output logic [3:0]                         dbg_ifu_fq_count_o,
    output logic                               dbg_ifu_fq_full_o,
    output logic                               dbg_ifu_fq_empty_o,
    output logic                               dbg_ifu_ibuf_pop_o,
    output logic                               dbg_dec_valid_o,
    output logic                               dbg_dec_ready_o,
    output logic                               dbg_rob_ready_o,
    output logic                               dbg_ren_src_from_pending_o,
    output logic [$clog2(Cfg.INSTR_PER_FETCH+1)-1:0] dbg_ren_src_count_o,
    output logic [$clog2(Cfg.INSTR_PER_FETCH+1)-1:0] dbg_ren_sel_count_o,
    output logic                               dbg_ren_fire_o,
    output logic                               dbg_ren_ready_o,
    // Debug (dispatch gate/capacity)
    output logic                               dbg_gate_alu_o,
    output logic                               dbg_gate_bru_o,
    output logic                               dbg_gate_lsu_o,
    output logic                               dbg_gate_mdu_o,
    output logic                               dbg_gate_csr_o,
    output logic [2:0]                         dbg_need_alu_o,
    output logic [2:0]                         dbg_need_bru_o,
    output logic [2:0]                         dbg_need_lsu_o,
    output logic [2:0]                         dbg_need_mdu_o,
    output logic [2:0]                         dbg_need_csr_o,
    output logic [$clog2(Cfg.RS_DEPTH+1)-1:0]  dbg_free_alu_o,
    output logic [$clog2(Cfg.RS_DEPTH+1)-1:0]  dbg_free_bru_o,
    output logic [$clog2(Cfg.RS_DEPTH+1)-1:0]  dbg_free_lsu_o,
    output logic [$clog2(Cfg.RS_DEPTH+1)-1:0]  dbg_free_csr_o,

    // Debug (LSU load path)
    output logic                               dbg_lsu_ld_req_valid_o,
    output logic                               dbg_lsu_ld_req_ready_o,
    output logic [Cfg.PLEN-1:0]                dbg_lsu_ld_req_addr_o,
    output logic                               dbg_lsu_ld_rsp_valid_o,
    output logic                               dbg_lsu_ld_rsp_ready_o,
    output logic [Cfg.XLEN-1:0]                dbg_lsu_ld_rsp_data_o,
    output logic                               dbg_lsu_ld_rsp_err_o,
    output logic [1:0]                         dbg_lsu_state_o,
    output logic                               dbg_lsu_ld_fire_o,
    output logic                               dbg_lsu_rsp_fire_o,
    output logic [ROB_IDX_W-1:0]               dbg_lsu_inflight_tag_o,
    output logic [Cfg.PLEN-1:0]                dbg_lsu_inflight_addr_o,
    output logic                               dbg_lsu_issue_valid_o,
    output logic                               dbg_lsu_req_ready_o,
    output logic                               dbg_lsu_issue_ready_o,
    output logic [4:0]                         dbg_lsu_free_count_o,
    output logic [3:0]                         dbg_lsu_grp_lane_busy_o,
    output logic                               dbg_lsu_grp_alloc_fire_o,
    output logic [1:0]                         dbg_lsu_grp_alloc_lane_o,
    output logic [1:0]                         dbg_lsu_grp_ld_owner_o,
    output logic [Cfg.RS_DEPTH-1:0]            dbg_lsu_rs_busy_o,
    output logic [Cfg.RS_DEPTH-1:0]            dbg_lsu_rs_ready_o,
    output logic [Cfg.RS_DEPTH-1:0]            dbg_lsu_rs_head_match_o,
    output logic                               dbg_lsu_rs_head_valid_o,
    output logic [$clog2(Cfg.RS_DEPTH)-1:0]    dbg_lsu_rs_head_idx_o,
    output logic [ROB_IDX_W-1:0]               dbg_lsu_rs_head_dst_o,
    output logic                               dbg_lsu_rs_head_r1_ready_o,
    output logic                               dbg_lsu_rs_head_r2_ready_o,
    output logic [ROB_IDX_W-1:0]               dbg_lsu_rs_head_q1_o,
    output logic [ROB_IDX_W-1:0]               dbg_lsu_rs_head_q2_o,
    output logic                               dbg_lsu_rs_head_has_rs1_o,
    output logic                               dbg_lsu_rs_head_has_rs2_o,
    output logic                               dbg_lsu_rs_head_is_store_o,
    output logic                               dbg_lsu_rs_head_is_load_o,
    output logic [SB_IDX_W-1:0]                dbg_lsu_rs_head_sb_id_o,

    // Debug (Store buffer / D$ store path)
    output logic [3:0]                         dbg_sb_alloc_req_o,
    output logic                               dbg_sb_alloc_ready_o,
    output logic                               dbg_sb_alloc_fire_o,
    output logic                               dbg_sb_dcache_req_valid_o,
    output logic                               dbg_sb_dcache_req_ready_o,
    output logic [Cfg.PLEN-1:0]                dbg_sb_dcache_req_addr_o,
    output logic [Cfg.XLEN-1:0]                dbg_sb_dcache_req_data_o,
    output logic [$bits(decode_pkg::lsu_op_e)-1:0] dbg_sb_dcache_req_op_o,
    // Debug (D$ MSHR)
    output logic [7:0]                         dbg_dc_mshr_count_o,
    output logic                               dbg_dc_mshr_full_o,
    output logic                               dbg_dc_mshr_empty_o,
    output logic                               dbg_dc_mshr_alloc_ready_o,
    output logic                               dbg_dc_mshr_req_line_hit_o,
    output logic                               dbg_dc_store_wait_same_line_o,
    output logic                               dbg_dc_store_wait_mshr_full_o,

    // Debug (ROB head / count)
    output logic [$bits(decode_pkg::fu_e)-1:0] dbg_rob_head_fu_o,
    output logic                               dbg_rob_head_complete_o,
    output logic                               dbg_rob_head_is_store_o,
    output logic [Cfg.PLEN-1:0]                dbg_rob_head_pc_o,
    output logic [6:0]                         dbg_rob_count_o,
    output logic [ROB_IDX_W-1:0]               dbg_rob_head_ptr_o,
    output logic [ROB_IDX_W-1:0]               dbg_rob_tail_ptr_o,
    output logic                               dbg_rob_q2_valid_o,
    output logic [ROB_IDX_W-1:0]               dbg_rob_q2_idx_o,
    output logic [$bits(decode_pkg::fu_e)-1:0] dbg_rob_q2_fu_o,
    output logic                               dbg_rob_q2_complete_o,
    output logic                               dbg_rob_q2_is_store_o,
    output logic [Cfg.PLEN-1:0]                dbg_rob_q2_pc_o,

    // Debug (Store Buffer head / count)
    output logic [4:0]                         dbg_sb_count_o,
    output logic [3:0]                         dbg_sb_head_ptr_o,
    output logic [3:0]                         dbg_sb_tail_ptr_o,
    output logic                               dbg_sb_head_valid_o,
    output logic                               dbg_sb_head_committed_o,
    output logic                               dbg_sb_head_addr_valid_o,
    output logic                               dbg_sb_head_data_valid_o,
    output logic [Cfg.PLEN-1:0]                dbg_sb_head_addr_o,
    // Debug (BPU RAS)
    output logic [7:0]                         dbg_bpu_arch_ras_count_o,
    output logic [7:0]                         dbg_bpu_spec_ras_count_o,
    output logic [Cfg.PLEN-1:0]                dbg_bpu_arch_ras_top_o,
    output logic [Cfg.PLEN-1:0]                dbg_bpu_spec_ras_top_o,
    output logic [63:0]                        dbg_bpu_cond_update_total_o,
    output logic [63:0]                        dbg_bpu_cond_local_correct_o,
    output logic [63:0]                        dbg_bpu_cond_global_correct_o,
    output logic [63:0]                        dbg_bpu_cond_selected_correct_o,
    output logic [63:0]                        dbg_bpu_cond_choose_local_o,
    output logic [63:0]                        dbg_bpu_cond_choose_global_o,
    // Debug (BRU mispred info)
    output logic                               dbg_bru_mispred_o,
    output logic [Cfg.PLEN-1:0]                dbg_bru_pc_o,
    output logic [Cfg.XLEN-1:0]                dbg_bru_imm_o,
    output logic [$bits(decode_pkg::branch_op_e)-1:0] dbg_bru_op_o,
    output logic                               dbg_bru_is_jump_o,
    output logic                               dbg_bru_is_branch_o,
    output logic                               dbg_bru_valid_o,
    output logic                               dbg_bru_wb_valid_o,
    output logic [Cfg.PLEN-1:0]                dbg_bru_redirect_pc_o,
    output logic [Cfg.XLEN-1:0]                dbg_bru_v1_o,
    output logic [Cfg.XLEN-1:0]                dbg_bru_v2_o
);

  // localparams provided via module parameters

  triathlon #(
      .Cfg(global_config_pkg::Cfg)
  ) dut (
      .clk_i,
      .rst_ni,

      .icache_miss_req_valid_o,
      .icache_miss_req_ready_i,
      .icache_miss_req_paddr_o,
      .icache_miss_req_victim_way_o,
      .icache_miss_req_index_o,

      .icache_refill_valid_i,
      .icache_refill_ready_o,
      .icache_refill_paddr_i,
      .icache_refill_way_i,
      .icache_refill_data_i,

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

  // Expose backend commit signals
  assign commit_valid_o = dut.u_backend.commit_valid;
  assign commit_we_o    = dut.u_backend.commit_we;
  assign commit_areg_o  = dut.u_backend.commit_areg;
  assign commit_wdata_o = dut.u_backend.commit_wdata;
  assign commit_pc_o    = dut.u_backend.commit_pc;
  assign dbg_csr_mtvec_o   = dut.u_backend.u_csr.csr_mtvec;
  assign dbg_csr_mepc_o    = dut.u_backend.u_csr.csr_mepc;
  assign dbg_csr_mstatus_o = dut.u_backend.u_csr.csr_mstatus;
  assign dbg_csr_mcause_o  = dut.u_backend.u_csr.csr_mcause;
  assign backend_flush_o = dut.u_backend.backend_flush_o;
  assign backend_redirect_pc_o = dut.u_backend.backend_redirect_pc_o;
  assign dbg_rob_flush_o = dut.u_backend.rob_flush;
  assign dbg_rob_flush_cause_o = dut.u_backend.rob_flush_cause;
  assign dbg_rob_flush_is_mispred_o = dut.u_backend.rob_flush_is_mispred;
  assign dbg_rob_flush_is_exception_o = dut.u_backend.rob_flush_is_exception;
  assign dbg_rob_flush_is_branch_o = dut.u_backend.rob_flush_is_branch;
  assign dbg_rob_flush_is_jump_o = dut.u_backend.rob_flush_is_jump;
  assign dbg_rob_flush_src_pc_o = dut.u_backend.rob_flush_src_pc;

  // Debug: frontend/backend handshakes
  assign dbg_fe_valid_o = dut.fe_ibuf_valid;
  assign dbg_fe_ready_o = dut.fe_ibuf_ready;
  assign dbg_fe_pc_o    = dut.fe_ibuf_pc;
  assign dbg_fe_instrs_o = dut.fe_ibuf_instrs;
  assign dbg_fe_slot_valid_o = dut.fe_ibuf_slot_valid;
  assign dbg_fe_pred_npc_o = dut.fe_ibuf_pred_npc;
  assign dbg_ifu_req_valid_o = dut.u_frontend.i_ifu.req_issue_valid_w;
  assign dbg_ifu_req_ready_o = dut.u_frontend.icache2ifu_rsp_handshake.ready;
  assign dbg_ifu_req_fire_o = dut.u_frontend.i_ifu.req_issue_fire_w;
  assign dbg_ifu_req_inflight_o = (dut.u_frontend.i_ifu.inf_count_q != '0);
  assign dbg_ifu_rsp_valid_o = dut.u_frontend.icache2ifu_rsp_handshake.valid;
  assign dbg_ifu_rsp_capture_o = dut.u_frontend.i_ifu.rsp_capture_w;
  assign dbg_icache_state_o = dut.u_frontend.i_icache.state_q;
  assign dbg_ifu_fq_count_o = dut.u_frontend.i_ifu.fq_count_q;
  assign dbg_ifu_fq_full_o = dut.u_frontend.i_ifu.fq_full_w;
  assign dbg_ifu_fq_empty_o = dut.u_frontend.i_ifu.fq_empty_w;
  assign dbg_ifu_ibuf_pop_o = dut.u_frontend.i_ifu.ibuf_pop_w;
  assign dbg_dec_valid_o = dut.u_backend.decode_ibuf_valid;
  assign dbg_dec_ready_o = dut.u_backend.decode_ibuf_ready;
  assign dbg_rob_ready_o = dut.u_backend.rob_ready;
  assign dbg_ren_src_from_pending_o = dut.u_backend.rename_src_from_pending;
  assign dbg_ren_sel_count_o = dut.u_backend.rename_sel_count;
  assign dbg_ren_fire_o = dut.u_backend.rename_fire;
  assign dbg_ren_ready_o = dut.u_backend.rename_ready;

  always_comb begin
    dbg_ren_src_count_o = '0;
    for (int i = 0; i < Cfg.INSTR_PER_FETCH; i++) begin
      if (dut.u_backend.rename_src_valid[i]) begin
        dbg_ren_src_count_o++;
      end
    end
  end

  assign dbg_gate_alu_o = dut.u_backend.alu_can_accept;
  assign dbg_gate_bru_o = dut.u_backend.bru_can_accept;
  assign dbg_gate_lsu_o = dut.u_backend.lsu_can_accept;
  assign dbg_gate_mdu_o = dut.u_backend.mdu_can_accept;
  assign dbg_gate_csr_o = dut.u_backend.csr_can_accept;
  assign dbg_need_alu_o = dut.u_backend.alu_need_cnt;
  assign dbg_need_bru_o = dut.u_backend.bru_need_cnt;
  assign dbg_need_lsu_o = dut.u_backend.lsu_need_cnt;
  assign dbg_need_mdu_o = dut.u_backend.mdu_need_cnt;
  assign dbg_need_csr_o = dut.u_backend.csr_need_cnt;
  assign dbg_free_alu_o = dut.u_backend.alu_free_count;
  assign dbg_free_bru_o = dut.u_backend.bru_free_count;
  assign dbg_free_lsu_o = dut.u_backend.lsu_free_count;
  assign dbg_free_csr_o = dut.u_backend.csr_free_count;

  // Debug: LSU load path
  assign dbg_lsu_ld_req_valid_o = dut.u_backend.lsu_ld_req_valid;
  assign dbg_lsu_ld_req_ready_o = dut.u_backend.lsu_ld_req_ready;
  assign dbg_lsu_ld_req_addr_o  = dut.u_backend.lsu_ld_req_addr;
  assign dbg_lsu_ld_rsp_valid_o = dut.u_backend.lsu_ld_rsp_valid;
  assign dbg_lsu_ld_rsp_ready_o = dut.u_backend.lsu_ld_rsp_ready;
  assign dbg_lsu_ld_rsp_data_o  = dut.u_backend.lsu_ld_rsp_data;
  assign dbg_lsu_ld_rsp_err_o   = dut.u_backend.lsu_ld_rsp_err;
  assign dbg_lsu_state_o        = dut.u_backend.u_lsu_group.state_q;
  assign dbg_lsu_ld_fire_o      = dut.u_backend.lsu_ld_req_valid & dut.u_backend.lsu_ld_req_ready;
  assign dbg_lsu_rsp_fire_o     = dut.u_backend.lsu_ld_rsp_valid & dut.u_backend.lsu_ld_rsp_ready;
  assign dbg_lsu_inflight_tag_o = dut.u_backend.u_lsu_group.req_tag_q;
  assign dbg_lsu_inflight_addr_o = dut.u_backend.u_lsu_group.req_addr_q;
  assign dbg_lsu_issue_valid_o  = dut.u_backend.lsu_en;
  assign dbg_lsu_req_ready_o    = dut.u_backend.lsu_req_ready;
  assign dbg_lsu_issue_ready_o  = dut.u_backend.lsu_issue_ready;
  assign dbg_lsu_free_count_o   = dut.u_backend.lsu_free_count;
  assign dbg_lsu_grp_lane_busy_o = dut.u_backend.u_lsu_group.dbg_lane_busy;
  assign dbg_lsu_grp_alloc_fire_o = dut.u_backend.u_lsu_group.dbg_alloc_fire;
  assign dbg_lsu_grp_alloc_lane_o = dut.u_backend.u_lsu_group.dbg_alloc_lane;
  assign dbg_lsu_grp_ld_owner_o = dut.u_backend.u_lsu_group.dbg_ld_owner;
  assign dbg_lsu_rs_busy_o      = dut.u_backend.u_issue_lsu.u_rs.busy;
  assign dbg_lsu_rs_ready_o     = dut.u_backend.u_issue_lsu.u_rs.ready_mask;

  logic [Cfg.RS_DEPTH-1:0] lsu_rs_head_match;
  logic lsu_rs_head_found;
  logic [$clog2(Cfg.RS_DEPTH)-1:0] lsu_rs_head_idx;

  always_comb begin
    lsu_rs_head_match = '0;
    for (int i = 0; i < Cfg.RS_DEPTH; i++) begin
      if (dut.u_backend.u_issue_lsu.u_rs.busy[i] &&
          (dut.u_backend.u_issue_lsu.u_rs.dst_arr[i] == dut.u_backend.rob_head_ptr)) begin
        lsu_rs_head_match[i] = 1'b1;
      end
    end
  end

  always_comb begin
    lsu_rs_head_found = 1'b0;
    lsu_rs_head_idx = '0;
    for (int i = 0; i < Cfg.RS_DEPTH; i++) begin
      if (!lsu_rs_head_found && lsu_rs_head_match[i]) begin
        lsu_rs_head_found = 1'b1;
        lsu_rs_head_idx = i[$clog2(Cfg.RS_DEPTH)-1:0];
      end
    end
  end

  assign dbg_lsu_rs_head_match_o = lsu_rs_head_match;
  assign dbg_lsu_rs_head_valid_o = lsu_rs_head_found;
  assign dbg_lsu_rs_head_idx_o   = lsu_rs_head_idx;
  assign dbg_lsu_rs_head_dst_o   = lsu_rs_head_found
                                  ? dut.u_backend.u_issue_lsu.u_rs.dst_arr[lsu_rs_head_idx]
                                  : '0;
  assign dbg_lsu_rs_head_r1_ready_o = lsu_rs_head_found
                                     ? dut.u_backend.u_issue_lsu.u_rs.r1_arr[lsu_rs_head_idx]
                                     : 1'b0;
  assign dbg_lsu_rs_head_r2_ready_o = lsu_rs_head_found
                                     ? dut.u_backend.u_issue_lsu.u_rs.r2_arr[lsu_rs_head_idx]
                                     : 1'b0;
  assign dbg_lsu_rs_head_q1_o = lsu_rs_head_found
                              ? dut.u_backend.u_issue_lsu.u_rs.q1_arr[lsu_rs_head_idx]
                              : '0;
  assign dbg_lsu_rs_head_q2_o = lsu_rs_head_found
                              ? dut.u_backend.u_issue_lsu.u_rs.q2_arr[lsu_rs_head_idx]
                              : '0;
  assign dbg_lsu_rs_head_has_rs1_o = lsu_rs_head_found
                                   ? dut.u_backend.u_issue_lsu.u_rs.op_arr[lsu_rs_head_idx].has_rs1
                                   : 1'b0;
  assign dbg_lsu_rs_head_has_rs2_o = lsu_rs_head_found
                                   ? dut.u_backend.u_issue_lsu.u_rs.op_arr[lsu_rs_head_idx].has_rs2
                                   : 1'b0;
  assign dbg_lsu_rs_head_is_store_o = lsu_rs_head_found
                                    ? dut.u_backend.u_issue_lsu.u_rs.op_arr[lsu_rs_head_idx].is_store
                                    : 1'b0;
  assign dbg_lsu_rs_head_is_load_o = lsu_rs_head_found
                                   ? dut.u_backend.u_issue_lsu.u_rs.op_arr[lsu_rs_head_idx].is_load
                                   : 1'b0;
  assign dbg_lsu_rs_head_sb_id_o = lsu_rs_head_found
                                 ? dut.u_backend.u_issue_lsu.u_rs.sb_arr[lsu_rs_head_idx]
                                 : '0;

  // Debug: Store buffer / D$ store path
  assign dbg_sb_alloc_req_o = dut.u_backend.sb_alloc_req;
  assign dbg_sb_alloc_ready_o = dut.u_backend.sb_alloc_ready;
  assign dbg_sb_alloc_fire_o  = dut.u_backend.sb_alloc_fire;
  assign dbg_sb_dcache_req_valid_o = dut.u_backend.sb_dcache_req_valid;
  assign dbg_sb_dcache_req_ready_o = dut.u_backend.sb_dcache_req_ready;
  assign dbg_sb_dcache_req_addr_o  = dut.u_backend.sb_dcache_req_addr;
  assign dbg_sb_dcache_req_data_o  = dut.u_backend.sb_dcache_req_data;
  assign dbg_sb_dcache_req_op_o    = dut.u_backend.sb_dcache_req_op;
  assign dbg_dc_mshr_count_o = {4'b0, dut.u_backend.u_dcache.mshr_count};
  assign dbg_dc_mshr_full_o = dut.u_backend.u_dcache.mshr_full;
  assign dbg_dc_mshr_empty_o = dut.u_backend.u_dcache.mshr_empty;
  assign dbg_dc_mshr_alloc_ready_o = dut.u_backend.u_dcache.mshr_alloc_ready;
  assign dbg_dc_mshr_req_line_hit_o = dut.u_backend.u_dcache.mshr_req_line_hit;
  assign dbg_dc_store_wait_same_line_o =
      dut.u_backend.sb_dcache_req_valid &&
      !dut.u_backend.sb_dcache_req_ready &&
      dut.u_backend.u_dcache.mshr_req_line_hit;
  assign dbg_dc_store_wait_mshr_full_o =
      dut.u_backend.sb_dcache_req_valid &&
      !dut.u_backend.sb_dcache_req_ready &&
      !dut.u_backend.u_dcache.mshr_alloc_ready;

  // Debug: ROB head state
  assign dbg_rob_head_fu_o       = dut.u_backend.u_rob.rob_ram[dut.u_backend.u_rob.head_ptr_q].fu_type;
  assign dbg_rob_head_complete_o = dut.u_backend.u_rob.rob_ram[dut.u_backend.u_rob.head_ptr_q].complete;
  assign dbg_rob_head_is_store_o = dut.u_backend.u_rob.rob_ram[dut.u_backend.u_rob.head_ptr_q].is_store;
  assign dbg_rob_head_pc_o       = dut.u_backend.u_rob.rob_ram[dut.u_backend.u_rob.head_ptr_q].pc;
  assign dbg_rob_count_o         = dut.u_backend.u_rob.count_q;
  assign dbg_rob_head_ptr_o      = dut.u_backend.u_rob.head_ptr_q;
  assign dbg_rob_tail_ptr_o      = dut.u_backend.u_rob.tail_ptr_q;

  logic [ROB_IDX_W-1:0] rob_q2_idx;
  always_comb begin
    if (lsu_rs_head_found) begin
      rob_q2_idx = dut.u_backend.u_issue_lsu.u_rs.q2_arr[lsu_rs_head_idx];
    end else begin
      rob_q2_idx = '0;
    end
  end

  assign dbg_rob_q2_valid_o = lsu_rs_head_found;
  assign dbg_rob_q2_idx_o   = rob_q2_idx;
  assign dbg_rob_q2_fu_o    = lsu_rs_head_found
                              ? dut.u_backend.u_rob.rob_ram[rob_q2_idx].fu_type
                              : '0;
  assign dbg_rob_q2_complete_o = lsu_rs_head_found
                                ? dut.u_backend.u_rob.rob_ram[rob_q2_idx].complete
                                : 1'b0;
  assign dbg_rob_q2_is_store_o = lsu_rs_head_found
                                ? dut.u_backend.u_rob.rob_ram[rob_q2_idx].is_store
                                : 1'b0;
  assign dbg_rob_q2_pc_o       = lsu_rs_head_found
                                ? dut.u_backend.u_rob.rob_ram[rob_q2_idx].pc
                                : '0;

  // Debug: Store Buffer head state
  assign dbg_sb_count_o          = dut.u_backend.u_sb.count;
  assign dbg_sb_head_ptr_o       = dut.u_backend.u_sb.head_ptr;
  assign dbg_sb_tail_ptr_o       = dut.u_backend.u_sb.tail_ptr;
  assign dbg_sb_head_valid_o     = dut.u_backend.u_sb.mem[dut.u_backend.u_sb.head_ptr].valid;
  assign dbg_sb_head_committed_o = dut.u_backend.u_sb.mem[dut.u_backend.u_sb.head_ptr].committed;
  assign dbg_sb_head_addr_valid_o = dut.u_backend.u_sb.mem[dut.u_backend.u_sb.head_ptr].addr_valid;
  assign dbg_sb_head_data_valid_o = dut.u_backend.u_sb.mem[dut.u_backend.u_sb.head_ptr].data_valid;
  assign dbg_sb_head_addr_o      = dut.u_backend.u_sb.mem[dut.u_backend.u_sb.head_ptr].addr;
  assign dbg_bpu_arch_ras_count_o = {3'b0, dut.u_frontend.i_bpu.arch_ras_count_q};
  assign dbg_bpu_spec_ras_count_o = {3'b0, dut.u_frontend.i_bpu.spec_ras_count_q};
  assign dbg_bpu_arch_ras_top_o = dut.u_frontend.i_bpu.arch_ras_top_w;
  assign dbg_bpu_spec_ras_top_o = dut.u_frontend.i_bpu.spec_ras_top_w;
  assign dbg_bpu_cond_update_total_o = dut.u_frontend.i_bpu.dbg_cond_update_total_q;
  assign dbg_bpu_cond_local_correct_o = dut.u_frontend.i_bpu.dbg_cond_local_correct_q;
  assign dbg_bpu_cond_global_correct_o = dut.u_frontend.i_bpu.dbg_cond_global_correct_q;
  assign dbg_bpu_cond_selected_correct_o = dut.u_frontend.i_bpu.dbg_cond_selected_correct_q;
  assign dbg_bpu_cond_choose_local_o = dut.u_frontend.i_bpu.dbg_cond_choose_local_q;
  assign dbg_bpu_cond_choose_global_o = dut.u_frontend.i_bpu.dbg_cond_choose_global_q;

  // Debug: BRU info (from backend execute)
  assign dbg_bru_mispred_o  = dut.u_backend.bru_mispred;
  assign dbg_bru_pc_o       = dut.u_backend.bru_uop.pc;
  assign dbg_bru_imm_o      = dut.u_backend.bru_uop.imm;
  assign dbg_bru_op_o       = dut.u_backend.bru_uop.br_op;
  assign dbg_bru_is_jump_o  = dut.u_backend.bru_uop.is_jump;
  assign dbg_bru_is_branch_o = dut.u_backend.bru_uop.is_branch;
  assign dbg_bru_valid_o    = dut.u_backend.bru_en;
  assign dbg_bru_wb_valid_o = dut.u_backend.bru_wb_valid;
  assign dbg_bru_redirect_pc_o = dut.u_backend.bru_redirect_pc;
  assign dbg_bru_v1_o = dut.u_backend.bru_v1;
  assign dbg_bru_v2_o = dut.u_backend.bru_v2;

endmodule
