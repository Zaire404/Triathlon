#include "logger/logger.h"

#include <iterator>

#include <fmt/format.h>
#include <spdlog/sinks/stdout_color_sinks.h>
#include <spdlog/spdlog.h>

namespace {
LogConfig g_config{};

void append_lsu_rs_state(fmt::memory_buffer& buf, const Snapshot& snap) {
  fmt::format_to(
      std::back_inserter(buf),
      " lsu_rs(b/r)=0x{:x}/0x{:x} lsu_rs_head(v/idx/dst)={}/0x{:x}/0x{:x}"
      " lsu_rs_head(rs1r/rs2r/has1/has2)={}/{}/{}/{}"
      " lsu_rs_head(q1/q2/sb)=0x{:x}/0x{:x}/0x{:x} lsu_rs_head(ld/st)={}/{}",
      snap.dbg_lsu_rs_busy, snap.dbg_lsu_rs_ready,
      static_cast<int>(snap.dbg_lsu_rs_head_valid), snap.dbg_lsu_rs_head_idx,
      snap.dbg_lsu_rs_head_dst, static_cast<int>(snap.dbg_lsu_rs_head_r1_ready),
      static_cast<int>(snap.dbg_lsu_rs_head_r2_ready),
      static_cast<int>(snap.dbg_lsu_rs_head_has_rs1),
      static_cast<int>(snap.dbg_lsu_rs_head_has_rs2), snap.dbg_lsu_rs_head_q1,
      snap.dbg_lsu_rs_head_q2, snap.dbg_lsu_rs_head_sb_id,
      static_cast<int>(snap.dbg_lsu_rs_head_is_load),
      static_cast<int>(snap.dbg_lsu_rs_head_is_store));
}

void append_rob_sb_state(fmt::memory_buffer& buf, const Snapshot& snap) {
  fmt::format_to(
      std::back_inserter(buf),
      " rob_cnt={} rob_ptr(h/t)=0x{:x}/0x{:x}"
      " rob_q2(v/idx/fu/comp/st/pc)={}/0x{:x}/0x{:x}/{}/{}/0x{:x}"
      " sb(cnt/h/t)=0x{:x}/0x{:x}/0x{:x}"
      " sb_head(v/c/a/d/addr)={}/{}/{}/{}/0x{:x}",
      snap.dbg_rob_count, snap.dbg_rob_head_ptr, snap.dbg_rob_tail_ptr,
      static_cast<int>(snap.dbg_rob_q2_valid), snap.dbg_rob_q2_idx,
      snap.dbg_rob_q2_fu, static_cast<int>(snap.dbg_rob_q2_complete),
      static_cast<int>(snap.dbg_rob_q2_is_store), snap.dbg_rob_q2_pc,
      snap.dbg_sb_count, snap.dbg_sb_head_ptr, snap.dbg_sb_tail_ptr,
      static_cast<int>(snap.dbg_sb_head_valid),
      static_cast<int>(snap.dbg_sb_head_committed),
      static_cast<int>(snap.dbg_sb_head_addr_valid),
      static_cast<int>(snap.dbg_sb_head_data_valid), snap.dbg_sb_head_addr);
}
}  // namespace

void Logger::init(const LogConfig& config) {
  g_config = config;
  if (!spdlog::get("npc")) {
    auto logger = spdlog::stdout_color_mt("npc");
    spdlog::set_default_logger(logger);
  }
  spdlog::set_pattern("%v");
}

void Logger::shutdown() { spdlog::shutdown(); }

const LogConfig& Logger::config() { return g_config; }

void Logger::log_commit(uint64_t cycle, uint32_t slot, uint32_t pc,
                        uint32_t inst, bool we, uint32_t rd, uint32_t data,
                        uint32_t a0) {
  if (!g_config.commit_trace) return;
  spdlog::info(
      "[commit] cycle={} slot={} pc=0x{:x} inst=0x{:x} we={} rd=x{} "
      "data=0x{:x} "
      "a0=0x{:x}",
      cycle, slot, pc, inst, static_cast<int>(we), rd, data, a0);
}

