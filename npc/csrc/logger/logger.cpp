#include "logger/logger.h"

#include <iomanip>
#include <sstream>

#include <spdlog/sinks/stdout_color_sinks.h>
#include <spdlog/spdlog.h>

namespace {
LogConfig g_config{};

void append_lsu_rs_state(std::ostringstream &oss, const Snapshot &snap) {
  oss << " lsu_rs(b/r)=0x" << std::hex << snap.dbg_lsu_rs_busy
      << "/0x" << snap.dbg_lsu_rs_ready
      << " lsu_rs_head(v/idx/dst)=" << std::dec
      << static_cast<int>(snap.dbg_lsu_rs_head_valid) << "/0x" << std::hex
      << snap.dbg_lsu_rs_head_idx << "/0x" << snap.dbg_lsu_rs_head_dst
      << " lsu_rs_head(rs1r/rs2r/has1/has2)=" << std::dec
      << static_cast<int>(snap.dbg_lsu_rs_head_r1_ready) << "/"
      << static_cast<int>(snap.dbg_lsu_rs_head_r2_ready) << "/"
      << static_cast<int>(snap.dbg_lsu_rs_head_has_rs1) << "/"
      << static_cast<int>(snap.dbg_lsu_rs_head_has_rs2)
      << " lsu_rs_head(q1/q2/sb)=0x" << std::hex
      << snap.dbg_lsu_rs_head_q1 << "/0x" << snap.dbg_lsu_rs_head_q2
      << "/0x" << snap.dbg_lsu_rs_head_sb_id
      << " lsu_rs_head(ld/st)=" << std::dec
      << static_cast<int>(snap.dbg_lsu_rs_head_is_load) << "/"
      << static_cast<int>(snap.dbg_lsu_rs_head_is_store);
}

void append_rob_sb_state(std::ostringstream &oss, const Snapshot &snap) {
  oss << " rob_cnt=" << std::dec << snap.dbg_rob_count
      << " rob_ptr(h/t)=0x" << std::hex << snap.dbg_rob_head_ptr
      << "/0x" << snap.dbg_rob_tail_ptr
      << std::dec
      << " rob_q2(v/idx/fu/comp/st/pc)=" << std::dec
      << static_cast<int>(snap.dbg_rob_q2_valid) << "/0x" << std::hex
      << snap.dbg_rob_q2_idx << "/0x" << snap.dbg_rob_q2_fu
      << std::dec << "/" << static_cast<int>(snap.dbg_rob_q2_complete)
      << "/" << static_cast<int>(snap.dbg_rob_q2_is_store)
      << "/0x" << std::hex << snap.dbg_rob_q2_pc
      << " sb(cnt/h/t)=0x" << std::hex << snap.dbg_sb_count
      << "/0x" << snap.dbg_sb_head_ptr
      << "/0x" << snap.dbg_sb_tail_ptr
      << std::dec
      << " sb_head(v/c/a/d/addr)=" << static_cast<int>(snap.dbg_sb_head_valid)
      << "/" << static_cast<int>(snap.dbg_sb_head_committed) << "/"
      << static_cast<int>(snap.dbg_sb_head_addr_valid) << "/"
      << static_cast<int>(snap.dbg_sb_head_data_valid) << "/0x" << std::hex
      << snap.dbg_sb_head_addr;
}
}

void Logger::init(const LogConfig &config) {
  g_config = config;
  if (!spdlog::get("npc")) {
    auto logger = spdlog::stdout_color_mt("npc");
    spdlog::set_default_logger(logger);
  }
  spdlog::set_pattern("%v");
}

void Logger::shutdown() { spdlog::shutdown(); }

const LogConfig &Logger::config() { return g_config; }

void Logger::log_commit(uint64_t cycle,
                        uint32_t slot,
                        uint32_t pc,
                        uint32_t inst,
                        bool we,
                        uint32_t rd,
                        uint32_t data,
                        uint32_t a0) {
  if (!g_config.commit_trace) return;
  std::ostringstream oss;
  oss << "[commit] cycle=" << cycle << " slot=" << slot
      << " pc=0x" << std::hex << pc
      << " inst=0x" << inst
      << " we=" << std::dec << we
      << " rd=x" << rd
      << " data=0x" << std::hex << data
      << " a0=0x" << a0;
  spdlog::info("{}", oss.str());
}

void Logger::log_stall(const Snapshot &snap) {
  if (!g_config.stall_trace) return;
  spdlog::info("{}", format_stall(snap));
}

void Logger::log_progress(const Snapshot &snap) {
  if (g_config.progress_interval == 0) return;
  spdlog::info("{}", format_progress(snap));
}

void Logger::log_perf(const Snapshot &snap, double ipc, double cpi) {
  std::ostringstream oss;
  oss << "IPC=" << ipc << " CPI=" << cpi
      << " cycles=" << snap.cycles
      << " commits=" << snap.total_commits;
  spdlog::info("{}", oss.str());
}

