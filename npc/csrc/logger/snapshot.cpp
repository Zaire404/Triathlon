#include "logger/snapshot.h"

#include "Vtb_triathlon.h"

Snapshot collect_snapshot(const Vtb_triathlon *top,
                          uint64_t cycles,
                          uint64_t total_commits,
                          uint64_t no_commit_cycles,
                          uint32_t last_commit_pc,
                          uint32_t last_commit_inst,
                          uint32_t a0) {
  Snapshot snap{};
  snap.cycles = cycles;
  snap.total_commits = total_commits;
  snap.no_commit_cycles = no_commit_cycles;
  snap.last_commit_pc = last_commit_pc;
  snap.last_commit_inst = last_commit_inst;
  snap.a0 = a0;

  snap.dbg_fe_valid = static_cast<uint8_t>(top->dbg_fe_valid_o);
  snap.dbg_fe_ready = static_cast<uint8_t>(top->dbg_fe_ready_o);
  snap.dbg_fe_pc = static_cast<uint32_t>(top->dbg_fe_pc_o);
  for (int i = 0; i < 4; i++) {
    snap.dbg_fe_instrs[i] = static_cast<uint32_t>(top->dbg_fe_instrs_o[i]);
  }

  snap.dbg_dec_valid = static_cast<uint8_t>(top->dbg_dec_valid_o);
  snap.dbg_dec_ready = static_cast<uint8_t>(top->dbg_dec_ready_o);
  snap.dbg_rob_ready = static_cast<uint8_t>(top->dbg_rob_ready_o);

  snap.dbg_lsu_ld_req_valid = static_cast<uint8_t>(top->dbg_lsu_ld_req_valid_o);
  snap.dbg_lsu_ld_req_ready = static_cast<uint8_t>(top->dbg_lsu_ld_req_ready_o);
  snap.dbg_lsu_ld_req_addr = static_cast<uint32_t>(top->dbg_lsu_ld_req_addr_o);
  snap.dbg_lsu_ld_rsp_valid = static_cast<uint8_t>(top->dbg_lsu_ld_rsp_valid_o);
  snap.dbg_lsu_ld_rsp_ready = static_cast<uint8_t>(top->dbg_lsu_ld_rsp_ready_o);

  snap.dbg_lsu_issue_valid = static_cast<uint8_t>(top->dbg_lsu_issue_valid_o);
  snap.dbg_lsu_req_ready = static_cast<uint8_t>(top->dbg_lsu_req_ready_o);
  snap.dbg_lsu_issue_ready = static_cast<uint8_t>(top->dbg_lsu_issue_ready_o);
  snap.dbg_lsu_free_count = static_cast<uint32_t>(top->dbg_lsu_free_count_o);

  snap.dbg_lsu_rs_busy = static_cast<uint32_t>(top->dbg_lsu_rs_busy_o);
  snap.dbg_lsu_rs_ready = static_cast<uint32_t>(top->dbg_lsu_rs_ready_o);
  snap.dbg_lsu_rs_head_valid = static_cast<uint8_t>(top->dbg_lsu_rs_head_valid_o);
  snap.dbg_lsu_rs_head_idx = static_cast<uint32_t>(top->dbg_lsu_rs_head_idx_o);
  snap.dbg_lsu_rs_head_dst = static_cast<uint32_t>(top->dbg_lsu_rs_head_dst_o);
  snap.dbg_lsu_rs_head_r1_ready = static_cast<uint8_t>(top->dbg_lsu_rs_head_r1_ready_o);
  snap.dbg_lsu_rs_head_r2_ready = static_cast<uint8_t>(top->dbg_lsu_rs_head_r2_ready_o);
  snap.dbg_lsu_rs_head_has_rs1 = static_cast<uint8_t>(top->dbg_lsu_rs_head_has_rs1_o);
  snap.dbg_lsu_rs_head_has_rs2 = static_cast<uint8_t>(top->dbg_lsu_rs_head_has_rs2_o);
  snap.dbg_lsu_rs_head_q1 = static_cast<uint32_t>(top->dbg_lsu_rs_head_q1_o);
  snap.dbg_lsu_rs_head_q2 = static_cast<uint32_t>(top->dbg_lsu_rs_head_q2_o);
  snap.dbg_lsu_rs_head_sb_id = static_cast<uint32_t>(top->dbg_lsu_rs_head_sb_id_o);
  snap.dbg_lsu_rs_head_is_load = static_cast<uint8_t>(top->dbg_lsu_rs_head_is_load_o);
  snap.dbg_lsu_rs_head_is_store = static_cast<uint8_t>(top->dbg_lsu_rs_head_is_store_o);

  snap.dbg_sb_alloc_req = static_cast<uint32_t>(top->dbg_sb_alloc_req_o);
  snap.dbg_sb_alloc_ready = static_cast<uint8_t>(top->dbg_sb_alloc_ready_o);
  snap.dbg_sb_alloc_fire = static_cast<uint8_t>(top->dbg_sb_alloc_fire_o);

  snap.dbg_sb_dcache_req_valid = static_cast<uint8_t>(top->dbg_sb_dcache_req_valid_o);
  snap.dbg_sb_dcache_req_ready = static_cast<uint8_t>(top->dbg_sb_dcache_req_ready_o);
  snap.dbg_sb_dcache_req_addr = static_cast<uint32_t>(top->dbg_sb_dcache_req_addr_o);

  snap.icache_miss_req_valid = static_cast<uint8_t>(top->icache_miss_req_valid_o);
  snap.icache_miss_req_ready = static_cast<uint8_t>(top->icache_miss_req_ready_i);
  snap.dcache_miss_req_valid = static_cast<uint8_t>(top->dcache_miss_req_valid_o);
  snap.dcache_miss_req_ready = static_cast<uint8_t>(top->dcache_miss_req_ready_i);

  snap.backend_flush = static_cast<uint8_t>(top->backend_flush_o);
  snap.backend_redirect_pc = static_cast<uint32_t>(top->backend_redirect_pc_o);
  snap.dbg_bru_valid = static_cast<uint8_t>(top->dbg_bru_valid_o);
  snap.dbg_bru_mispred = static_cast<uint8_t>(top->dbg_bru_mispred_o);
  snap.dbg_bru_pc = static_cast<uint32_t>(top->dbg_bru_pc_o);
  snap.dbg_bru_imm = static_cast<uint32_t>(top->dbg_bru_imm_o);
  snap.dbg_bru_op = static_cast<uint32_t>(top->dbg_bru_op_o);
  snap.dbg_bru_is_jump = static_cast<uint8_t>(top->dbg_bru_is_jump_o);
  snap.dbg_bru_is_branch = static_cast<uint8_t>(top->dbg_bru_is_branch_o);

  snap.dbg_rob_head_fu = static_cast<uint32_t>(top->dbg_rob_head_fu_o);
  snap.dbg_rob_head_complete = static_cast<uint8_t>(top->dbg_rob_head_complete_o);
  snap.dbg_rob_head_is_store = static_cast<uint8_t>(top->dbg_rob_head_is_store_o);
  snap.dbg_rob_head_pc = static_cast<uint32_t>(top->dbg_rob_head_pc_o);
  snap.dbg_rob_count = static_cast<uint32_t>(top->dbg_rob_count_o);
  snap.dbg_rob_head_ptr = static_cast<uint32_t>(top->dbg_rob_head_ptr_o);
  snap.dbg_rob_tail_ptr = static_cast<uint32_t>(top->dbg_rob_tail_ptr_o);

  snap.dbg_rob_q2_valid = static_cast<uint8_t>(top->dbg_rob_q2_valid_o);
  snap.dbg_rob_q2_idx = static_cast<uint32_t>(top->dbg_rob_q2_idx_o);
  snap.dbg_rob_q2_fu = static_cast<uint32_t>(top->dbg_rob_q2_fu_o);
  snap.dbg_rob_q2_complete = static_cast<uint8_t>(top->dbg_rob_q2_complete_o);
  snap.dbg_rob_q2_is_store = static_cast<uint8_t>(top->dbg_rob_q2_is_store_o);
  snap.dbg_rob_q2_pc = static_cast<uint32_t>(top->dbg_rob_q2_pc_o);

  snap.dbg_sb_count = static_cast<uint32_t>(top->dbg_sb_count_o);
  snap.dbg_sb_head_ptr = static_cast<uint32_t>(top->dbg_sb_head_ptr_o);
  snap.dbg_sb_tail_ptr = static_cast<uint32_t>(top->dbg_sb_tail_ptr_o);
  snap.dbg_sb_head_valid = static_cast<uint8_t>(top->dbg_sb_head_valid_o);
  snap.dbg_sb_head_committed = static_cast<uint8_t>(top->dbg_sb_head_committed_o);
  snap.dbg_sb_head_addr_valid = static_cast<uint8_t>(top->dbg_sb_head_addr_valid_o);
  snap.dbg_sb_head_data_valid = static_cast<uint8_t>(top->dbg_sb_head_data_valid_o);
  snap.dbg_sb_head_addr = static_cast<uint32_t>(top->dbg_sb_head_addr_o);

  return snap;
}