void Logger::log_stall(const Snapshot& snap) {
  if (!g_config.stall_trace) return;
  spdlog::info("{}", format_stall(snap));
}

void Logger::log_progress(const Snapshot& snap) {
  if (g_config.progress_interval == 0) return;
  spdlog::info("{}", format_progress(snap));
}

void Logger::log_perf(const Snapshot& snap, double ipc, double cpi) {
  uint64_t cycles = snap.perf_cycles ? snap.perf_cycles : snap.cycles;
  uint64_t commit_instrs =
      snap.perf_commit_instrs ? snap.perf_commit_instrs : snap.total_commits;
  uint64_t commit_cycles = snap.perf_commit_cycles;
  uint64_t nocommit_cycles = snap.perf_nocommit_cycles;
  auto pct = [&](uint64_t v) -> double {
    if (cycles == 0) return 0.0;
    return 100.0 * static_cast<double>(v) / static_cast<double>(cycles);
  };

  spdlog::info(
      "IPC={} CPI={} cycles={} commit_instrs={} commit_cycles={} "
      "no_commit_cycles={}",
      ipc, cpi, cycles, commit_instrs, commit_cycles, nocommit_cycles);
  spdlog::info(
      "stall cycles (not exclusive) fe_empty={}({:.1f}%) fe_stall={}({:.1f}%) "
      "dec_stall={}({:.1f}%) rob_full={}({:.1f}%) "
      "issue_full={}({:.1f}%) sb_full={}({:.1f}%) ic_miss={}({:.1f}%) "
      "dc_miss={}({:.1f}%) flush={}({:.1f}%)",
      snap.perf_fe_empty_cycles, pct(snap.perf_fe_empty_cycles),
      snap.perf_fe_stall_cycles, pct(snap.perf_fe_stall_cycles),
      snap.perf_dec_stall_cycles, pct(snap.perf_dec_stall_cycles),
      snap.perf_rob_full_cycles, pct(snap.perf_rob_full_cycles),
      snap.perf_issue_full_cycles, pct(snap.perf_issue_full_cycles),
      snap.perf_sb_full_cycles, pct(snap.perf_sb_full_cycles),
      snap.perf_icache_miss_cycles, pct(snap.perf_icache_miss_cycles),
      snap.perf_dcache_miss_cycles, pct(snap.perf_dcache_miss_cycles),
      snap.perf_flush_cycles, pct(snap.perf_flush_cycles));
  spdlog::info(
      "issueq full (per-fu) alu={}({:.1f}%) bru={}({:.1f}%) "
      "lsu={}({:.1f}%) csr={}({:.1f}%)",
      snap.perf_alu_full_cycles, pct(snap.perf_alu_full_cycles),
      snap.perf_bru_full_cycles, pct(snap.perf_bru_full_cycles),
      snap.perf_lsu_full_cycles, pct(snap.perf_lsu_full_cycles),
      snap.perf_csr_full_cycles, pct(snap.perf_csr_full_cycles));
  spdlog::info(
      "miss reqs icache={} dcache={} miss_bp_cycles icache={}({:.1f}%) "
      "dcache={}({:.1f}%)",
      snap.perf_icache_miss_reqs, snap.perf_dcache_miss_reqs,
      snap.perf_icache_miss_cycles, pct(snap.perf_icache_miss_cycles),
      snap.perf_dcache_miss_cycles, pct(snap.perf_dcache_miss_cycles));
  spdlog::info(
      "ifu state cycles start={}({:.1f}%) wait_icache={}({:.1f}%) "
      "wait_ibuf={}({:.1f}%)",
      snap.perf_ifu_start_cycles, pct(snap.perf_ifu_start_cycles),
      snap.perf_ifu_wait_icache_cycles,
      pct(snap.perf_ifu_wait_icache_cycles),
      snap.perf_ifu_wait_ibuf_cycles, pct(snap.perf_ifu_wait_ibuf_cycles));
  spdlog::info(
      "icache req stall total={}({:.1f}%) not_ready={}({:.1f}%) "
      "respq_full={}({:.1f}%)",
      snap.perf_ic_stall_cycles, pct(snap.perf_ic_stall_cycles),
      snap.perf_ic_stall_noready_cycles, pct(snap.perf_ic_stall_noready_cycles),
      snap.perf_ic_stall_respq_cycles, pct(snap.perf_ic_stall_respq_cycles));
  spdlog::info(
      "icache state cycles idle={}({:.1f}%) lookup={}({:.1f}%) "
      "miss_req={}({:.1f}%) wait_refill={}({:.1f}%)",
      snap.perf_icache_idle_cycles, pct(snap.perf_icache_idle_cycles),
      snap.perf_icache_lookup_cycles, pct(snap.perf_icache_lookup_cycles),
      snap.perf_icache_miss_req_cycles,
      pct(snap.perf_icache_miss_req_cycles),
      snap.perf_icache_wait_refill_cycles,
      pct(snap.perf_icache_wait_refill_cycles));
  spdlog::info(
      "lsu state cycles idle={}({:.1f}%) ld_req={}({:.1f}%) "
      "ld_rsp={}({:.1f}%) resp={}({:.1f}%)",
      snap.perf_lsu_idle_cycles, pct(snap.perf_lsu_idle_cycles),
      snap.perf_lsu_ld_req_cycles, pct(snap.perf_lsu_ld_req_cycles),
      snap.perf_lsu_ld_rsp_cycles, pct(snap.perf_lsu_ld_rsp_cycles),
      snap.perf_lsu_resp_cycles, pct(snap.perf_lsu_resp_cycles));
  spdlog::info(
      "dcache state cycles idle={}({:.1f}%) lookup={}({:.1f}%) "
      "store_write={}({:.1f}%) wb_req={}({:.1f}%) miss_req={}({:.1f}%) "
      "wait_refill={}({:.1f}%) resp={}({:.1f}%)",
      snap.perf_dcache_idle_cycles, pct(snap.perf_dcache_idle_cycles),
      snap.perf_dcache_lookup_cycles, pct(snap.perf_dcache_lookup_cycles),
      snap.perf_dcache_store_write_cycles,
      pct(snap.perf_dcache_store_write_cycles),
      snap.perf_dcache_wb_req_cycles,
      pct(snap.perf_dcache_wb_req_cycles),
      snap.perf_dcache_miss_req_cycles,
      pct(snap.perf_dcache_miss_req_cycles),
      snap.perf_dcache_wait_refill_cycles,
      pct(snap.perf_dcache_wait_refill_cycles),
      snap.perf_dcache_resp_cycles, pct(snap.perf_dcache_resp_cycles));
}

