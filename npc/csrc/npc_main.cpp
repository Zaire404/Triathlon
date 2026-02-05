#include <fmt/format.h>

#include <array>
#include <cstdint>
#include <cstdlib>
#include <fstream>
#include <iostream>
#include <sstream>
#include <string>
#include <unordered_map>
#include <vector>

#include "Vtb_triathlon.h"
#include "logger/logger.h"
#include "logger/snapshot.h"
#include "verilated.h"
#include "verilated_vcd_c.h"

namespace {

constexpr uint32_t kPmemBase = 0x80000000u;
constexpr uint32_t kEbreakInsn = 0x00100073u;
constexpr uint32_t kSerialPort = 0xA00003F8u;

struct SimArgs {
  std::string img_path;
  uint64_t max_cycles = 2000000;
  bool trace = false;
  std::string trace_path = "npc.vcd";
  bool commit_trace = false;
  bool fe_trace = false;
  bool bru_trace = false;
  bool stall_trace = false;
  uint64_t stall_threshold = 200;
  uint64_t progress_interval = 0;
};

static bool parse_u64(const std::string& s, uint64_t& out) {
  try {
    size_t idx = 0;
    out = std::stoull(s, &idx, 0);
    return idx == s.size();
  } catch (...) {
    return false;
  }
}

static SimArgs parse_args(int argc, char** argv) {
  SimArgs args;
  for (int i = 1; i < argc; i++) {
    std::string arg = argv[i];

    if (arg == "-d") {
      if (i + 1 < argc) i++;
      continue;
    }
    if (arg == "--max-cycles" && i + 1 < argc) {
      uint64_t v = 0;
      if (parse_u64(argv[i + 1], v)) {
        args.max_cycles = v;
        i++;
        continue;
      }
    }
    if (arg.rfind("--max-cycles=", 0) == 0) {
      uint64_t v = 0;
      if (parse_u64(arg.substr(std::string("--max-cycles=").size()), v)) {
        args.max_cycles = v;
      }
      continue;
    }
    if (arg == "--trace") {
      args.trace = true;
      if (i + 1 < argc && argv[i + 1][0] != '-') {
        args.trace_path = argv[i + 1];
        i++;
      }
      continue;
    }
    if (arg.rfind("--trace=", 0) == 0) {
      args.trace = true;
      args.trace_path = arg.substr(std::string("--trace=").size());
      continue;
    }
    if (arg == "--commit-trace") {
      args.commit_trace = true;
      continue;
    }
    if (arg == "--fe-trace") {
      args.fe_trace = true;
      continue;
    }
    if (arg == "--bru-trace") {
      args.bru_trace = true;
      continue;
    }
    if (arg == "--stall-trace") {
      args.stall_trace = true;
      if (i + 1 < argc) {
        uint64_t v = 0;
        if (parse_u64(argv[i + 1], v)) {
          args.stall_threshold = v;
          i++;
        }
      }
      continue;
    }
    if (arg.rfind("--stall-trace=", 0) == 0) {
      args.stall_trace = true;
      uint64_t v = 0;
      if (parse_u64(arg.substr(std::string("--stall-trace=").size()), v)) {
        args.stall_threshold = v;
      }
      continue;
    }
    if (arg == "--progress") {
      args.progress_interval = 1000000;
      if (i + 1 < argc && argv[i + 1][0] != '-') {
        uint64_t v = 0;
        if (parse_u64(argv[i + 1], v)) {
          args.progress_interval = v;
          i++;
        }
      }
      continue;
    }
    if (arg.rfind("--progress=", 0) == 0) {
      uint64_t v = 0;
      if (parse_u64(arg.substr(std::string("--progress=").size()), v)) {
        args.progress_interval = v;
      }
      continue;
    }
    if (!arg.empty() && arg[0] == '-') {
      continue;
    }
    args.img_path = arg;
  }
  return args;
}

struct UnifiedMem {
  std::unordered_map<uint32_t, uint32_t> words;

