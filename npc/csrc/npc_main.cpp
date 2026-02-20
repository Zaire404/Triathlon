#include "Vtb_triathlon.h"
#include "verilated.h"
#include "verilated_vcd_c.h"

#include <algorithm>
#include <array>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <deque>
#include <dlfcn.h>
#include <fstream>
#include <iostream>
#include <string>
#include <unordered_map>
#include <vector>

namespace {

constexpr uint32_t kPmemBase = 0x80000000u;
constexpr uint32_t kEbreakInsn = 0x00100073u;
constexpr uint32_t kSerialPort = 0xA00003F8u;
constexpr uint32_t kRtcPortLow = 0xA0000048u;
constexpr uint32_t kRtcPortHigh = 0xA000004Cu;
constexpr uint32_t kPmemSize = 0x08000000u;
constexpr uint32_t kMmioBase = 0xA0000000u;
constexpr uint32_t kMmioEnd = 0xAFFFFFFFu;
constexpr uint32_t kSeed4Addr = 0x80003C3Cu;

struct SimArgs {
  std::string img_path;
  uint64_t max_cycles = 600000000;
  std::string difftest_so;
  bool trace = false;
  std::string trace_path = "npc.vcd";
  bool commit_trace = false;
  bool fe_trace = false;
  bool bru_trace = false;
  bool stall_trace = false;
  uint64_t stall_threshold = 200;
  uint64_t progress_interval = 0;
};

static bool parse_u64(const std::string &s, uint64_t &out) {
  try {
    size_t idx = 0;
    out = std::stoull(s, &idx, 0);
    return idx == s.size();
  } catch (...) {
    return false;
  }
}

static SimArgs parse_args(int argc, char **argv) {
  SimArgs args;
  for (int i = 1; i < argc; i++) {
    std::string arg = argv[i];

    if (arg == "-d") {
      if (i + 1 < argc) {
        args.difftest_so = argv[i + 1];
        i++;
      }
      continue;
    }
    if (arg.rfind("--difftest=", 0) == 0) {
      args.difftest_so = arg.substr(std::string("--difftest=").size());
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

struct DifftestCPUState {
  uint32_t gpr[16];
  uint32_t pc;
  struct {
    uint32_t mtvec;
    uint32_t mepc;
    uint32_t mstatus;
    uint32_t mcause;
  } csr;
};

struct DUTCSRState {
  uint32_t mtvec;
  uint32_t mepc;
  uint32_t mstatus;
  uint32_t mcause;
};

class Difftest {
 public:
  bool init(const std::string &so_path,
            const std::vector<uint32_t> &pmem_words,
            uint32_t entry_pc) {
    handle_ = dlopen(so_path.c_str(), RTLD_LAZY);
    if (!handle_) {
      std::cerr << "[difftest] dlopen failed: " << dlerror() << "\n";
      return false;
    }

    difftest_memcpy_ =
        reinterpret_cast<difftest_memcpy_t>(dlsym(handle_, "difftest_memcpy"));
    difftest_regcpy_ =
        reinterpret_cast<difftest_regcpy_t>(dlsym(handle_, "difftest_regcpy"));
    difftest_exec_ =
        reinterpret_cast<difftest_exec_t>(dlsym(handle_, "difftest_exec"));
    difftest_init_ =
        reinterpret_cast<difftest_init_t>(dlsym(handle_, "difftest_init"));

    if (!difftest_memcpy_ || !difftest_regcpy_ || !difftest_exec_ ||
        !difftest_init_) {
      std::cerr << "[difftest] dlsym failed: missing required symbols\n";
      return false;
    }

    difftest_init_(0);

    std::vector<uint8_t> pmem(kPmemSize, 0);
    size_t max_words = kPmemSize / sizeof(uint32_t);
    size_t word_cnt = pmem_words.size() < max_words ? pmem_words.size() : max_words;
    size_t copy_bytes = word_cnt * sizeof(uint32_t);
    if (copy_bytes > 0) {
      std::memcpy(pmem.data(), pmem_words.data(), copy_bytes);
    }
    difftest_memcpy_(kPmemBase, pmem.data(), pmem.size(), kToRef);

    DifftestCPUState boot = {};
    boot.pc = entry_pc;
    boot.csr.mstatus = 0x1800u;
    boot.csr.mtvec = 0x0u;
    boot.csr.mepc = 0x0u;
    boot.csr.mcause = 0x0u;
    difftest_regcpy_(&boot, kToRef);
    last_ref_state_ = boot;
    has_last_ref_state_ = true;

    enabled_ = true;
    std::cout << "[difftest] enabled, image bytes copied=" << pmem.size()
              << "\n";
    return true;
  }

  bool enabled() const { return enabled_; }

  bool step_and_check(uint64_t cycle, uint32_t pc, uint32_t inst,
                      const std::array<uint32_t, 32> &rf_before,
                      const std::array<uint32_t, 32> &rf_after) {
    if (!enabled_) return true;

    DifftestCPUState ref_before = {};
    difftest_regcpy_(&ref_before, kToDut);
    if (ref_before.pc != pc) {
      std::cerr << "[difftest] pc mismatch before exec at cycle " << cycle
                << " commit_pc=0x" << std::hex << pc << " ref_pc=0x"
                << ref_before.pc << std::dec << "\n";
      return false;
    }

    difftest_exec_(1);

    DifftestCPUState ref_after = {};
    difftest_regcpy_(&ref_after, kToDut);
    last_ref_state_ = ref_after;
    has_last_ref_state_ = true;

    uint32_t mmio_load_rd = 0;
    bool ignore_mmio_load_rd = decode_mmio_load_rd(inst, rf_before, mmio_load_rd);

    for (int reg = 0; reg < 16; reg++) {
      if (ignore_mmio_load_rd && reg == static_cast<int>(mmio_load_rd)) continue;
      if (ref_after.gpr[reg] != rf_after[reg]) {
        std::cerr << "[difftest] x" << reg << " mismatch at cycle " << cycle
                  << " pc=0x" << std::hex << pc << " inst=0x" << inst
                  << ": dut=0x" << rf_after[reg] << " ref=0x"
                  << ref_after.gpr[reg] << std::dec << "\n";
        return false;
      }
    }

    if (ignore_mmio_load_rd && mmio_load_rd != 0) {
      ref_after.gpr[mmio_load_rd] = rf_after[mmio_load_rd];
      difftest_regcpy_(&ref_after, kToRef);
      last_ref_state_ = ref_after;
    }

    return true;
  }

  bool check_arch_state(uint64_t cycle, const std::array<uint32_t, 32> &rf_after,
                        const DUTCSRState &dut_csr) {
    if (!enabled_ || !has_last_ref_state_) return true;

    for (int reg = 0; reg < 16; reg++) {
      if (last_ref_state_.gpr[reg] != rf_after[reg]) {
        std::cerr << "[difftest] x" << reg
                  << " mismatch at cycle-end " << cycle
                  << ": dut=0x" << std::hex << rf_after[reg]
                  << " ref=0x" << last_ref_state_.gpr[reg] << std::dec << "\n";
        return false;
      }
    }

    if (last_ref_state_.csr.mtvec != dut_csr.mtvec) {
      std::cerr << "[difftest] mtvec mismatch at cycle-end " << cycle
                << ": dut=0x" << std::hex << dut_csr.mtvec << " ref=0x"
                << last_ref_state_.csr.mtvec << std::dec << "\n";
      return false;
    }
    if (last_ref_state_.csr.mepc != dut_csr.mepc) {
      std::cerr << "[difftest] mepc mismatch at cycle-end " << cycle
                << ": dut=0x" << std::hex << dut_csr.mepc << " ref=0x"
                << last_ref_state_.csr.mepc << std::dec << "\n";
      return false;
    }
    if (last_ref_state_.csr.mstatus != dut_csr.mstatus) {
      std::cerr << "[difftest] mstatus mismatch at cycle-end " << cycle
                << ": dut=0x" << std::hex << dut_csr.mstatus << " ref=0x"
                << last_ref_state_.csr.mstatus << std::dec << "\n";
      return false;
    }
    if (last_ref_state_.csr.mcause != dut_csr.mcause) {
      std::cerr << "[difftest] mcause mismatch at cycle-end " << cycle
                << ": dut=0x" << std::hex << dut_csr.mcause << " ref=0x"
                << last_ref_state_.csr.mcause << std::dec << "\n";
      return false;
    }

    return true;
  }

  ~Difftest() {
    handle_ = nullptr;
  }

 private:
  using difftest_memcpy_t = void (*)(uint32_t, void *, size_t, bool);
  using difftest_regcpy_t = void (*)(void *, bool);
  using difftest_exec_t = void (*)(uint64_t);
  using difftest_init_t = void (*)(int);

  static constexpr bool kToDut = false;
  static constexpr bool kToRef = true;

  static int32_t sext12(uint32_t imm12) {
    return static_cast<int32_t>(imm12 << 20) >> 20;
  }

  static bool is_mmio_addr(uint32_t addr) {
    return addr >= kMmioBase && addr <= kMmioEnd;
  }

  static bool decode_mmio_load_rd(uint32_t inst,
                                  const std::array<uint32_t, 32> &rf_before,
                                  uint32_t &rd_out) {
    uint32_t opcode = inst & 0x7fu;
    if (opcode != 0x03u) return false;  // LOAD

    uint32_t rd = (inst >> 7) & 0x1fu;
    uint32_t rs1 = (inst >> 15) & 0x1fu;
    uint32_t imm12 = (inst >> 20) & 0xfffu;
    int32_t imm = sext12(imm12);

    if (rs1 >= rf_before.size()) return false;
    uint32_t addr = rf_before[rs1] + static_cast<uint32_t>(imm);
    if (!is_mmio_addr(addr)) return false;
    if (rd == 0 || rd >= 16) return false;

    rd_out = rd;
    return true;
  }

  void *handle_ = nullptr;
  difftest_memcpy_t difftest_memcpy_ = nullptr;
  difftest_regcpy_t difftest_regcpy_ = nullptr;
  difftest_exec_t difftest_exec_ = nullptr;
  difftest_init_t difftest_init_ = nullptr;

  DifftestCPUState last_ref_state_ = {};
  bool has_last_ref_state_ = false;
  bool enabled_ = false;
};

struct UnifiedMem {
  std::vector<uint32_t> pmem_words;
  uint64_t rtc_time_us = 0;

  UnifiedMem() : pmem_words(kPmemSize / sizeof(uint32_t), 0) {}

  static bool in_pmem(uint32_t addr) {
    return addr >= kPmemBase && addr < (kPmemBase + kPmemSize);
  }

  void set_time_us(uint64_t t) { rtc_time_us = t; }

  void write_word(uint32_t addr, uint32_t data) {
    uint32_t aligned = addr & ~0x3u;
    if (!in_pmem(aligned)) return;
    uint32_t idx = (aligned - kPmemBase) >> 2;
    if (idx < pmem_words.size()) {
      pmem_words[idx] = data;
    }
  }

  void write_byte(uint32_t addr, uint8_t data) {
    if (!in_pmem(addr)) return;
    uint32_t aligned = addr & ~0x3u;
    uint32_t shift = (addr & 0x3u) * 8u;
    uint32_t mask = 0xffu << shift;
    uint32_t cur = read_word(aligned);
    uint32_t next = (cur & ~mask) | (static_cast<uint32_t>(data) << shift);
    write_word(aligned, next);
  }

  void write_half(uint32_t addr, uint16_t data) {
    if (!in_pmem(addr) || !in_pmem(addr + 1u)) return;
    uint32_t aligned = addr & ~0x3u;
    uint32_t shift = (addr & 0x3u) * 8u;
    uint32_t mask = 0xffffu << shift;
    uint32_t cur = read_word(aligned);
    uint32_t next = (cur & ~mask) | (static_cast<uint32_t>(data) << shift);
    write_word(aligned, next);
  }

  void write_store(uint32_t addr, uint32_t data, uint32_t op) {
    switch (op) {
      case 7u:  // LSU_SB
        write_byte(addr, static_cast<uint8_t>(data & 0xffu));
        break;
      case 8u:  // LSU_SH
        write_half(addr, static_cast<uint16_t>(data & 0xffffu));
        break;
      case 9u:  // LSU_SW
        write_word(addr, data);
        break;
      default:
        break;
    }
  }

  uint32_t read_word(uint32_t addr) const {
    uint32_t aligned = addr & ~0x3u;
    if (aligned == kRtcPortLow) return static_cast<uint32_t>(rtc_time_us & 0xFFFFFFFFu);
    if (aligned == kRtcPortHigh) return static_cast<uint32_t>((rtc_time_us >> 32) & 0xFFFFFFFFu);
    if (!in_pmem(aligned)) return 0u;
    uint32_t idx = (aligned - kPmemBase) >> 2;
    if (idx < pmem_words.size()) {
      return pmem_words[idx];
    }
    return 0u;
  }

  void fill_line(uint32_t line_addr, std::array<uint32_t, 8> &line) const {
    for (int i = 0; i < 8; i++) {
      line[i] = read_word(line_addr + 4u * static_cast<uint32_t>(i));
    }
  }

  void write_line(uint32_t line_addr, const std::array<uint32_t, 8> &line) {
    for (int i = 0; i < 8; i++) {
      write_word(line_addr + 4u * static_cast<uint32_t>(i), line[i]);
    }
  }

  bool load_binary(const std::string &path, uint32_t base) {
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
  UnifiedMem *mem = nullptr;

  void reset() {
    pending = false;
    delay = 0;
    miss_addr = 0;
    miss_way = 0;
    refill_pulse = false;
  }

  void drive(Vtb_triathlon *top) {
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

  void observe(Vtb_triathlon *top) {
    if (!top->rst_ni) {
      reset();
      return;
    }

    if (refill_pulse) {
      refill_pulse = false;
    }

    if (top->icache_miss_req_valid_o && top->icache_miss_req_ready_i) {
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
  struct MissTxn {
    int delay = 0;
    uint32_t miss_addr = 0;
    uint32_t miss_way = 0;
    std::array<uint32_t, 8> line_words{};
  };

  std::deque<MissTxn> pending_q{};
  bool refill_pulse = false;
  MissTxn refill_txn{};
  UnifiedMem *mem = nullptr;

  void reset() {
    pending_q.clear();
    refill_pulse = false;
    refill_txn = MissTxn{};
  }

  void drive(Vtb_triathlon *top) {
    top->dcache_miss_req_ready_i = 1;
    top->dcache_wb_req_ready_i = 1;
    if (refill_pulse) {
      top->dcache_refill_valid_i = 1;
      top->dcache_refill_paddr_i = refill_txn.miss_addr;
      top->dcache_refill_way_i = refill_txn.miss_way;
      for (int i = 0; i < 8; i++) top->dcache_refill_data_i[i] = refill_txn.line_words[i];
    } else {
      top->dcache_refill_valid_i = 0;
      top->dcache_refill_paddr_i = 0;
      top->dcache_refill_way_i = 0;
      for (int i = 0; i < 8; i++) top->dcache_refill_data_i[i] = 0;
    }
  }

  void observe(Vtb_triathlon *top) {
    if (!top->rst_ni) {
      reset();
      return;
    }

    if (refill_pulse) {
      refill_pulse = false;
    }

    if (top->dcache_miss_req_valid_o && top->dcache_miss_req_ready_i) {
      MissTxn txn{};
      txn.delay = 2;
      txn.miss_addr = top->dcache_miss_req_paddr_o;
      txn.miss_way = top->dcache_miss_req_victim_way_o;
      if (mem) mem->fill_line(txn.miss_addr, txn.line_words);
      pending_q.push_back(txn);
    }

    for (auto &txn : pending_q) {
      if (txn.delay > 0) {
        txn.delay--;
      }
    }

    if (!pending_q.empty() && pending_q.front().delay == 0) {
      if (top->dcache_refill_ready_o) {
        refill_txn = pending_q.front();
        pending_q.pop_front();
        refill_pulse = true;
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

  void drive(Vtb_triathlon *top) {
    icache.drive(top);
    dcache.drive(top);
  }

  void observe(Vtb_triathlon *top) {
    icache.observe(top);
    dcache.observe(top);
  }
};

static void tick(Vtb_triathlon *top, MemSystem &mem, VerilatedVcdC *tfp,
                 vluint64_t &sim_time) {
  mem.drive(top);
  top->clk_i = 0;
  top->eval();
  if (tfp) tfp->dump(sim_time++);
  top->clk_i = 1;
  top->eval();
  if (tfp) tfp->dump(sim_time++);
  mem.observe(top);
}

static void reset(Vtb_triathlon *top, MemSystem &mem, VerilatedVcdC *tfp,
                  vluint64_t &sim_time) {
  top->rst_ni = 0;
  mem.reset();
  for (int i = 0; i < 5; i++) tick(top, mem, tfp, sim_time);
  top->rst_ni = 1;
  for (int i = 0; i < 2; i++) tick(top, mem, tfp, sim_time);
}

}  // namespace

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  SimArgs args = parse_args(argc, argv);

  if (args.img_path.empty()) {
    std::cerr << "Usage: " << argv[0]
              << " <IMG> [--max-cycles N] [-d REF_SO] [--trace [vcd]] [--commit-trace]"
              << " [--bru-trace] [--fe-trace] [--stall-trace [N]]"
              << " [--progress [N]]\n";
    return 1;
  }

  MemSystem mem;
  if (!mem.mem.load_binary(args.img_path, kPmemBase)) return 1;
  mem.icache.mem = &mem.mem;
  mem.dcache.mem = &mem.mem;

  auto *top = new Vtb_triathlon;
  VerilatedVcdC *tfp = nullptr;
  vluint64_t sim_time = 0;

#if VM_TRACE
  if (args.trace) {
    Verilated::traceEverOn(true);
    tfp = new VerilatedVcdC;
    top->trace(tfp, 99);
    tfp->open(args.trace_path.c_str());
  }
#else
  if (args.trace) {
    std::cerr << "[warn] this binary is built without --trace support, ignore --trace\n";
  }
#endif

  Difftest difftest;
  if (!args.difftest_so.empty()) {
    if (!difftest.init(args.difftest_so, mem.mem.pmem_words, kPmemBase)) {
      if (tfp) tfp->close();
      delete top;
      return 1;
    }
  }

  reset(top, mem, tfp, sim_time);

  std::array<uint32_t, 32> rf{};
  uint64_t no_commit_cycles = 0;
  uint64_t total_commits = 0;
  uint32_t last_commit_pc = 0;
  uint32_t last_commit_inst = 0;
  bool pending_flush_penalty = false;
  uint64_t pending_flush_cycle = 0;
  std::string pending_flush_reason = "unknown";
  uint64_t pred_cond_total = 0;
  uint64_t pred_cond_miss = 0;
  uint64_t pred_jump_total = 0;
  uint64_t pred_jump_miss = 0;
  uint64_t pred_ret_total = 0;
  uint64_t pred_ret_miss = 0;
  uint64_t pred_call_total = 0;
  uint64_t control_branch_count = 0;
  uint64_t control_jal_count = 0;
  uint64_t control_jalr_count = 0;
  uint64_t control_branch_taken_count = 0;
  uint64_t control_call_count = 0;
  uint64_t control_ret_count = 0;
  uint64_t redirect_distance_sum = 0;
  uint64_t redirect_distance_samples = 0;
  uint64_t redirect_distance_max = 0;
  uint64_t wrong_path_killed_uops = 0;
  std::unordered_map<uint32_t, uint64_t> commit_pc_hist;
  std::unordered_map<uint32_t, uint64_t> commit_inst_hist;
  std::array<uint64_t, 5> commit_width_hist = {};
  std::array<uint64_t, 8> stall_cycle_hist = {};
  std::array<uint64_t, 19> stall_frontend_empty_hist = {};
  std::unordered_map<std::string, uint64_t> stall_decode_blocked_detail_hist;
  std::unordered_map<std::string, uint64_t> stall_rob_backpressure_detail_hist;
  uint64_t ifu_fq_enq = 0;
  uint64_t ifu_fq_deq = 0;
  uint64_t ifu_fq_bypass = 0;
  uint64_t ifu_fq_enq_blocked = 0;
  uint64_t ifu_fq_full_cycles = 0;
  uint64_t ifu_fq_empty_cycles = 0;
  uint64_t ifu_fq_nonempty_cycles = 0;
  uint64_t ifu_fq_occ_sum = 0;
  uint64_t ifu_fq_occ_max = 0;
  std::array<uint64_t, 16> ifu_fq_occ_hist = {};
  bool has_prev_commit = false;
  uint32_t prev_commit_pc = 0;
  uint32_t prev_commit_inst = 0;

  auto popcount4 = [](uint32_t v) -> uint32_t {
    v &= 0xFu;
    return ((v >> 0) & 1u) + ((v >> 1) & 1u) + ((v >> 2) & 1u) + ((v >> 3) & 1u);
  };
  auto is_call_inst = [](uint32_t inst) -> bool {
    uint32_t opcode = inst & 0x7Fu;
    uint32_t rd = (inst >> 7) & 0x1Fu;
    if (opcode == 0x6Fu || opcode == 0x67u) {
      return (rd == 1u || rd == 5u);
    }
    return false;
  };
  auto is_ret_inst = [](uint32_t inst) -> bool {
    uint32_t opcode = inst & 0x7Fu;
    if (opcode != 0x67u) return false;  // JALR only
    uint32_t rd = (inst >> 7) & 0x1Fu;
    uint32_t rs1 = (inst >> 15) & 0x1Fu;
    uint32_t imm12 = (inst >> 20) & 0xFFFu;
    return (rd == 0u) && (rs1 == 1u || rs1 == 5u) && (imm12 == 0u);
  };
  auto emit_pred_summary = [&]() {
    if (!(args.commit_trace || args.bru_trace)) return;
    uint64_t pred_cond_hit = (pred_cond_total >= pred_cond_miss) ? (pred_cond_total - pred_cond_miss) : 0;
    uint64_t pred_jump_hit = (pred_jump_total >= pred_jump_miss) ? (pred_jump_total - pred_jump_miss) : 0;
    uint64_t pred_ret_hit = (pred_ret_total >= pred_ret_miss) ? (pred_ret_total - pred_ret_miss) : 0;
    uint64_t cond_update_total = static_cast<uint64_t>(top->dbg_bpu_cond_update_total_o);
    uint64_t cond_local_correct = static_cast<uint64_t>(top->dbg_bpu_cond_local_correct_o);
    uint64_t cond_global_correct = static_cast<uint64_t>(top->dbg_bpu_cond_global_correct_o);
    uint64_t cond_selected_correct = static_cast<uint64_t>(top->dbg_bpu_cond_selected_correct_o);
    uint64_t cond_choose_local = static_cast<uint64_t>(top->dbg_bpu_cond_choose_local_o);
    uint64_t cond_choose_global = static_cast<uint64_t>(top->dbg_bpu_cond_choose_global_o);
    std::ios::fmtflags f(std::cout.flags());
    std::cout << "[pred  ] cond_total=" << pred_cond_total
              << " cond_miss=" << pred_cond_miss
              << " cond_hit=" << pred_cond_hit
              << " jump_total=" << pred_jump_total
              << " jump_miss=" << pred_jump_miss
              << " jump_hit=" << pred_jump_hit
              << " ret_total=" << pred_ret_total
              << " ret_miss=" << pred_ret_miss
              << " ret_hit=" << pred_ret_hit
              << " call_total=" << pred_call_total
              << " cond_update_total=" << cond_update_total
              << " cond_local_correct=" << cond_local_correct
              << " cond_global_correct=" << cond_global_correct
              << " cond_selected_correct=" << cond_selected_correct
              << " cond_choose_local=" << cond_choose_local
              << " cond_choose_global=" << cond_choose_global
              << "\n";
    std::cout << "[flushm] wrong_path_killed_uops=" << wrong_path_killed_uops
              << " redirect_distance_samples=" << redirect_distance_samples
              << " redirect_distance_sum=" << redirect_distance_sum
              << " redirect_distance_max=" << redirect_distance_max
              << "\n";
    std::cout.flags(f);
  };

  enum StallKindIdx : int {
    kStallFlushRecovery = 0,
    kStallICacheMissWait = 1,
    kStallDCacheMissWait = 2,
    kStallROBBackpressure = 3,
    kStallFrontendEmpty = 4,
    kStallDecodeBlocked = 5,
    kStallLSUReqBlocked = 6,
    kStallOther = 7,
  };

  enum FrontendEmptyDetailIdx : int {
    kFeNoReq = 0,
    kFeWaitICacheRspHitLatency = 1,
    kFeWaitICacheRspMissWait = 2,
    kFeRspBlockedByFQFull = 3,
    kFeWaitIbufferConsume = 4,
    kFeRedirectRecovery = 5,
    kFeRspCaptureBubble = 6,
    kFeHasDataDecodeGap = 7,
    kFeOther = 8,
    kFeDropStaleRsp = 9,
    kFeNoReqReqQEmpty = 10,
    kFeNoReqInfFull = 11,
    kFeNoReqStorageBudget = 12,
    kFeNoReqFlushBlock = 13,
    kFeNoReqOther = 14,
    kFeReqFireNoInflight = 15,
    kFeRspNoInflight = 16,
    kFeFQNonemptyNoFeValid = 17,
    kFeReqReadyNoFire = 18,
  };

  auto classify_stall_cycle = [&]() -> int {
    if (top->backend_flush_o) return kStallFlushRecovery;
    if (top->icache_miss_req_valid_o) return kStallICacheMissWait;
    if (top->dcache_miss_req_valid_o) return kStallDCacheMissWait;
    if (!top->dbg_rob_ready_o) return kStallROBBackpressure;
    if (!top->dbg_dec_valid_o) return kStallFrontendEmpty;
    if (top->dbg_dec_valid_o && !top->dbg_dec_ready_o) return kStallDecodeBlocked;
    if (top->dbg_lsu_issue_valid_o && !top->dbg_lsu_req_ready_o) return kStallLSUReqBlocked;
    return kStallOther;
  };

  auto classify_frontend_empty_cycle = [&]() -> int {
    bool fe_valid = top->dbg_fe_valid_o;
    bool fe_ready = top->dbg_fe_ready_o;
    bool ifu_req_valid = top->dbg_ifu_req_valid_o;
    bool ifu_req_ready = top->dbg_ifu_req_ready_o;
    bool ifu_req_fire = top->dbg_ifu_req_fire_o;
    bool ifu_req_inflight = top->dbg_ifu_req_inflight_o;
    bool ifu_rsp_valid = top->dbg_ifu_rsp_valid_o;
    bool ifu_rsp_capture = top->dbg_ifu_rsp_capture_o;
    bool ifu_drop_stale_rsp = top->dbg_ifu_drop_stale_rsp_o;
    bool ifu_fq_full = top->dbg_ifu_fq_full_o;
    bool ifu_fq_empty = top->dbg_ifu_fq_empty_o;
    bool ifu_block_flush = top->dbg_ifu_block_flush_o;
    bool ifu_block_reqq_empty = top->dbg_ifu_block_reqq_empty_o;
    bool ifu_block_inf_full = top->dbg_ifu_block_inf_full_o;
    bool ifu_block_storage_budget = top->dbg_ifu_block_storage_budget_o;

    if (fe_valid && !fe_ready) return kFeWaitIbufferConsume;
    if (fe_valid && fe_ready) return kFeHasDataDecodeGap;
    if (ifu_req_inflight && ifu_rsp_valid && ifu_rsp_capture) return kFeRspCaptureBubble;
    if (ifu_drop_stale_rsp) return kFeDropStaleRsp;
    if (ifu_rsp_valid && !ifu_rsp_capture && ifu_fq_full) return kFeRspBlockedByFQFull;
    if (ifu_req_inflight && !ifu_rsp_valid) {
      uint32_t icache_state = static_cast<uint32_t>(top->dbg_icache_state_o);
      if (icache_state == 2u || icache_state == 3u) return kFeWaitICacheRspMissWait;
      return kFeWaitICacheRspHitLatency;
    }
    if (!ifu_req_inflight && ifu_fq_empty && !ifu_req_valid) {
      if (ifu_block_flush) return kFeNoReqFlushBlock;
      if (ifu_block_reqq_empty) return kFeNoReqReqQEmpty;
      if (ifu_block_inf_full) return kFeNoReqInfFull;
      if (ifu_block_storage_budget) return kFeNoReqStorageBudget;
      if (!ifu_req_ready) return kFeRedirectRecovery;
      return kFeNoReqOther;
    }
    if (!ifu_req_fire && ifu_req_valid && !ifu_req_ready) return kFeRedirectRecovery;
    if (ifu_req_fire && !ifu_req_inflight && !ifu_rsp_valid) return kFeReqFireNoInflight;
    if (ifu_rsp_valid && !ifu_rsp_capture && !ifu_req_inflight) return kFeRspNoInflight;
    if (!ifu_fq_empty && !fe_valid) return kFeFQNonemptyNoFeValid;
    if (ifu_req_valid && ifu_req_ready && !ifu_req_fire) return kFeReqReadyNoFire;
    return kFeOther;
  };

  auto classify_decode_blocked_detail_cycle = [&]() -> const char * {
    constexpr uint32_t kPendingReplayFullSrc = 4;
    int has_rs2 = static_cast<int>(top->dbg_lsu_rs_head_has_rs2_o);
    int rs2_ready = static_cast<int>(top->dbg_lsu_rs_head_r2_ready_o);

    if (top->dbg_ren_src_from_pending_o) {
      bool full = static_cast<uint32_t>(top->dbg_ren_src_count_o) >= kPendingReplayFullSrc;
      if (top->dbg_ren_fire_o && static_cast<uint32_t>(top->dbg_ren_sel_count_o) > 0u) {
        return full ? "pending_replay_progress_full" : "pending_replay_progress_has_room";
      }
      return full ? "pending_replay_wait_full" : "pending_replay_wait_has_room";
    }

    if (static_cast<uint32_t>(top->dbg_lsu_grp_lane_busy_o) != 0u && !top->dbg_lsu_grp_alloc_fire_o) {
      if (static_cast<uint32_t>(top->dbg_lsu_grp_ld_owner_o) == 0u) return "lsug_wait_dcache_owner";
      return "lsug_no_free_lane";
    }

    if (top->dbg_dc_store_wait_same_line_o) return "dc_store_wait_same_line";
    if (top->dbg_dc_store_wait_mshr_full_o) return "dc_store_wait_mshr_full";

    if (static_cast<uint32_t>(top->dbg_sb_alloc_req_o) != 0u && !top->dbg_sb_alloc_ready_o) return "sb_alloc_blocked";

    if (top->dbg_lsu_rs_head_valid_o) {
      bool has_rs1 = top->dbg_lsu_rs_head_has_rs1_o;
      bool rs1_ready = top->dbg_lsu_rs_head_r1_ready_o;
      bool has_rs2_local = top->dbg_lsu_rs_head_has_rs2_o;
      bool rs2_ready_local = top->dbg_lsu_rs_head_r2_ready_o;
      if ((has_rs1 && !rs1_ready) || (has_rs2_local && !rs2_ready_local)) return "lsu_operand_wait";
    }

    if (static_cast<uint32_t>(top->dbg_lsu_rs_busy_o) != 0u && static_cast<uint32_t>(top->dbg_lsu_rs_ready_o) == 0u) {
      return "lsu_rs_pressure";
    }

    if (top->dbg_rob_q2_valid_o && !top->dbg_rob_q2_complete_o && has_rs2 == 1 && rs2_ready == 0) return "rob_q2_wait";

    std::array<int, 5> gate = {static_cast<int>(top->dbg_gate_alu_o), static_cast<int>(top->dbg_gate_bru_o),
                               static_cast<int>(top->dbg_gate_lsu_o), static_cast<int>(top->dbg_gate_mdu_o),
                               static_cast<int>(top->dbg_gate_csr_o)};
    std::array<uint32_t, 5> need = {static_cast<uint32_t>(top->dbg_need_alu_o), static_cast<uint32_t>(top->dbg_need_bru_o),
                                    static_cast<uint32_t>(top->dbg_need_lsu_o), static_cast<uint32_t>(top->dbg_need_mdu_o),
                                    static_cast<uint32_t>(top->dbg_need_csr_o)};
    const std::array<std::pair<int, const char *>, 5> gate_priority = {{
        {2, "dispatch_gate_lsu"},
        {0, "dispatch_gate_alu"},
        {1, "dispatch_gate_bru"},
        {4, "dispatch_gate_csr"},
        {3, "dispatch_gate_mdu"},
    }};
    for (const auto &entry : gate_priority) {
      int idx = entry.first;
      if (gate[idx] == 0 && need[idx] > 0u) return entry.second;
    }
    for (const auto &entry : gate_priority) {
      int idx = entry.first;
      if (gate[idx] == 0) return entry.second;
    }

    uint32_t sm = static_cast<uint32_t>(top->dbg_lsu_state_o);
    if (sm == 1u && !top->dbg_lsu_ld_fire_o) return "lsu_wait_ld_req";
    if (sm == 2u && !top->dbg_lsu_rsp_fire_o) return "lsu_wait_ld_rsp";
    return "other";
  };

  auto classify_rob_backpressure_detail_cycle = [&]() -> const char * {
    uint32_t fu = static_cast<uint32_t>(top->dbg_rob_head_fu_o);
    bool complete = top->dbg_rob_head_complete_o;
    bool is_store = top->dbg_rob_head_is_store_o;

    if (is_store) {
      if (!top->dbg_sb_head_valid_o) return "rob_store_wait_sb_head";
      if (!top->dbg_sb_head_committed_o) return "rob_store_wait_commit";
      if (!top->dbg_sb_head_addr_valid_o) return "rob_store_wait_addr";
      if (!top->dbg_sb_head_data_valid_o) return "rob_store_wait_data";
      if (top->dbg_sb_dcache_req_valid_o && !top->dbg_sb_dcache_req_ready_o) return "rob_store_wait_dcache";
      if (!top->dbg_sb_dcache_req_valid_o) return "rob_store_wait_issue";
      return "rob_store_wait_other";
    }

    if (!complete) {
      if (fu == 1u) return "rob_head_fu_alu_incomplete";
      if (fu == 2u) return "rob_head_fu_branch_incomplete";
      if (fu == 3u) {
        uint32_t sm = static_cast<uint32_t>(top->dbg_lsu_state_o);
        bool ld_valid = top->dbg_lsu_ld_req_valid_o;
        bool ld_ready = top->dbg_lsu_ld_req_ready_o;
        bool rsp_valid = top->dbg_lsu_ld_rsp_valid_o;
        bool rsp_ready = top->dbg_lsu_ld_rsp_ready_o;
        uint32_t owner = static_cast<uint32_t>(top->dbg_lsu_grp_ld_owner_o);
        bool alloc_fire = top->dbg_lsu_grp_alloc_fire_o;

        if (sm == 0u) return "rob_lsu_incomplete_sm_idle";
        if (sm == 1u) {
          if (ld_valid && !ld_ready) {
            if (owner != 0u) {
              if (rsp_valid && rsp_ready) return "rob_lsu_wait_ld_req_ready_owner_rsp_fire";
              if (!rsp_valid && rsp_ready) return "rob_lsu_wait_ld_req_ready_owner_rsp_valid";
              if (rsp_valid && !rsp_ready) return "rob_lsu_wait_ld_req_ready_owner_rsp_ready";
            }
            if (top->dbg_sb_dcache_req_valid_o && !top->dbg_sb_dcache_req_ready_o) return "rob_lsu_wait_ld_req_ready_sb_conflict";
            bool mshr_blocked = top->dbg_dc_mshr_full_o || !top->dbg_dc_mshr_alloc_ready_o;
            if (mshr_blocked) return "rob_lsu_wait_ld_req_ready_mshr_blocked";
            if (top->dcache_miss_req_valid_o && !top->dcache_miss_req_ready_i) return "rob_lsu_wait_ld_req_ready_miss_port_busy";
            return "rob_lsu_wait_ld_req_ready";
          }
          if (!ld_valid && !ld_ready) {
            if (owner != 0u) {
              if (rsp_valid && rsp_ready) return "rob_lsu_wait_ld_owner_rsp_fire";
              if (!rsp_valid && rsp_ready) return "rob_lsu_wait_ld_owner_rsp_valid";
              if (rsp_valid && !rsp_ready) return "rob_lsu_wait_ld_owner_rsp_ready";
              return "rob_lsu_wait_ld_owner_hold";
            }
            if (!alloc_fire) return "rob_lsu_wait_ld_arb_no_grant";
          }
          if (!top->dbg_lsu_ld_fire_o) return "rob_lsu_wait_ld_req_fire";
          return "rob_lsu_incomplete_sm_req_unknown";
        }
        if (sm == 2u) {
          if (!rsp_valid) return "rob_lsu_wait_ld_rsp_valid";
          if (rsp_valid && !rsp_ready) return "rob_lsu_wait_ld_rsp_ready";
          if (!top->dbg_lsu_rsp_fire_o) return "rob_lsu_wait_ld_rsp_fire";
          return "rob_lsu_incomplete_sm_rsp_unknown";
        }
        if (sm == 3u) return "rob_lsu_wait_wb";
        return "rob_lsu_incomplete_sm_illegal";
      }
      if (fu == 4u || fu == 5u) return "rob_head_fu_mdu_incomplete";
      if (fu == 6u) return "rob_head_fu_csr_incomplete";
      return "rob_head_fu_unknown_incomplete";
    }

    return "rob_head_complete_but_not_ready";
  };

  auto emit_ranked_summary = [&](const char *tag,
                                 const char *value_key,
                                 const std::unordered_map<uint32_t, uint64_t> &hist) {
    std::vector<std::pair<uint32_t, uint64_t>> items(hist.begin(), hist.end());
    std::sort(items.begin(), items.end(), [](const auto &a, const auto &b) {
      if (a.second != b.second) return a.second > b.second;
      return a.first < b.first;
    });

    std::ios::fmtflags f(std::cout.flags());
    std::cout << "[" << tag << "]";
    const size_t limit = std::min<size_t>(5, items.size());
    for (size_t i = 0; i < limit; i++) {
      std::cout << " rank" << i << "_" << value_key << "=0x" << std::hex << items[i].first
                << std::dec << " rank" << i << "_count=" << items[i].second;
    }
    std::cout << "\n";
    std::cout.flags(f);
  };

  auto emit_detail_summary = [&](const char *tag, const char *total_key, uint64_t total,
                                 const std::unordered_map<std::string, uint64_t> &hist) {
    std::vector<std::pair<std::string, uint64_t>> items(hist.begin(), hist.end());
    std::sort(items.begin(), items.end(), [](const auto &a, const auto &b) {
      if (a.first != b.first) return a.first < b.first;
      return a.second > b.second;
    });
    std::cout << "[" << tag << "] mode=cycle " << total_key << "=" << total;
    for (const auto &kv : items) {
      std::cout << " " << kv.first << "=" << kv.second;
    }
    std::cout << "\n";
  };

  auto emit_profile_summary = [&](uint64_t final_cycles) {
    if (!(args.commit_trace || args.bru_trace)) return;
    emit_pred_summary();

    if (has_prev_commit) {
      uint32_t opcode = prev_commit_inst & 0x7Fu;
      if (opcode == 0x63u) {
        control_branch_count++;
      } else if (opcode == 0x6Fu) {
        control_jal_count++;
      } else if (opcode == 0x67u) {
        control_jalr_count++;
      }
      if (is_call_inst(prev_commit_inst)) control_call_count++;
      if (is_ret_inst(prev_commit_inst)) control_ret_count++;
      has_prev_commit = false;
    }

    uint64_t stall_total_cycles = 0;
    for (uint64_t v : stall_cycle_hist) stall_total_cycles += v;

    std::cout << "[commitm] cycles=" << final_cycles
              << " commits=" << total_commits
              << " width0=" << commit_width_hist[0]
              << " width1=" << commit_width_hist[1]
              << " width2=" << commit_width_hist[2]
              << " width3=" << commit_width_hist[3]
              << " width4=" << commit_width_hist[4]
              << "\n";
    std::cout << "[controlm] branch_count=" << control_branch_count
              << " jal_count=" << control_jal_count
              << " jalr_count=" << control_jalr_count
              << " branch_taken_count=" << control_branch_taken_count
              << " call_count=" << control_call_count
              << " ret_count=" << control_ret_count
              << " control_count=" << (control_branch_count + control_jal_count + control_jalr_count)
              << "\n";
    std::cout << "[stallm] mode=cycle"
              << " stall_total_cycles=" << stall_total_cycles
              << " flush_recovery=" << stall_cycle_hist[kStallFlushRecovery]
              << " icache_miss_wait=" << stall_cycle_hist[kStallICacheMissWait]
              << " dcache_miss_wait=" << stall_cycle_hist[kStallDCacheMissWait]
              << " rob_backpressure=" << stall_cycle_hist[kStallROBBackpressure]
              << " frontend_empty=" << stall_cycle_hist[kStallFrontendEmpty]
              << " decode_blocked=" << stall_cycle_hist[kStallDecodeBlocked]
              << " lsu_req_blocked=" << stall_cycle_hist[kStallLSUReqBlocked]
              << " other=" << stall_cycle_hist[kStallOther]
              << "\n";
    uint64_t fe_no_req_total = stall_frontend_empty_hist[kFeNoReq] +
                               stall_frontend_empty_hist[kFeNoReqReqQEmpty] +
                               stall_frontend_empty_hist[kFeNoReqInfFull] +
                               stall_frontend_empty_hist[kFeNoReqStorageBudget] +
                               stall_frontend_empty_hist[kFeNoReqFlushBlock] +
                               stall_frontend_empty_hist[kFeNoReqOther];
    std::cout << "[stallm2] mode=cycle"
              << " frontend_empty_total=" << stall_cycle_hist[kStallFrontendEmpty]
              << " fe_no_req=" << fe_no_req_total
              << " fe_wait_icache_rsp_hit_latency=" << stall_frontend_empty_hist[kFeWaitICacheRspHitLatency]
              << " fe_wait_icache_rsp_miss_wait=" << stall_frontend_empty_hist[kFeWaitICacheRspMissWait]
              << " fe_rsp_blocked_by_fq_full=" << stall_frontend_empty_hist[kFeRspBlockedByFQFull]
              << " fe_wait_ibuffer_consume=" << stall_frontend_empty_hist[kFeWaitIbufferConsume]
              << " fe_redirect_recovery=" << stall_frontend_empty_hist[kFeRedirectRecovery]
              << " fe_rsp_capture_bubble=" << stall_frontend_empty_hist[kFeRspCaptureBubble]
              << " fe_has_data_decode_gap=" << stall_frontend_empty_hist[kFeHasDataDecodeGap]
              << " fe_drop_stale_rsp=" << stall_frontend_empty_hist[kFeDropStaleRsp]
              << " fe_no_req_reqq_empty=" << stall_frontend_empty_hist[kFeNoReqReqQEmpty]
              << " fe_no_req_inf_full=" << stall_frontend_empty_hist[kFeNoReqInfFull]
              << " fe_no_req_storage_budget=" << stall_frontend_empty_hist[kFeNoReqStorageBudget]
              << " fe_no_req_flush_block=" << stall_frontend_empty_hist[kFeNoReqFlushBlock]
              << " fe_no_req_other=" << stall_frontend_empty_hist[kFeNoReqOther]
              << " fe_req_fire_no_inflight=" << stall_frontend_empty_hist[kFeReqFireNoInflight]
              << " fe_rsp_no_inflight=" << stall_frontend_empty_hist[kFeRspNoInflight]
              << " fe_fq_nonempty_no_fevalid=" << stall_frontend_empty_hist[kFeFQNonemptyNoFeValid]
              << " fe_req_ready_nofire=" << stall_frontend_empty_hist[kFeReqReadyNoFire]
              << " fe_other=" << stall_frontend_empty_hist[kFeOther]
              << "\n";
    uint64_t fq_samples = final_cycles;
    uint64_t fq_occ_avg_x1000 = (fq_samples == 0) ? 0 : ((ifu_fq_occ_sum * 1000ull + fq_samples / 2ull) / fq_samples);
    std::cout << "[ifum] mode=cycle"
              << " fq_samples=" << fq_samples
              << " fq_enq=" << ifu_fq_enq
              << " fq_deq=" << ifu_fq_deq
              << " fq_bypass=" << ifu_fq_bypass
              << " fq_enq_blocked=" << ifu_fq_enq_blocked
              << " fq_full_cycles=" << ifu_fq_full_cycles
              << " fq_empty_cycles=" << ifu_fq_empty_cycles
              << " fq_nonempty_cycles=" << ifu_fq_nonempty_cycles
              << " fq_occ_sum=" << ifu_fq_occ_sum
              << " fq_occ_max=" << ifu_fq_occ_max
              << " fq_occ_avg_x1000=" << fq_occ_avg_x1000;
    for (size_t i = 0; i < ifu_fq_occ_hist.size(); i++) {
      std::cout << " fq_occ_bin" << i << "=" << ifu_fq_occ_hist[i];
    }
    std::cout << "\n";
    emit_detail_summary("stallm3", "decode_blocked_total", stall_cycle_hist[kStallDecodeBlocked],
                        stall_decode_blocked_detail_hist);
    emit_detail_summary("stallm4", "rob_backpressure_total", stall_cycle_hist[kStallROBBackpressure],
                        stall_rob_backpressure_detail_hist);
    emit_ranked_summary("hotpcm", "pc", commit_pc_hist);
    emit_ranked_summary("hotinstm", "inst", commit_inst_hist);
  };
  for (uint64_t cycles = 0; cycles < args.max_cycles; cycles++) {
    mem.mem.set_time_us(cycles);
    tick(top, mem, tfp, sim_time);
    uint32_t fq_count = static_cast<uint32_t>(top->dbg_ifu_fq_count_o);
    if (fq_count >= ifu_fq_occ_hist.size()) fq_count = static_cast<uint32_t>(ifu_fq_occ_hist.size() - 1);
    ifu_fq_occ_sum += fq_count;
    ifu_fq_occ_hist[fq_count]++;
    ifu_fq_occ_max = std::max<uint64_t>(ifu_fq_occ_max, fq_count);
    if (top->dbg_ifu_fq_full_o) ifu_fq_full_cycles++;
    if (top->dbg_ifu_fq_empty_o) {
      ifu_fq_empty_cycles++;
    } else {
      ifu_fq_nonempty_cycles++;
    }
    if (top->dbg_ifu_fq_enq_fire_o) ifu_fq_enq++;
    if (top->dbg_ifu_fq_deq_fire_o) ifu_fq_deq++;
    if (top->dbg_ifu_fq_bypass_fire_o) ifu_fq_bypass++;
    if (top->dbg_ifu_fq_enq_blocked_o) ifu_fq_enq_blocked++;

    if (top->dbg_sb_dcache_req_valid_o && top->dbg_sb_dcache_req_ready_o) {
      uint32_t addr = top->dbg_sb_dcache_req_addr_o;
      uint32_t data = top->dbg_sb_dcache_req_data_o;
      uint32_t op = top->dbg_sb_dcache_req_op_o;
      mem.mem.write_store(addr, data, op);
      if (args.commit_trace) {
        std::ios::fmtflags f(std::cout.flags());
        std::cout << "[stwb  ] cycle=" << cycles
                  << " addr=0x" << std::hex << addr
                  << " data=0x" << data
                  << std::dec
                  << " op=" << op
                  << ((addr == kSeed4Addr) ? " <seed4>" : "")
                  << "\n";
        std::cout.flags(f);
      }
      // avoid double printing when difftest also prints the log
      if (addr == kSerialPort && !difftest.enabled()) {
        uint8_t ch = static_cast<uint8_t>(data & 0xFFu);
        std::cout << static_cast<char>(ch) << std::flush;
      }
    }

    if (args.commit_trace && top->dbg_lsu_ld_fire_o) {
      std::ios::fmtflags f(std::cout.flags());
      std::cout << "[ldreq ] cycle=" << cycles
                << " addr=0x" << std::hex << top->dbg_lsu_ld_req_addr_o
                << " tag=0x" << static_cast<uint32_t>(top->dbg_lsu_inflight_tag_o)
                << ((top->dbg_lsu_ld_req_addr_o == kSeed4Addr) ? " <seed4>" : "")
                << std::dec << "\n";
      std::cout.flags(f);
    }

    if (args.commit_trace && top->dbg_lsu_rsp_fire_o) {
      std::ios::fmtflags f(std::cout.flags());
      std::cout << "[ldrsp ] cycle=" << cycles
                << " addr=0x" << std::hex << top->dbg_lsu_inflight_addr_o
                << " tag=0x" << static_cast<uint32_t>(top->dbg_lsu_inflight_tag_o)
                << " data=0x" << top->dbg_lsu_ld_rsp_data_o
                << std::dec
                << " err=" << static_cast<int>(top->dbg_lsu_ld_rsp_err_o)
                << ((top->dbg_lsu_inflight_addr_o == kSeed4Addr) ? " <seed4>" : "")
                << "\n";
      std::cout.flags(f);
    }

    if ((args.commit_trace || args.bru_trace) && top->backend_flush_o) {
      bool rob_flush = top->dbg_rob_flush_o;
      bool rob_mispred = top->dbg_rob_flush_is_mispred_o;
      bool rob_exception = top->dbg_rob_flush_is_exception_o;
      bool rob_is_branch = top->dbg_rob_flush_is_branch_o;
      bool rob_is_jump = top->dbg_rob_flush_is_jump_o;
      uint32_t cause = static_cast<uint32_t>(top->dbg_rob_flush_cause_o) & 0x1Fu;
      uint32_t src_pc = top->dbg_rob_flush_src_pc_o;
      uint32_t redirect_pc = top->backend_redirect_pc_o;

      std::string flush_reason = "external";
      std::string flush_source = rob_flush ? "rob" : "external";
      if (rob_flush) {
        if (rob_mispred) {
          flush_reason = "branch_mispredict";
        } else if (rob_exception) {
          flush_reason = "exception";
        } else {
          flush_reason = "rob_other";
        }
      }

      std::string miss_type = "none";
      std::string miss_subtype = "none";
      if (flush_reason == "branch_mispredict") {
        if (rob_is_jump) {
          uint32_t src_inst = mem.mem.read_word(src_pc);
          if (is_ret_inst(src_inst)) {
            miss_type = "return";
            miss_subtype = "return";
            pred_ret_miss++;
          } else {
            miss_type = "jump";
            miss_subtype = "jump";
            pred_jump_miss++;
          }
        } else if (rob_is_branch) {
          miss_type = "cond_branch";
          miss_subtype = "cond_branch";
          pred_cond_miss++;
        } else {
          miss_type = "control_unknown";
          miss_subtype = "control_unknown";
        }
      }

      uint32_t redirect_distance =
          (redirect_pc >= src_pc) ? (redirect_pc - src_pc) : (src_pc - redirect_pc);
      redirect_distance_sum += redirect_distance;
      redirect_distance_samples++;
      redirect_distance_max = std::max<uint64_t>(redirect_distance_max, redirect_distance);

      uint32_t commit_pop = popcount4(static_cast<uint32_t>(top->commit_valid_o));
      uint32_t rob_count = static_cast<uint32_t>(top->dbg_rob_count_o);
      uint32_t killed_uops = (rob_count >= commit_pop) ? (rob_count - commit_pop) : 0;
      if (flush_reason == "branch_mispredict") {
        wrong_path_killed_uops += killed_uops;
      }

      std::ios::fmtflags f(std::cout.flags());
      std::cout << "[flush ] cycle=" << cycles
                << " reason=" << flush_reason
                << " source=" << flush_source
                << " cause=0x" << std::hex << cause
                << " src_pc=0x" << src_pc
                << " redirect_pc=0x" << redirect_pc
                << std::dec
                << " miss_type=" << miss_type
                << " miss_subtype=" << miss_subtype
                << " bpu_arch_ras_count=" << static_cast<uint32_t>(top->dbg_bpu_arch_ras_count_o)
                << " bpu_spec_ras_count=" << static_cast<uint32_t>(top->dbg_bpu_spec_ras_count_o)
                << " bpu_arch_ras_top=0x" << std::hex << static_cast<uint32_t>(top->dbg_bpu_arch_ras_top_o)
                << " bpu_spec_ras_top=0x" << static_cast<uint32_t>(top->dbg_bpu_spec_ras_top_o)
                << std::dec
                << " redirect_distance=" << redirect_distance
                << " killed_uops=" << killed_uops
                << std::dec << "\n";
      if (top->dbg_bru_mispred_o) {
        std::cout << "[bru   ] cycle=" << cycles
                  << " valid=" << static_cast<int>(top->dbg_bru_valid_o)
                  << " pc=0x" << std::hex << top->dbg_bru_pc_o
                  << " imm=0x" << static_cast<uint32_t>(top->dbg_bru_imm_o)
                  << " op=" << std::dec << static_cast<int>(top->dbg_bru_op_o)
                  << " is_jump=" << static_cast<int>(top->dbg_bru_is_jump_o)
                  << " is_branch=" << static_cast<int>(top->dbg_bru_is_branch_o)
                  << std::dec << "\n";
      }
      std::cout.flags(f);
      if (!pending_flush_penalty) {
        pending_flush_penalty = true;
        pending_flush_cycle = cycles;
        pending_flush_reason = flush_reason;
      }
    }

    if (args.bru_trace && top->dbg_bru_wb_valid_o) {
      std::ios::fmtflags f(std::cout.flags());
      std::cout << "[bruwb ] cycle=" << cycles
                << " pc=0x" << std::hex << top->dbg_bru_pc_o
                << " v1=0x" << top->dbg_bru_v1_o
                << " v2=0x" << top->dbg_bru_v2_o
                << " redirect=0x" << top->dbg_bru_redirect_pc_o
                << std::dec
                << " mispred=" << static_cast<int>(top->dbg_bru_mispred_o)
                << " is_jump=" << static_cast<int>(top->dbg_bru_is_jump_o)
                << " is_branch=" << static_cast<int>(top->dbg_bru_is_branch_o)
                << " op=" << static_cast<int>(top->dbg_bru_op_o)
                << "\n";
      std::cout.flags(f);
    }

    uint32_t commit_this_cycle = 0;
    for (int i = 0; i < 4; i++) {
      bool valid = (top->commit_valid_o >> i) & 0x1;
      if (!valid) continue;
      commit_this_cycle++;
      total_commits++;

      std::array<uint32_t, 32> rf_before = rf;

      bool we = (top->commit_we_o >> i) & 0x1;
      uint32_t rd = (top->commit_areg_o >> (i * 5)) & 0x1F;
      uint32_t data = top->commit_wdata_o[i];
      if (we && rd != 0) {
        rf[rd] = data;
      }

      uint32_t pc = top->commit_pc_o[i];
      uint32_t inst = mem.mem.read_word(pc);
      commit_pc_hist[pc]++;
      commit_inst_hist[inst]++;

      if (has_prev_commit) {
        uint32_t prev_opcode = prev_commit_inst & 0x7Fu;
        if (prev_opcode == 0x63u) {
          control_branch_count++;
          uint32_t expected_next = prev_commit_pc + 4u;
          if (pc != expected_next) control_branch_taken_count++;
        } else if (prev_opcode == 0x6Fu) {
          control_jal_count++;
        } else if (prev_opcode == 0x67u) {
          control_jalr_count++;
        }
        if (is_call_inst(prev_commit_inst)) control_call_count++;
        if (is_ret_inst(prev_commit_inst)) control_ret_count++;
      }
      has_prev_commit = true;
      prev_commit_pc = pc;
      prev_commit_inst = inst;

      uint32_t opcode = inst & 0x7Fu;
      if (opcode == 0x63u) {
        pred_cond_total++;
      } else if (opcode == 0x6Fu || opcode == 0x67u) {
        if (is_ret_inst(inst)) {
          pred_ret_total++;
        } else {
          pred_jump_total++;
        }
      }
      if (is_call_inst(inst)) {
        pred_call_total++;
      }
      last_commit_pc = pc;
      last_commit_inst = inst;
      if (args.commit_trace) {
        std::ios::fmtflags f(std::cout.flags());
        std::cout << "[commit] cycle=" << cycles
                  << " slot=" << i
                  << " pc=0x" << std::hex << pc
                  << " inst=0x" << inst
                  << " we=" << std::dec << we
                  << " rd=x" << rd
                  << " data=0x" << std::hex << data
                  << " a0=0x" << rf[10]
                  << std::dec << "\n";
        std::cout.flags(f);
      }
      if (!difftest.step_and_check(cycles, pc, inst, rf_before, rf)) {
        std::cerr << "[difftest] stop on first mismatch\n";
        emit_profile_summary(cycles);
        if (tfp) tfp->close();
        delete top;
        return 1;
      }
      if (inst == kEbreakInsn) {
        uint32_t code = rf[10];
        if (code == 0) {
          std::cout << "HIT GOOD TRAP\n";
          double ipc = cycles ? static_cast<double>(total_commits) / static_cast<double>(cycles) : 0.0;
          double cpi = total_commits ? static_cast<double>(cycles) / static_cast<double>(total_commits) : 0.0;
          std::cout << "IPC=" << ipc << " CPI=" << cpi
                    << " cycles=" << cycles
                    << " commits=" << total_commits << "\n";
          emit_profile_summary(cycles);
          if (tfp) tfp->close();
          delete top;
          return 0;
        }
        std::cout << "HIT BAD TRAP (code=" << code << ")\n";
        emit_profile_summary(cycles);
        if (tfp) tfp->close();
        delete top;
        return 1;
      }
    }

    commit_width_hist[std::min<uint32_t>(commit_this_cycle, 4u)]++;

    if (commit_this_cycle != 0) {
      if ((args.commit_trace || args.bru_trace) && pending_flush_penalty &&
          cycles > pending_flush_cycle) {
        std::ios::fmtflags f(std::cout.flags());
        std::cout << "[flushp] cycle=" << cycles
                  << " reason=" << pending_flush_reason
                  << " penalty=" << (cycles - pending_flush_cycle)
                  << "\n";
        std::cout.flags(f);
        pending_flush_penalty = false;
      }
      if (difftest.enabled()) {
        DUTCSRState dut_csr = {};
        dut_csr.mtvec = top->dbg_csr_mtvec_o;
        dut_csr.mepc = top->dbg_csr_mepc_o;
        dut_csr.mstatus = top->dbg_csr_mstatus_o;
        dut_csr.mcause = top->dbg_csr_mcause_o;
        if (!difftest.check_arch_state(cycles, rf, dut_csr)) {
          std::cerr << "[difftest] stop on arch-state mismatch\n";
          emit_profile_summary(cycles);
          if (tfp) tfp->close();
          delete top;
          return 1;
        }
      }
      no_commit_cycles = 0;
    } else {
      no_commit_cycles++;
      int stall_kind = classify_stall_cycle();
      stall_cycle_hist[stall_kind]++;
      if (stall_kind == kStallFrontendEmpty) {
        stall_frontend_empty_hist[classify_frontend_empty_cycle()]++;
      } else if (stall_kind == kStallDecodeBlocked) {
        stall_decode_blocked_detail_hist[classify_decode_blocked_detail_cycle()]++;
      } else if (stall_kind == kStallROBBackpressure) {
        stall_rob_backpressure_detail_hist[classify_rob_backpressure_detail_cycle()]++;
      }
      if (args.stall_trace && args.stall_threshold > 0 &&
          (no_commit_cycles == args.stall_threshold ||
           (no_commit_cycles > args.stall_threshold &&
            no_commit_cycles % args.stall_threshold == 0))) {
        std::ios::fmtflags f(std::cout.flags());
        std::cout << "[stall ] cycle=" << cycles
                  << " no_commit=" << no_commit_cycles
                  << " fe(v/r/pc)=" << static_cast<int>(top->dbg_fe_valid_o) << "/"
                  << static_cast<int>(top->dbg_fe_ready_o) << "/0x" << std::hex
                  << top->dbg_fe_pc_o
                  << " ifu_req(v/r/fire/inflight)=" << std::dec
                  << static_cast<int>(top->dbg_ifu_req_valid_o) << "/"
                  << static_cast<int>(top->dbg_ifu_req_ready_o) << "/"
                  << static_cast<int>(top->dbg_ifu_req_fire_o) << "/"
                  << static_cast<int>(top->dbg_ifu_req_inflight_o)
                  << " ifu_rsp(v/cap)="
                  << static_cast<int>(top->dbg_ifu_rsp_valid_o) << "/"
                  << static_cast<int>(top->dbg_ifu_rsp_capture_o)
                  << " ifu_fq(cnt/full/empty/pop)="
                  << static_cast<uint32_t>(top->dbg_ifu_fq_count_o) << "/"
                  << static_cast<int>(top->dbg_ifu_fq_full_o) << "/"
                  << static_cast<int>(top->dbg_ifu_fq_empty_o) << "/"
                  << static_cast<int>(top->dbg_ifu_ibuf_pop_o)
                  << " dec(v/r)=" << std::dec << static_cast<int>(top->dbg_dec_valid_o) << "/"
                  << static_cast<int>(top->dbg_dec_ready_o)
                  << " rob_ready=" << static_cast<int>(top->dbg_rob_ready_o)
                  << " ren(pend/src/sel/fire/rdy)="
                  << static_cast<int>(top->dbg_ren_src_from_pending_o) << "/"
                  << static_cast<uint32_t>(top->dbg_ren_src_count_o) << "/"
                  << static_cast<uint32_t>(top->dbg_ren_sel_count_o) << "/"
                  << static_cast<int>(top->dbg_ren_fire_o) << "/"
                  << static_cast<int>(top->dbg_ren_ready_o)
                  << " gate(alu/bru/lsu/mdu/csr)="
                  << static_cast<int>(top->dbg_gate_alu_o) << "/"
                  << static_cast<int>(top->dbg_gate_bru_o) << "/"
                  << static_cast<int>(top->dbg_gate_lsu_o) << "/"
                  << static_cast<int>(top->dbg_gate_mdu_o) << "/"
                  << static_cast<int>(top->dbg_gate_csr_o)
                  << " need(alu/bru/lsu/mdu/csr)="
                  << static_cast<uint32_t>(top->dbg_need_alu_o) << "/"
                  << static_cast<uint32_t>(top->dbg_need_bru_o) << "/"
                  << static_cast<uint32_t>(top->dbg_need_lsu_o) << "/"
                  << static_cast<uint32_t>(top->dbg_need_mdu_o) << "/"
                  << static_cast<uint32_t>(top->dbg_need_csr_o)
                  << " free(alu/bru/lsu/csr)="
                  << static_cast<uint32_t>(top->dbg_free_alu_o) << "/"
                  << static_cast<uint32_t>(top->dbg_free_bru_o) << "/"
                  << static_cast<uint32_t>(top->dbg_free_lsu_o) << "/"
                  << static_cast<uint32_t>(top->dbg_free_csr_o)
                  << " lsu_ld(v/r/addr)=" << static_cast<int>(top->dbg_lsu_ld_req_valid_o) << "/"
                  << static_cast<int>(top->dbg_lsu_ld_req_ready_o) << "/0x" << std::hex
                  << top->dbg_lsu_ld_req_addr_o
                  << " lsu_rsp(v/r)=" << std::dec << static_cast<int>(top->dbg_lsu_ld_rsp_valid_o)
                  << "/" << static_cast<int>(top->dbg_lsu_ld_rsp_ready_o)
                  << " lsu_sm=" << static_cast<uint32_t>(top->dbg_lsu_state_o)
                  << " lsu_ld_fire=" << static_cast<int>(top->dbg_lsu_ld_fire_o)
                  << " lsu_rsp_fire=" << static_cast<int>(top->dbg_lsu_rsp_fire_o)
                  << " lsu_inflight(tag/addr)=0x" << std::hex
                  << static_cast<uint32_t>(top->dbg_lsu_inflight_tag_o)
                  << "/0x" << top->dbg_lsu_inflight_addr_o
                  << " lsug(busy/alloc_fire/alloc_lane/ld_owner)=0x"
                  << static_cast<uint32_t>(top->dbg_lsu_grp_lane_busy_o)
                  << std::dec << "/" << static_cast<int>(top->dbg_lsu_grp_alloc_fire_o)
                  << "/0x" << std::hex << static_cast<uint32_t>(top->dbg_lsu_grp_alloc_lane_o)
                  << "/0x" << static_cast<uint32_t>(top->dbg_lsu_grp_ld_owner_o)
                  << " lsu_rs(b/r)=0x" << std::hex
                  << static_cast<uint32_t>(top->dbg_lsu_rs_busy_o) << "/0x"
                  << static_cast<uint32_t>(top->dbg_lsu_rs_ready_o)
                  << " lsu_rs_head(v/idx/dst)=" << std::dec
                  << static_cast<int>(top->dbg_lsu_rs_head_valid_o) << "/0x"
                  << std::hex << static_cast<uint32_t>(top->dbg_lsu_rs_head_idx_o)
                  << "/0x" << static_cast<uint32_t>(top->dbg_lsu_rs_head_dst_o)
                  << " lsu_rs_head(rs1r/rs2r/has1/has2)=" << std::dec
                  << static_cast<int>(top->dbg_lsu_rs_head_r1_ready_o) << "/"
                  << static_cast<int>(top->dbg_lsu_rs_head_r2_ready_o) << "/"
                  << static_cast<int>(top->dbg_lsu_rs_head_has_rs1_o) << "/"
                  << static_cast<int>(top->dbg_lsu_rs_head_has_rs2_o)
                  << " lsu_rs_head(q1/q2/sb)=0x" << std::hex
                  << static_cast<uint32_t>(top->dbg_lsu_rs_head_q1_o) << "/0x"
                  << static_cast<uint32_t>(top->dbg_lsu_rs_head_q2_o) << "/0x"
                  << static_cast<uint32_t>(top->dbg_lsu_rs_head_sb_id_o)
                  << " lsu_rs_head(ld/st)=" << std::dec
                  << static_cast<int>(top->dbg_lsu_rs_head_is_load_o) << "/"
                  << static_cast<int>(top->dbg_lsu_rs_head_is_store_o)
                  << " sb_alloc(req/ready/fire)=0x" << std::hex
                  << static_cast<uint32_t>(top->dbg_sb_alloc_req_o)
                  << std::dec << "/" << static_cast<int>(top->dbg_sb_alloc_ready_o) << "/"
                  << static_cast<int>(top->dbg_sb_alloc_fire_o)
                  << " sb_dcache(v/r/addr)=" << static_cast<int>(top->dbg_sb_dcache_req_valid_o)
                  << "/" << static_cast<int>(top->dbg_sb_dcache_req_ready_o) << "/0x"
                  << std::hex << top->dbg_sb_dcache_req_addr_o
                  << " dc_mshr(cnt/full/empty)=" << std::dec
                  << static_cast<uint32_t>(top->dbg_dc_mshr_count_o) << "/"
                  << static_cast<int>(top->dbg_dc_mshr_full_o) << "/"
                  << static_cast<int>(top->dbg_dc_mshr_empty_o)
                  << " dc_mshr(alloc_rdy/line_hit)="
                  << static_cast<int>(top->dbg_dc_mshr_alloc_ready_o) << "/"
                  << static_cast<int>(top->dbg_dc_mshr_req_line_hit_o)
                  << " dc_store_wait(same/full)="
                  << static_cast<int>(top->dbg_dc_store_wait_same_line_o) << "/"
                  << static_cast<int>(top->dbg_dc_store_wait_mshr_full_o)
                  << " ic_miss(v/r)=" << std::dec
                  << static_cast<int>(top->icache_miss_req_valid_o) << "/"
                  << static_cast<int>(top->icache_miss_req_ready_i)
                  << " ic_sm=" << static_cast<uint32_t>(top->dbg_icache_state_o)
                  << " dc_miss(v/r)=" << static_cast<int>(top->dcache_miss_req_valid_o) << "/"
                  << static_cast<int>(top->dcache_miss_req_ready_i)
                  << " flush=" << static_cast<int>(top->backend_flush_o)
                  << " rdir=0x" << std::hex << top->backend_redirect_pc_o
                  << std::dec
                  << " rob_head(fu/comp/is_store/pc)=0x" << std::hex
                  << static_cast<uint32_t>(top->dbg_rob_head_fu_o)
                  << "/" << static_cast<int>(top->dbg_rob_head_complete_o)
                  << "/" << static_cast<int>(top->dbg_rob_head_is_store_o)
                  << "/0x" << top->dbg_rob_head_pc_o
                  << std::dec
                  << " rob_cnt=" << static_cast<uint32_t>(top->dbg_rob_count_o)
                  << " rob_ptr(h/t)=0x" << std::hex
                  << static_cast<uint32_t>(top->dbg_rob_head_ptr_o)
                  << "/0x" << static_cast<uint32_t>(top->dbg_rob_tail_ptr_o)
                  << std::dec
                  << " rob_q2(v/idx/fu/comp/st/pc)=" << std::dec
                  << static_cast<int>(top->dbg_rob_q2_valid_o) << "/0x"
                  << std::hex << static_cast<uint32_t>(top->dbg_rob_q2_idx_o)
                  << "/0x" << static_cast<uint32_t>(top->dbg_rob_q2_fu_o)
                  << std::dec << "/" << static_cast<int>(top->dbg_rob_q2_complete_o)
                  << "/" << static_cast<int>(top->dbg_rob_q2_is_store_o)
                  << "/0x" << std::hex << static_cast<uint32_t>(top->dbg_rob_q2_pc_o)
                  << " sb(cnt/h/t)=0x" << std::hex
                  << static_cast<uint32_t>(top->dbg_sb_count_o)
                  << "/0x" << static_cast<uint32_t>(top->dbg_sb_head_ptr_o)
                  << "/0x" << static_cast<uint32_t>(top->dbg_sb_tail_ptr_o)
                  << std::dec
                  << " sb_head(v/c/a/d/addr)="
                  << static_cast<int>(top->dbg_sb_head_valid_o) << "/"
                  << static_cast<int>(top->dbg_sb_head_committed_o) << "/"
                  << static_cast<int>(top->dbg_sb_head_addr_valid_o) << "/"
                  << static_cast<int>(top->dbg_sb_head_data_valid_o) << "/0x"
                  << std::hex << top->dbg_sb_head_addr_o
                  << std::dec << "\n";
        std::cout.flags(f);
      }
    }

    if (args.progress_interval > 0 && cycles != 0 &&
        (cycles % args.progress_interval == 0)) {
      std::ios::fmtflags f(std::cout.flags());
      std::cout << "[progress] cycle=" << cycles
                << " commits=" << total_commits
                << " no_commit=" << no_commit_cycles
                << " last_pc=0x" << std::hex << last_commit_pc
                << " last_inst=0x" << last_commit_inst
                << " a0=0x" << rf[10]
                << " rob_head(pc/comp/is_store/fu)=0x" << top->dbg_rob_head_pc_o
                << "/" << std::dec
                << static_cast<int>(top->dbg_rob_head_complete_o) << "/"
                << static_cast<int>(top->dbg_rob_head_is_store_o) << "/0x"
                << std::hex << static_cast<uint32_t>(top->dbg_rob_head_fu_o)
                << " rob_cnt=" << std::dec
                << static_cast<uint32_t>(top->dbg_rob_count_o)
                << " rob_ptr(h/t)=0x" << std::hex
                << static_cast<uint32_t>(top->dbg_rob_head_ptr_o)
                << "/0x" << static_cast<uint32_t>(top->dbg_rob_tail_ptr_o)
                << std::dec
                << " rob_q2(v/idx/fu/comp/st/pc)=" << std::dec
                << static_cast<int>(top->dbg_rob_q2_valid_o) << "/0x"
                << std::hex << static_cast<uint32_t>(top->dbg_rob_q2_idx_o)
                << "/0x" << static_cast<uint32_t>(top->dbg_rob_q2_fu_o)
                << std::dec << "/" << static_cast<int>(top->dbg_rob_q2_complete_o)
                << "/" << static_cast<int>(top->dbg_rob_q2_is_store_o)
                << "/0x" << std::hex << static_cast<uint32_t>(top->dbg_rob_q2_pc_o)
                << " sb(cnt/h/t)=0x" << std::hex
                << static_cast<uint32_t>(top->dbg_sb_count_o)
                << "/0x" << static_cast<uint32_t>(top->dbg_sb_head_ptr_o)
                << "/0x" << static_cast<uint32_t>(top->dbg_sb_tail_ptr_o)
                << " sb_head(v/c/a/d/addr)=" << std::dec
                << static_cast<int>(top->dbg_sb_head_valid_o) << "/"
                << static_cast<int>(top->dbg_sb_head_committed_o) << "/"
                << static_cast<int>(top->dbg_sb_head_addr_valid_o) << "/"
                << static_cast<int>(top->dbg_sb_head_data_valid_o) << "/0x"
                << std::hex << top->dbg_sb_head_addr_o
                << " sb_dcache(v/r/addr)= " << std::dec
                << static_cast<int>(top->dbg_sb_dcache_req_valid_o) << "/"
                << static_cast<int>(top->dbg_sb_dcache_req_ready_o) << "/0x"
                << std::hex << top->dbg_sb_dcache_req_addr_o
                << " dc_mshr(cnt/full/empty)=" << std::dec
                << static_cast<uint32_t>(top->dbg_dc_mshr_count_o) << "/"
                << static_cast<int>(top->dbg_dc_mshr_full_o) << "/"
                << static_cast<int>(top->dbg_dc_mshr_empty_o)
                << " dc_mshr(alloc_rdy/line_hit)="
                << static_cast<int>(top->dbg_dc_mshr_alloc_ready_o) << "/"
                << static_cast<int>(top->dbg_dc_mshr_req_line_hit_o)
                << " dc_store_wait(same/full)="
                << static_cast<int>(top->dbg_dc_store_wait_same_line_o) << "/"
                << static_cast<int>(top->dbg_dc_store_wait_mshr_full_o)
                << " lsu_issue(v/r)=" << std::dec
                << static_cast<int>(top->dbg_lsu_issue_valid_o) << "/"
                << static_cast<int>(top->dbg_lsu_req_ready_o)
                << " lsu_issue_ready=" << static_cast<int>(top->dbg_lsu_issue_ready_o)
                << " lsu_free=" << static_cast<uint32_t>(top->dbg_lsu_free_count_o)
                << " lsu_rs(b/r)=0x" << std::hex
                << static_cast<uint32_t>(top->dbg_lsu_rs_busy_o) << "/0x"
                << static_cast<uint32_t>(top->dbg_lsu_rs_ready_o)
                << " lsu_rs_head(v/idx/dst)=" << std::dec
                << static_cast<int>(top->dbg_lsu_rs_head_valid_o) << "/0x"
                << std::hex << static_cast<uint32_t>(top->dbg_lsu_rs_head_idx_o)
                << "/0x" << static_cast<uint32_t>(top->dbg_lsu_rs_head_dst_o)
                << " lsu_rs_head(rs1r/rs2r/has1/has2)=" << std::dec
                << static_cast<int>(top->dbg_lsu_rs_head_r1_ready_o) << "/"
                << static_cast<int>(top->dbg_lsu_rs_head_r2_ready_o) << "/"
                << static_cast<int>(top->dbg_lsu_rs_head_has_rs1_o) << "/"
                << static_cast<int>(top->dbg_lsu_rs_head_has_rs2_o)
                << " lsu_rs_head(q1/q2/sb)=0x" << std::hex
                << static_cast<uint32_t>(top->dbg_lsu_rs_head_q1_o) << "/0x"
                << static_cast<uint32_t>(top->dbg_lsu_rs_head_q2_o) << "/0x"
                << static_cast<uint32_t>(top->dbg_lsu_rs_head_sb_id_o)
                << " lsu_rs_head(ld/st)=" << std::dec
                << static_cast<int>(top->dbg_lsu_rs_head_is_load_o) << "/"
                << static_cast<int>(top->dbg_lsu_rs_head_is_store_o)
                << " lsu_ld(v/r/rsp)="
                << static_cast<int>(top->dbg_lsu_ld_req_valid_o) << "/"
                << static_cast<int>(top->dbg_lsu_ld_req_ready_o) << "/"
                << static_cast<int>(top->dbg_lsu_ld_rsp_valid_o)
                << " flush=" << static_cast<int>(top->backend_flush_o)
                << " dc_miss(v/r)="
                << static_cast<int>(top->dcache_miss_req_valid_o) << "/"
                << static_cast<int>(top->dcache_miss_req_ready_i)
                << std::dec << "\n";
      std::cout.flags(f);
    }

    if (args.fe_trace && top->dbg_fe_valid_o && top->dbg_fe_ready_o) {
      uint32_t base_pc = top->dbg_fe_pc_o;
      uint32_t mismatch_mask = 0;
      std::array<uint32_t, 4> fe_instrs{};
      std::array<uint32_t, 4> mem_instrs{};
      uint32_t slot_valid = static_cast<uint32_t>(top->dbg_fe_slot_valid_o) & 0xFu;
      for (int i = 0; i < 4; i++) {
        fe_instrs[i] = top->dbg_fe_instrs_o[i];
        mem_instrs[i] = mem.mem.read_word(base_pc + static_cast<uint32_t>(i * 4));
        if (fe_instrs[i] != mem_instrs[i]) {
          mismatch_mask |= (1u << i);
        }
      }
      if (mismatch_mask != 0 || slot_valid != 0xFu) {
        std::ios::fmtflags f(std::cout.flags());
        std::cout << "[fe   ] cycle=" << cycles
                  << " pc=0x" << std::hex << base_pc
                  << " slot_valid=0x" << slot_valid
                  << " mismatch=0x" << mismatch_mask
                  << " pred={";
        for (int i = 0; i < 4; i++) {
          if (i) std::cout << ",";
          std::cout << "0x" << static_cast<uint32_t>(top->dbg_fe_pred_npc_o[i]);
        }
        std::cout << "}"
                  << " fe={";
        for (int i = 0; i < 4; i++) {
          if (i) std::cout << ",";
          std::cout << "0x" << fe_instrs[i];
        }
        std::cout << "} mem={";
        for (int i = 0; i < 4; i++) {
          if (i) std::cout << ",";
          std::cout << "0x" << mem_instrs[i];
        }
        std::cout << "}" << std::dec << "\n";
        std::cout.flags(f);
      }
    }
  }

  std::cerr << "TIMEOUT after " << args.max_cycles << " cycles\n";
  emit_profile_summary(args.max_cycles);
  if (tfp) tfp->close();
  delete top;
  return 1;
}