void Logger::log_info(const std::string& msg) { spdlog::info("{}", msg); }

void Logger::log_warn(const std::string& msg) { spdlog::warn("{}", msg); }

bool Logger::needs_periodic_snapshot() {
  return g_config.stall_trace || g_config.progress_interval > 0;
}

void Logger::log_flush(uint64_t cycle, uint32_t redirect_pc) {
  spdlog::info("[flush ] cycle={} redirect_pc=0x{:x}", cycle, redirect_pc);
}

void Logger::log_bru(const Snapshot& snap) {
  spdlog::info(
      "[bru   ] cycle={} valid={} pc=0x{:x} imm=0x{:x} op={} is_jump={} "
      "is_branch={}",
      snap.cycles, static_cast<int>(snap.dbg_bru_valid), snap.dbg_bru_pc,
      snap.dbg_bru_imm, snap.dbg_bru_op, static_cast<int>(snap.dbg_bru_is_jump),
      static_cast<int>(snap.dbg_bru_is_branch));
}

void Logger::log_fe_mismatch(const Snapshot& snap) {
  std::string fe_str = fmt::format(
      "0x{:x},0x{:x},0x{:x},0x{:x}", snap.dbg_fe_instrs[0],
      snap.dbg_fe_instrs[1], snap.dbg_fe_instrs[2], snap.dbg_fe_instrs[3]);
  std::string mem_str = fmt::format(
      "0x{:x},0x{:x},0x{:x},0x{:x}", snap.mem_fe_instrs[0],
      snap.mem_fe_instrs[1], snap.mem_fe_instrs[2], snap.mem_fe_instrs[3]);
  spdlog::info(
      "[fe   ] cycle={} pc=0x{:x} mismatch=0x{:x} fe={{{}}} mem={{{}}}",
      snap.cycles, snap.dbg_fe_pc, snap.fe_mismatch_mask, fe_str, mem_str);
}