void Logger::log_info(const std::string &msg) { spdlog::info("{}", msg); }

void Logger::log_warn(const std::string &msg) { spdlog::warn("{}", msg); }

std::string Logger::format_stall(const Snapshot &snap) {
  std::ostringstream oss;
  oss << "[stall ] cycle=" << snap.cycles
      << " no_commit=" << snap.no_commit_cycles
      << " fe(v/r/pc)=" << static_cast<int>(snap.dbg_fe_valid) << "/"
      << static_cast<int>(snap.dbg_fe_ready) << "/0x" << std::hex
      << snap.dbg_fe_pc
      << " dec(v/r)=" << std::dec << static_cast<int>(snap.dbg_dec_valid) << "/"
      << static_cast<int>(snap.dbg_dec_ready)
      << " rob_ready=" << static_cast<int>(snap.dbg_rob_ready)
      << " lsu_ld(v/r/addr)=" << static_cast<int>(snap.dbg_lsu_ld_req_valid)
      << "/" << static_cast<int>(snap.dbg_lsu_ld_req_ready) << "/0x" << std::hex
      << snap.dbg_lsu_ld_req_addr
      << " lsu_rsp(v/r)=" << std::dec << static_cast<int>(snap.dbg_lsu_ld_rsp_valid)
      << "/" << static_cast<int>(snap.dbg_lsu_ld_rsp_ready);
  append_lsu_rs_state(oss, snap);
  oss << " sb_alloc(req/ready/fire)=0x" << std::hex << snap.dbg_sb_alloc_req
      << std::dec << "/" << static_cast<int>(snap.dbg_sb_alloc_ready) << "/"
      << static_cast<int>(snap.dbg_sb_alloc_fire)
      << " sb_dcache(v/r/addr)=" << static_cast<int>(snap.dbg_sb_dcache_req_valid)
      << "/" << static_cast<int>(snap.dbg_sb_dcache_req_ready) << "/0x" << std::hex
      << snap.dbg_sb_dcache_req_addr
      << " ic_miss(v/r)=" << std::dec << static_cast<int>(snap.icache_miss_req_valid)
      << "/" << static_cast<int>(snap.icache_miss_req_ready)
      << " dc_miss(v/r)=" << static_cast<int>(snap.dcache_miss_req_valid)
      << "/" << static_cast<int>(snap.dcache_miss_req_ready)
      << " flush=" << static_cast<int>(snap.backend_flush)
      << " rdir=0x" << std::hex << snap.backend_redirect_pc
      << std::dec
      << " rob_head(fu/comp/is_store/pc)=0x" << std::hex << snap.dbg_rob_head_fu
      << "/" << static_cast<int>(snap.dbg_rob_head_complete)
      << "/" << static_cast<int>(snap.dbg_rob_head_is_store)
      << "/0x" << snap.dbg_rob_head_pc;
  append_rob_sb_state(oss, snap);
  return oss.str();
}

std::string Logger::format_progress(const Snapshot &snap) {
  std::ostringstream oss;
  oss << "[progress] cycle=" << snap.cycles
      << " commits=" << snap.total_commits
      << " no_commit=" << snap.no_commit_cycles
      << " last_pc=0x" << std::hex << snap.last_commit_pc
      << " last_inst=0x" << snap.last_commit_inst
      << " a0=0x" << snap.a0
      << " rob_head(pc/comp/is_store/fu)=0x" << snap.dbg_rob_head_pc
      << "/" << std::dec << static_cast<int>(snap.dbg_rob_head_complete)
      << "/" << static_cast<int>(snap.dbg_rob_head_is_store) << "/0x" << std::hex
      << snap.dbg_rob_head_fu;
  append_rob_sb_state(oss, snap);
  oss << " sb_dcache(v/r/addr)= " << std::dec
      << static_cast<int>(snap.dbg_sb_dcache_req_valid) << "/"
      << static_cast<int>(snap.dbg_sb_dcache_req_ready) << "/0x" << std::hex
      << snap.dbg_sb_dcache_req_addr
      << " lsu_issue(v/r)=" << std::dec << static_cast<int>(snap.dbg_lsu_issue_valid)
      << "/" << static_cast<int>(snap.dbg_lsu_req_ready)
      << " lsu_issue_ready=" << static_cast<int>(snap.dbg_lsu_issue_ready)
      << " lsu_free=" << snap.dbg_lsu_free_count;
  append_lsu_rs_state(oss, snap);
  oss << " lsu_ld(v/r/rsp)=" << std::dec
      << static_cast<int>(snap.dbg_lsu_ld_req_valid) << "/"
      << static_cast<int>(snap.dbg_lsu_ld_req_ready) << "/"
      << static_cast<int>(snap.dbg_lsu_ld_rsp_valid)
      << " flush=" << static_cast<int>(snap.backend_flush)
      << " dc_miss(v/r)=" << static_cast<int>(snap.dcache_miss_req_valid)
      << "/" << static_cast<int>(snap.dcache_miss_req_ready);
  return oss.str();
}