  void write_word(uint32_t addr, uint32_t data) { words[addr & ~0x3u] = data; }

  uint32_t read_word(uint32_t addr) const {
    auto it = words.find(addr & ~0x3u);
    if (it == words.end()) return 0u;
    return it->second;
  }

  void fill_line(uint32_t line_addr, std::array<uint32_t, 8>& line) const {
    for (int i = 0; i < 8; i++) {
      line[i] = read_word(line_addr + 4u * static_cast<uint32_t>(i));
    }
  }

  void write_line(uint32_t line_addr, const std::array<uint32_t, 8>& line) {
    for (int i = 0; i < 8; i++) {
      write_word(line_addr + 4u * static_cast<uint32_t>(i), line[i]);
    }
  }

  bool load_binary(const std::string& path, uint32_t base) {
    std::ifstream ifs(path, std::ios::binary);
    if (!ifs) {
      std::cerr << "Failed to open IMG: " << path << "\n";
      return false;
    }
    std::vector<uint8_t> buf((std::istreambuf_iterator<char>(ifs)),
                             std::istreambuf_iterator<char>());
    for (size_t i = 0; i < buf.size(); i += 4) {
      uint32_t word = 0;
      for (size_t b = 0; b < 4; b++) {
        if (i + b < buf.size()) {
          word |= static_cast<uint32_t>(buf[i + b]) << (8 * b);
        }
      }
      write_word(base + static_cast<uint32_t>(i), word);
    }
    return true;
  }
};

struct ICacheModel {
  bool pending = false;
  int delay = 0;
  uint32_t miss_addr = 0;
  uint32_t miss_way = 0;
  bool refill_pulse = false;
  std::array<uint32_t, 8> line_words{};
  UnifiedMem* mem = nullptr;

  void reset() {
    pending = false;
    delay = 0;
    miss_addr = 0;
    miss_way = 0;
    refill_pulse = false;
  }

  void drive(Vtb_triathlon* top) {
    top->icache_miss_req_ready_i = 1;
    if (refill_pulse) {
      top->icache_refill_valid_i = 1;
      top->icache_refill_paddr_i = miss_addr;
      top->icache_refill_way_i = miss_way;
      for (int i = 0; i < 8; i++) top->icache_refill_data_i[i] = line_words[i];
    } else {
      top->icache_refill_valid_i = 0;
      top->icache_refill_paddr_i = 0;
      top->icache_refill_way_i = 0;
      for (int i = 0; i < 8; i++) top->icache_refill_data_i[i] = 0;
    }
  }

  void observe(Vtb_triathlon* top) {
    if (!top->rst_ni) {
      reset();
      return;
    }

    if (refill_pulse) {
      refill_pulse = false;
    }

    if (!pending && top->icache_miss_req_valid_o) {
      pending = true;
      delay = 2;
      miss_addr = top->icache_miss_req_paddr_o;
      miss_way = top->icache_miss_req_victim_way_o;
      if (mem) mem->fill_line(miss_addr, line_words);
    }

    if (pending) {
      if (delay > 0) {
        delay--;
      } else if (top->icache_refill_ready_o) {
        refill_pulse = true;
        pending = false;
      }
    }
  }
};

struct DCacheModel {
  bool pending = false;
  int delay = 0;
  uint32_t miss_addr = 0;
  uint32_t miss_way = 0;
  bool refill_pulse = false;
  std::array<uint32_t, 8> line_words{};
  UnifiedMem* mem = nullptr;

  void reset() {
    pending = false;
    delay = 0;
    miss_addr = 0;
    miss_way = 0;
    refill_pulse = false;
  }