void Logger::maybe_log_flush(const Snapshot& snap) {
  if (!snap.backend_flush) return;
  if (!(g_config.commit_trace || g_config.bru_trace)) return;
  log_flush(snap.cycles, snap.backend_redirect_pc);
}

void Logger::maybe_log_bru(const Snapshot& snap) {
  if (!g_config.bru_trace) return;
  if (!snap.backend_flush || !snap.dbg_bru_mispred) return;
  log_bru(snap);
}

void Logger::maybe_log_fe_mismatch(
    const Snapshot& snap, const std::function<uint32_t(uint32_t)>& read_word) {
  if (!g_config.fe_trace) return;
  if (!snap.dbg_fe_valid || !snap.dbg_fe_ready) return;
  std::array<uint32_t, 4> mem_instrs{};
  uint32_t mismatch_mask = 0;
  for (int i = 0; i < 4; i++) {
    uint32_t addr = snap.dbg_fe_pc + static_cast<uint32_t>(i * 4);
    mem_instrs[i] = read_word(addr);
    if (snap.dbg_fe_instrs[i] != mem_instrs[i]) {
      mismatch_mask |= (1u << i);
    }
  }
  if (mismatch_mask == 0) return;
  Snapshot fe_snap = snap;
  fe_snap.mem_fe_instrs = mem_instrs;
  fe_snap.fe_mismatch_mask = mismatch_mask;
  log_fe_mismatch(fe_snap);
}

void Logger::maybe_log_stall(const Snapshot& snap) {
  if (!g_config.stall_trace) return;
  if (g_config.stall_threshold == 0) return;
  if (snap.no_commit_cycles < g_config.stall_threshold) return;
  if (snap.no_commit_cycles != g_config.stall_threshold &&
      (snap.no_commit_cycles % g_config.stall_threshold) != 0) {
    return;
  }
  log_stall(snap);
}

void Logger::maybe_log_progress(const Snapshot& snap) {
  if (g_config.progress_interval == 0) return;
  if (snap.cycles == 0) return;
  if ((snap.cycles % g_config.progress_interval) != 0) return;
  log_progress(snap);
}

