#pragma once

#include <array>
#include <cstdint>

struct Snapshot {
  uint64_t cycles = 0;
  uint64_t total_commits = 0;
  uint64_t no_commit_cycles = 0;
  uint32_t last_commit_pc = 0;
  uint32_t last_commit_inst = 0;
  uint32_t a0 = 0;

  uint8_t dbg_fe_valid = 0;
  uint8_t dbg_fe_ready = 0;
  uint32_t dbg_fe_pc = 0;
  std::array<uint32_t, 4> dbg_fe_instrs{};
  std::array<uint32_t, 4> mem_fe_instrs{};
  uint32_t fe_mismatch_mask = 0;

  uint8_t dbg_dec_valid = 0;
  uint8_t dbg_dec_ready = 0;
  uint8_t dbg_rob_ready = 0;

  uint8_t dbg_lsu_ld_req_valid = 0;
  uint8_t dbg_lsu_ld_req_ready = 0;
  uint32_t dbg_lsu_ld_req_addr = 0;
  uint8_t dbg_lsu_ld_rsp_valid = 0;
  uint8_t dbg_lsu_ld_rsp_ready = 0;

  uint8_t dbg_lsu_issue_valid = 0;
  uint8_t dbg_lsu_req_ready = 0;
  uint8_t dbg_lsu_issue_ready = 0;
  uint32_t dbg_lsu_free_count = 0;

  uint32_t dbg_lsu_rs_busy = 0;
  uint32_t dbg_lsu_rs_ready = 0;
  uint8_t dbg_lsu_rs_head_valid = 0;
  uint32_t dbg_lsu_rs_head_idx = 0;
  uint32_t dbg_lsu_rs_head_dst = 0;
  uint8_t dbg_lsu_rs_head_r1_ready = 0;
  uint8_t dbg_lsu_rs_head_r2_ready = 0;
  uint8_t dbg_lsu_rs_head_has_rs1 = 0;
  uint8_t dbg_lsu_rs_head_has_rs2 = 0;
  uint32_t dbg_lsu_rs_head_q1 = 0;
  uint32_t dbg_lsu_rs_head_q2 = 0;
  uint32_t dbg_lsu_rs_head_sb_id = 0;
  uint8_t dbg_lsu_rs_head_is_load = 0;
  uint8_t dbg_lsu_rs_head_is_store = 0;

  uint32_t dbg_sb_alloc_req = 0;
  uint8_t dbg_sb_alloc_ready = 0;
  uint8_t dbg_sb_alloc_fire = 0;

  uint8_t dbg_sb_dcache_req_valid = 0;
  uint8_t dbg_sb_dcache_req_ready = 0;
  uint32_t dbg_sb_dcache_req_addr = 0;

  uint8_t icache_miss_req_valid = 0;
  uint8_t icache_miss_req_ready = 0;
  uint8_t dcache_miss_req_valid = 0;
  uint8_t dcache_miss_req_ready = 0;

  uint8_t backend_flush = 0;
  uint32_t backend_redirect_pc = 0;

  uint8_t dbg_bru_valid = 0;
  uint8_t dbg_bru_mispred = 0;
  uint32_t dbg_bru_pc = 0;
  uint32_t dbg_bru_imm = 0;
  uint32_t dbg_bru_op = 0;
  uint8_t dbg_bru_is_jump = 0;
  uint8_t dbg_bru_is_branch = 0;

  uint32_t dbg_rob_head_fu = 0;
  uint8_t dbg_rob_head_complete = 0;
  uint8_t dbg_rob_head_is_store = 0;
  uint32_t dbg_rob_head_pc = 0;
  uint32_t dbg_rob_count = 0;
  uint32_t dbg_rob_head_ptr = 0;
  uint32_t dbg_rob_tail_ptr = 0;

  uint8_t dbg_rob_q2_valid = 0;
  uint32_t dbg_rob_q2_idx = 0;
  uint32_t dbg_rob_q2_fu = 0;
  uint8_t dbg_rob_q2_complete = 0;
  uint8_t dbg_rob_q2_is_store = 0;
  uint32_t dbg_rob_q2_pc = 0;

  uint32_t dbg_sb_count = 0;
  uint32_t dbg_sb_head_ptr = 0;
  uint32_t dbg_sb_tail_ptr = 0;
  uint8_t dbg_sb_head_valid = 0;
  uint8_t dbg_sb_head_committed = 0;
  uint8_t dbg_sb_head_addr_valid = 0;
  uint8_t dbg_sb_head_data_valid = 0;
  uint32_t dbg_sb_head_addr = 0;

  uint64_t perf_cycles = 0;
  uint64_t perf_commit_cycles = 0;
  uint64_t perf_commit_instrs = 0;
  uint64_t perf_nocommit_cycles = 0;
  uint64_t perf_fe_empty_cycles = 0;
  uint64_t perf_fe_stall_cycles = 0;
  uint64_t perf_dec_stall_cycles = 0;
  uint64_t perf_rob_full_cycles = 0;
  uint64_t perf_issue_full_cycles = 0;
  uint64_t perf_alu_full_cycles = 0;
  uint64_t perf_bru_full_cycles = 0;
  uint64_t perf_lsu_full_cycles = 0;
  uint64_t perf_csr_full_cycles = 0;
  uint64_t perf_sb_full_cycles = 0;
  uint64_t perf_icache_miss_cycles = 0;
  uint64_t perf_dcache_miss_cycles = 0;
  uint64_t perf_flush_cycles = 0;
  uint64_t perf_icache_miss_reqs = 0;
  uint64_t perf_dcache_miss_reqs = 0;
  uint64_t perf_ifu_start_cycles = 0;
  uint64_t perf_ifu_wait_icache_cycles = 0;
  uint64_t perf_ifu_wait_ibuf_cycles = 0;
  uint64_t perf_icache_idle_cycles = 0;
  uint64_t perf_icache_lookup_cycles = 0;
  uint64_t perf_icache_miss_req_cycles = 0;
  uint64_t perf_icache_wait_refill_cycles = 0;
  uint64_t perf_lsu_idle_cycles = 0;
  uint64_t perf_lsu_ld_req_cycles = 0;
  uint64_t perf_lsu_ld_rsp_cycles = 0;
  uint64_t perf_lsu_resp_cycles = 0;
  uint64_t perf_dcache_idle_cycles = 0;
  uint64_t perf_dcache_lookup_cycles = 0;
  uint64_t perf_dcache_store_write_cycles = 0;
  uint64_t perf_dcache_wb_req_cycles = 0;
  uint64_t perf_dcache_miss_req_cycles = 0;
  uint64_t perf_dcache_wait_refill_cycles = 0;
  uint64_t perf_dcache_resp_cycles = 0;
};

struct Vtb_triathlon;

Snapshot collect_snapshot(const Vtb_triathlon *top,
                          uint64_t cycles,
                          uint64_t total_commits,
                          uint64_t no_commit_cycles,
                          uint32_t last_commit_pc,
                          uint32_t last_commit_inst,
                          uint32_t a0);