  void drive(Vtb_triathlon* top) {
    top->dcache_miss_req_ready_i = 1;
    top->dcache_wb_req_ready_i = 1;
    if (refill_pulse) {
      top->dcache_refill_valid_i = 1;
      top->dcache_refill_paddr_i = miss_addr;
      top->dcache_refill_way_i = miss_way;
      for (int i = 0; i < 8; i++) top->dcache_refill_data_i[i] = line_words[i];
    } else {
      top->dcache_refill_valid_i = 0;
      top->dcache_refill_paddr_i = 0;
      top->dcache_refill_way_i = 0;
      for (int i = 0; i < 8; i++) top->dcache_refill_data_i[i] = 0;
    }
  }

  void observe(Vtb_triathlon* top) {
    if (!top->rst_ni) {
      reset();
      return;
    }

    if (refill_pulse) {
      refill_pulse = false;
    }

    if (!pending && top->dcache_miss_req_valid_o) {
      pending = true;
      delay = 2;
      miss_addr = top->dcache_miss_req_paddr_o;
      miss_way = top->dcache_miss_req_victim_way_o;
      if (mem) mem->fill_line(miss_addr, line_words);
    }

    if (pending) {
      if (delay > 0) {
        delay--;
      } else if (top->dcache_refill_ready_o) {
        refill_pulse = true;
        pending = false;
      }
    }

    if (top->dcache_wb_req_valid_o && top->dcache_wb_req_ready_i) {
      std::array<uint32_t, 8> wb_line{};
      for (int i = 0; i < 8; i++) wb_line[i] = top->dcache_wb_req_data_o[i];
      if (mem) mem->write_line(top->dcache_wb_req_paddr_o, wb_line);
    }
  }
};

struct MemSystem {
  UnifiedMem mem;
  ICacheModel icache;
  DCacheModel dcache;

  void reset() {
    icache.reset();
    dcache.reset();
  }

  void drive(Vtb_triathlon* top) {
    icache.drive(top);
    dcache.drive(top);
  }

  void observe(Vtb_triathlon* top) {
    icache.observe(top);
    dcache.observe(top);
  }
};

static void tick(Vtb_triathlon* top, MemSystem& mem, VerilatedVcdC* tfp,
                 vluint64_t& sim_time) {
  mem.drive(top);
  top->clk_i = 0;
  top->eval();
  if (tfp) tfp->dump(sim_time++);
  top->clk_i = 1;
  top->eval();
  if (tfp) tfp->dump(sim_time++);
  mem.observe(top);
}

static void reset(Vtb_triathlon* top, MemSystem& mem, VerilatedVcdC* tfp,
                  vluint64_t& sim_time) {
  top->rst_ni = 0;
  mem.reset();
  for (int i = 0; i < 5; i++) tick(top, mem, tfp, sim_time);
  top->rst_ni = 1;
  for (int i = 0; i < 2; i++) tick(top, mem, tfp, sim_time);
}

}  // namespace