std::string Logger::format_stall(const Snapshot& snap) {
  fmt::memory_buffer buf;
  fmt::format_to(
      std::back_inserter(buf),
      "[stall ] cycle={} no_commit={} fe(v/r/pc)={}/{}/0x{:x} dec(v/r)={}/{} "
      "rob_ready={} lsu_ld(v/r/addr)={}/{}/0x{:x} lsu_rsp(v/r)={}/{}",
      snap.cycles, snap.no_commit_cycles, static_cast<int>(snap.dbg_fe_valid),
      static_cast<int>(snap.dbg_fe_ready), snap.dbg_fe_pc,
      static_cast<int>(snap.dbg_dec_valid),
      static_cast<int>(snap.dbg_dec_ready),
      static_cast<int>(snap.dbg_rob_ready),
      static_cast<int>(snap.dbg_lsu_ld_req_valid),
      static_cast<int>(snap.dbg_lsu_ld_req_ready), snap.dbg_lsu_ld_req_addr,
      static_cast<int>(snap.dbg_lsu_ld_rsp_valid),
      static_cast<int>(snap.dbg_lsu_ld_rsp_ready));
  append_lsu_rs_state(buf, snap);
  fmt::format_to(
      std::back_inserter(buf),
      " sb_alloc(req/ready/fire)=0x{:x}/{}/{} sb_dcache(v/r/addr)={}/{}/0x{:x} "
      "ic_miss(v/r)={}/{} dc_miss(v/r)={}/{} flush={} rdir=0x{:x} "
      "rob_head(fu/comp/is_store/pc)=0x{:x}/{}/{}/0x{:x}",
      snap.dbg_sb_alloc_req, static_cast<int>(snap.dbg_sb_alloc_ready),
      static_cast<int>(snap.dbg_sb_alloc_fire),
      static_cast<int>(snap.dbg_sb_dcache_req_valid),
      static_cast<int>(snap.dbg_sb_dcache_req_ready),
      snap.dbg_sb_dcache_req_addr, static_cast<int>(snap.icache_miss_req_valid),
      static_cast<int>(snap.icache_miss_req_ready),
      static_cast<int>(snap.dcache_miss_req_valid),
      static_cast<int>(snap.dcache_miss_req_ready),
      static_cast<int>(snap.backend_flush), snap.backend_redirect_pc,
      snap.dbg_rob_head_fu, static_cast<int>(snap.dbg_rob_head_complete),
      static_cast<int>(snap.dbg_rob_head_is_store), snap.dbg_rob_head_pc);
  append_rob_sb_state(buf, snap);
  return fmt::to_string(buf);
}

std::string Logger::format_progress(const Snapshot& snap) {
  fmt::memory_buffer buf;
  fmt::format_to(
      std::back_inserter(buf),
      "[progress] cycle={} commits={} no_commit={} last_pc=0x{:x} "
      "last_inst=0x{:x} "
      "a0=0x{:x} rob_head(pc/comp/is_store/fu)=0x{:x}/{}/{}"
      "/0x{:x}",
      snap.cycles, snap.total_commits, snap.no_commit_cycles,
      snap.last_commit_pc, snap.last_commit_inst, snap.a0, snap.dbg_rob_head_pc,
      static_cast<int>(snap.dbg_rob_head_complete),
      static_cast<int>(snap.dbg_rob_head_is_store), snap.dbg_rob_head_fu);
  append_rob_sb_state(buf, snap);
  fmt::format_to(
      std::back_inserter(buf),
      " sb_dcache(v/r/addr)= {}/{}/0x{:x} lsu_issue(v/r)={}/{} "
      "lsu_issue_ready={} "
      "lsu_free={}",
      static_cast<int>(snap.dbg_sb_dcache_req_valid),
      static_cast<int>(snap.dbg_sb_dcache_req_ready),
      snap.dbg_sb_dcache_req_addr, static_cast<int>(snap.dbg_lsu_issue_valid),
      static_cast<int>(snap.dbg_lsu_req_ready),
      static_cast<int>(snap.dbg_lsu_issue_ready), snap.dbg_lsu_free_count);
  append_lsu_rs_state(buf, snap);
  fmt::format_to(std::back_inserter(buf),
                 " lsu_ld(v/r/rsp)={}/{}/{} flush={} dc_miss(v/r)={}/{}",
                 static_cast<int>(snap.dbg_lsu_ld_req_valid),
                 static_cast<int>(snap.dbg_lsu_ld_req_ready),
                 static_cast<int>(snap.dbg_lsu_ld_rsp_valid),
                 static_cast<int>(snap.backend_flush),
                 static_cast<int>(snap.dcache_miss_req_valid),
                 static_cast<int>(snap.dcache_miss_req_ready));
  return fmt::to_string(buf);
}