int main(int argc, char** argv) {
  Verilated::commandArgs(argc, argv);
  SimArgs args = parse_args(argc, argv);

  if (args.img_path.empty()) {
    std::cerr << "Usage: " << argv[0]
              << " <IMG> [--max-cycles N] [--trace [vcd]] [--commit-trace]"
              << " [--bru-trace] [--fe-trace] [--stall-trace [N]]"
              << " [--progress [N]]\n";
    return 1;
  }

  LogConfig log_config{};
  log_config.commit_trace = args.commit_trace;
  log_config.fe_trace = args.fe_trace;
  log_config.bru_trace = args.bru_trace;
  log_config.stall_trace = args.stall_trace;
  log_config.stall_threshold = args.stall_threshold;
  log_config.progress_interval = args.progress_interval;
  Logger::init(log_config);

  MemSystem mem;
  if (!mem.mem.load_binary(args.img_path, kPmemBase)) return 1;
  mem.icache.mem = &mem.mem;
  mem.dcache.mem = &mem.mem;

  auto* top = new Vtb_triathlon;
  VerilatedVcdC* tfp = nullptr;
  vluint64_t sim_time = 0;

  if (args.trace) {
    Verilated::traceEverOn(true);
    tfp = new VerilatedVcdC;
    top->trace(tfp, 99);
    tfp->open(args.trace_path.c_str());
  }

  reset(top, mem, tfp, sim_time);

  std::array<uint32_t, 32> rf{};
  uint64_t no_commit_cycles = 0;
  uint64_t total_commits = 0;
  uint32_t last_commit_pc = 0;
  uint32_t last_commit_inst = 0;
  for (uint64_t cycles = 0; cycles < args.max_cycles; cycles++) {
    tick(top, mem, tfp, sim_time);

    if (top->dbg_sb_dcache_req_valid_o && top->dbg_sb_dcache_req_ready_o) {
      uint32_t addr = top->dbg_sb_dcache_req_addr_o;
      if (addr == kSerialPort) {
        uint8_t ch =
            static_cast<uint8_t>(top->dbg_sb_dcache_req_data_o & 0xFFu);
        std::cout << static_cast<char>(ch) << std::flush;
      }
    }

    bool need_flush_bru_log = top->backend_flush_o || top->dbg_bru_mispred_o;
    bool need_periodic_log = Logger::needs_periodic_snapshot();
    bool need_fe_mismatch_log =
        Logger::config().fe_trace && top->dbg_fe_valid_o && top->dbg_fe_ready_o;

    bool any_commit = false;
    for (int i = 0; i < 4; i++) {
      bool valid = (top->commit_valid_o >> i) & 0x1;
      if (!valid) continue;
      any_commit = true;
      total_commits++;

      bool we = (top->commit_we_o >> i) & 0x1;
      uint32_t rd = (top->commit_areg_o >> (i * 5)) & 0x1F;
      uint32_t data = top->commit_wdata_o[i];
      if (we && rd != 0) {
        rf[rd] = data;
      }

      uint32_t pc = top->commit_pc_o[i];
      uint32_t inst = mem.mem.read_word(pc);
      last_commit_pc = pc;
      last_commit_inst = inst;
      Logger::log_commit(cycles, i, pc, inst, we, rd, data, rf[10]);
      if (inst == kEbreakInsn) {
        uint32_t code = rf[10];
        if (code == 0) {
          Logger::log_info("HIT GOOD TRAP");
          Snapshot snap =
              collect_snapshot(top, cycles, total_commits, no_commit_cycles,
                               last_commit_pc, last_commit_inst, rf[10]);
          double ipc = cycles ? static_cast<double>(total_commits) /
                                    static_cast<double>(cycles)
                              : 0.0;
          double cpi = total_commits ? static_cast<double>(cycles) /
                                           static_cast<double>(total_commits)
                                     : 0.0;
          Logger::log_perf(snap, ipc, cpi);
          if (tfp) tfp->close();
          delete top;
          Logger::shutdown();
          return 0;
        }
        Logger::log_warn(fmt::format("HIT BAD TRAP (code={})", code));
        if (tfp) tfp->close();
        delete top;
        Logger::shutdown();
        return 1;
      }
    }

    if (any_commit) {
      no_commit_cycles = 0;
    } else {
      no_commit_cycles++;
    }

    if (need_flush_bru_log || need_periodic_log || need_fe_mismatch_log) {
      Snapshot snap =
          collect_snapshot(top, cycles, total_commits, no_commit_cycles,
                           last_commit_pc, last_commit_inst, rf[10]);

      if (need_flush_bru_log) {
        Logger::maybe_log_flush(snap);
        Logger::maybe_log_bru(snap);
      }

      if (need_periodic_log) {
        Logger::maybe_log_stall(snap);
        Logger::maybe_log_progress(snap);
      }

      if (need_fe_mismatch_log) {
        Logger::maybe_log_fe_mismatch(
            snap, [&](uint32_t addr) { return mem.mem.read_word(addr); });
      }
    }
  }

  Logger::log_warn(fmt::format("TIMEOUT after {} cycles", args.max_cycles));

  if (tfp) tfp->close();
  delete top;
  Logger::shutdown();
  return 1;
}
