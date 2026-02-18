#include "Vtb_backend.h"
#include "verilated.h"
#include <array>
#include <cassert>
#include <cstdint>
#include <cstdlib>
#include <functional>
#include <iostream>
#include <vector>

#define ANSI_RES_GRN "\x1b[32m"
#define ANSI_RES_RED "\x1b[31m"
#define ANSI_RES_RST "\x1b[0m"

static const int INSTR_PER_FETCH = 4;
static const int NRET = 4;
static const int XLEN = 32;
static const uint32_t LINE_BYTES = 32; // DCACHE_LINE_WIDTH=256b -> 32B

// -----------------------------------------------------------------------------
// Instruction encoders (RV32I)
// -----------------------------------------------------------------------------
static inline uint32_t enc_r(uint32_t funct7, uint32_t rs2, uint32_t rs1,
                             uint32_t funct3, uint32_t rd, uint32_t opcode) {
  return (funct7 << 25) | (rs2 << 20) | (rs1 << 15) | (funct3 << 12) |
         (rd << 7) | opcode;
}

static inline uint32_t enc_i(int32_t imm, uint32_t rs1, uint32_t funct3,
                             uint32_t rd, uint32_t opcode) {
  uint32_t imm12 = static_cast<uint32_t>(imm) & 0xFFF;
  return (imm12 << 20) | (rs1 << 15) | (funct3 << 12) | (rd << 7) | opcode;
}

static inline uint32_t enc_s(int32_t imm, uint32_t rs2, uint32_t rs1,
                             uint32_t funct3, uint32_t opcode) {
  uint32_t imm12 = static_cast<uint32_t>(imm) & 0xFFF;
  uint32_t imm11_5 = (imm12 >> 5) & 0x7F;
  uint32_t imm4_0 = imm12 & 0x1F;
  return (imm11_5 << 25) | (rs2 << 20) | (rs1 << 15) | (funct3 << 12) |
         (imm4_0 << 7) | opcode;
}

static inline uint32_t enc_b(int32_t imm, uint32_t rs2, uint32_t rs1,
                             uint32_t funct3, uint32_t opcode) {
  uint32_t imm13 = static_cast<uint32_t>(imm) & 0x1FFF; // 13-bit
  uint32_t bit12 = (imm13 >> 12) & 0x1;
  uint32_t bit11 = (imm13 >> 11) & 0x1;
  uint32_t bits10_5 = (imm13 >> 5) & 0x3F;
  uint32_t bits4_1 = (imm13 >> 1) & 0xF;
  return (bit12 << 31) | (bits10_5 << 25) | (rs2 << 20) | (rs1 << 15) |
         (funct3 << 12) | (bits4_1 << 8) | (bit11 << 7) | opcode;
}

static inline uint32_t enc_j(int32_t imm, uint32_t rd, uint32_t opcode) {
  uint32_t imm21 = static_cast<uint32_t>(imm) & 0x1FFFFF; // 21-bit
  uint32_t bit20 = (imm21 >> 20) & 0x1;
  uint32_t bits10_1 = (imm21 >> 1) & 0x3FF;
  uint32_t bit11 = (imm21 >> 11) & 0x1;
  uint32_t bits19_12 = (imm21 >> 12) & 0xFF;
  return (bit20 << 31) | (bits19_12 << 12) | (bit11 << 20) |
         (bits10_1 << 21) | (rd << 7) | opcode;
}

static inline uint32_t insn_addi(uint32_t rd, uint32_t rs1, int32_t imm) {
  return enc_i(imm, rs1, 0x0, rd, 0x13);
}

static inline uint32_t insn_add(uint32_t rd, uint32_t rs1, uint32_t rs2) {
  return enc_r(0x00, rs2, rs1, 0x0, rd, 0x33);
}

static inline uint32_t insn_lw(uint32_t rd, uint32_t rs1, int32_t imm) {
  return enc_i(imm, rs1, 0x2, rd, 0x03);
}

static inline uint32_t insn_sw(uint32_t rs2, uint32_t rs1, int32_t imm) {
  return enc_s(imm, rs2, rs1, 0x2, 0x23);
}

static inline uint32_t insn_beq(uint32_t rs1, uint32_t rs2, int32_t imm) {
  return enc_b(imm, rs2, rs1, 0x0, 0x63);
}

static inline uint32_t insn_jal(uint32_t rd, int32_t imm) {
  return enc_j(imm, rd, 0x6F);
}

static inline uint32_t insn_jalr(uint32_t rd, uint32_t rs1, int32_t imm) {
  return enc_i(imm, rs1, 0x0, rd, 0x67);
}

static inline uint32_t insn_nop() { return insn_addi(0, 0, 0); }

// -----------------------------------------------------------------------------
// Memory model for D$ miss/refill
// -----------------------------------------------------------------------------
struct MemModel {
  bool pending = false;
  int delay = 0;
  uint32_t miss_addr = 0;
  uint32_t miss_way = 0;
  uint32_t pattern = 0;
  bool refill_pulse = false;

  void reset() {
    pending = false;
    delay = 0;
    miss_addr = 0;
    miss_way = 0;
    pattern = 0;
    refill_pulse = false;
  }

  static uint32_t make_pattern(uint32_t line_addr) {
    return 0xA5A50000u ^ (line_addr & 0xFFFFu);
  }

  void drive(Vtb_backend *top) {
    top->dcache_miss_req_ready_i = 1;
    top->dcache_wb_req_ready_i = 1;

    if (refill_pulse) {
      top->dcache_refill_valid_i = 1;
      top->dcache_refill_paddr_i = miss_addr;
      top->dcache_refill_way_i = miss_way;
      for (int i = 0; i < 8; i++) {
        top->dcache_refill_data_i[i] = pattern;
      }
    } else {
      top->dcache_refill_valid_i = 0;
      top->dcache_refill_paddr_i = 0;
      top->dcache_refill_way_i = 0;
      for (int i = 0; i < 8; i++) {
        top->dcache_refill_data_i[i] = 0;
      }
    }
  }

  void observe(Vtb_backend *top) {
    if (refill_pulse) {
      refill_pulse = false; // one-cycle pulse
    }

    if (!pending && top->dcache_miss_req_valid_o) {
      pending = true;
      delay = 2;
      miss_addr = top->dcache_miss_req_paddr_o;
      miss_way = top->dcache_miss_req_victim_way_o;
      pattern = make_pattern(miss_addr);
    }

    if (pending) {
      if (delay > 0) {
        delay--;
      } else if (top->dcache_refill_ready_o) {
        refill_pulse = true;
        pending = false;
      }
    }
  }
};

// -----------------------------------------------------------------------------
// Test helpers
// -----------------------------------------------------------------------------
static void tick(Vtb_backend *top, MemModel &mem) {
  mem.drive(top);
  top->clk_i = 0;
  top->eval();
  top->clk_i = 1;
  top->eval();
  mem.observe(top);
}

static bool tick_sample_frontend_ready(Vtb_backend *top, MemModel &mem) {
  mem.drive(top);
  top->clk_i = 0;
  top->eval();
  bool ready = top->frontend_ibuf_ready;
  top->clk_i = 1;
  top->eval();
  mem.observe(top);
  return ready;
}

static void reset(Vtb_backend *top, MemModel &mem) {
  top->rst_ni = 0;
  top->flush_from_backend = 0;
  top->frontend_ibuf_valid = 0;
  top->frontend_ibuf_pc = 0;
  for (int i = 0; i < INSTR_PER_FETCH; i++) {
    top->frontend_ibuf_instrs[i] = 0;
    top->frontend_ibuf_pred_npc[i] = 0;
  }
  top->frontend_ibuf_slot_valid = 0;

  mem.reset();
  tick(top, mem);
  tick(top, mem);
  top->rst_ni = 1;
  tick(top, mem);
}

static void update_commits(Vtb_backend *top, std::array<uint32_t, 32> &rf,
                           std::vector<uint32_t> &commit_log) {
  for (int i = 0; i < NRET; i++) {
    bool valid = (top->commit_valid_o >> i) & 0x1;
    bool we = (top->commit_we_o >> i) & 0x1;
    uint32_t rd = (top->commit_areg_o >> (i * 5)) & 0x1F;
    uint32_t data = top->commit_wdata_o[i];
    if (valid) {
      commit_log.push_back(rd);
      if (we && rd != 0) {
        rf[rd] = data;
      }
    }
  }
}

static void send_group(Vtb_backend *top, MemModel &mem,
                       std::array<uint32_t, 32> &rf,
                       std::vector<uint32_t> &commit_log,
                       uint32_t base_pc,
                       const std::array<uint32_t, 4> &instrs) {
  bool sent = false;
  while (!sent) {
    top->frontend_ibuf_valid = 1;
    top->frontend_ibuf_pc = base_pc;
    top->frontend_ibuf_slot_valid = 0;
    for (int i = 0; i < INSTR_PER_FETCH; i++) {
      top->frontend_ibuf_instrs[i] = instrs[i];
      top->frontend_ibuf_slot_valid |= (1u << i);
      top->frontend_ibuf_pred_npc[i] = base_pc + static_cast<uint32_t>((i + 1) * 4);
    }
    bool ready = tick_sample_frontend_ready(top, mem);
    update_commits(top, rf, commit_log);
    if (ready) {
      sent = true;
    }
  }
  top->frontend_ibuf_valid = 0;
}

static void send_group_with_pred(Vtb_backend *top, MemModel &mem,
                                 std::array<uint32_t, 32> &rf,
                                 std::vector<uint32_t> &commit_log,
                                 uint32_t base_pc,
                                 const std::array<uint32_t, 4> &instrs,
                                 const std::array<uint32_t, 4> &pred_npcs,
                                 bool *flush_seen = nullptr) {
  bool sent = false;
  while (!sent) {
    top->frontend_ibuf_valid = 1;
    top->frontend_ibuf_pc = base_pc;
    top->frontend_ibuf_slot_valid = 0;
    for (int i = 0; i < INSTR_PER_FETCH; i++) {
      top->frontend_ibuf_instrs[i] = instrs[i];
      top->frontend_ibuf_slot_valid |= (1u << i);
      top->frontend_ibuf_pred_npc[i] = pred_npcs[i];
    }
    bool ready = tick_sample_frontend_ready(top, mem);
    if (flush_seen && top->rob_flush_o) {
      *flush_seen = true;
    }
    update_commits(top, rf, commit_log);
    if (ready) {
      sent = true;
    }
  }
  top->frontend_ibuf_valid = 0;
}

static bool run_until(Vtb_backend *top, MemModel &mem,
                      std::array<uint32_t, 32> &rf,
                      std::vector<uint32_t> &commit_log,
                      const std::function<bool()> &pred, int max_cycles) {
  for (int i = 0; i < max_cycles; i++) {
    tick(top, mem);
    update_commits(top, rf, commit_log);
    if (pred()) return true;
  }
  return false;
}

static void expect(bool cond, const char *msg) {
  if (!cond) {
    std::cout << "[ " << ANSI_RES_RED << "FAIL" << ANSI_RES_RST << " ] " << msg << "\n";
    std::exit(1);
  }
  std::cout << "[ " << ANSI_RES_GRN << "PASS" << ANSI_RES_RST << " ] " << msg << "\n";
}

// -----------------------------------------------------------------------------
// Tests
// -----------------------------------------------------------------------------
static void test_alu_and_deps(Vtb_backend *top, MemModel &mem) {
  std::array<uint32_t, 32> rf{};
  std::vector<uint32_t> commits;

  reset(top, mem);

  std::array<uint32_t, 4> group = {
      insn_addi(1, 0, 5),      // x1 = 5
      insn_addi(2, 1, 3),      // x2 = x1 + 3
      insn_add(3, 1, 2),       // x3 = x1 + x2
      insn_nop()};
  send_group(top, mem, rf, commits, 0x8000, group);

  bool ok = run_until(top, mem, rf, commits, [&]() {
    return (rf[1] == 5 && rf[2] == 8 && rf[3] == 13);
  }, 200);

  expect(ok, "ALU/RAW dependency commit");
}

static void test_branch_flush(Vtb_backend *top, MemModel &mem) {
  std::array<uint32_t, 32> rf{};
  std::vector<uint32_t> commits;

  reset(top, mem);

  std::array<uint32_t, 4> group = {
      insn_addi(1, 0, 1),      // x1 = 1
      insn_beq(0, 0, 8),       // taken, target = pc+8
      insn_addi(2, 0, 2),      // wrong-path
      insn_addi(3, 0, 3)       // wrong-path (will re-fetch)
  };
  send_group(top, mem, rf, commits, 0x8000, group);

  bool flush_seen = false;
  bool wrong_commit = false;
  int bpu_update_count = 0;
  uint32_t first_update_pc = 0;
  uint32_t first_update_target = 0;
  bool first_update_is_cond = false;
  bool first_update_taken = false;

  for (int i = 0; i < 200; i++) {
    tick(top, mem);
    update_commits(top, rf, commits);
    if (top->rob_flush_o) flush_seen = true;
    if (top->bpu_update_valid_o) {
      bpu_update_count++;
      if (bpu_update_count == 1) {
        first_update_pc = top->bpu_update_pc_o;
        first_update_target = top->bpu_update_target_o;
        first_update_is_cond = top->bpu_update_is_cond_o;
        first_update_taken = top->bpu_update_taken_o;
      }
    }

    // Any commit to x2/x3 before re-fetch is wrong
    for (uint32_t rd : commits) {
      if (rd == 2 || rd == 3) {
        wrong_commit = true;
        break;
      }
    }
    commits.clear();

    if (flush_seen) break;
  }

  expect(flush_seen, "Branch mispred flush asserted");
  expect(!wrong_commit, "Wrong-path instructions not committed before re-fetch");

  // Re-fetch correct-path instruction at target PC (0x8000 + 12)
  std::array<uint32_t, 4> group2 = {
      insn_addi(3, 0, 3),
      insn_nop(),
      insn_nop(),
      insn_nop()};
  send_group(top, mem, rf, commits, 0x800C, group2);

  bool ok = false;
  for (int i = 0; i < 200; i++) {
    tick(top, mem);
    update_commits(top, rf, commits);
    if (top->bpu_update_valid_o) {
      bpu_update_count++;
    }
    if (rf[1] == 1 && rf[2] == 0 && rf[3] == 3) {
      ok = true;
      break;
    }
  }

  if (!ok) {
    std::cout << "    [DEBUG] rf1=" << rf[1] << " rf2=" << rf[2] << " rf3=" << rf[3] << std::endl;
    std::cout << "    [DEBUG] commits:";
    for (auto rd : commits) std::cout << " x" << rd;
    std::cout << std::endl;
  }
  expect(ok, "Branch flush + correct-path commit");
  expect(bpu_update_count == 1, "Commit-time predictor update asserted exactly once");
  expect(first_update_pc == 0x8004, "Predictor update PC matches committed branch PC");
  expect(first_update_target == 0x800C, "Predictor update target matches branch target");
  expect(first_update_is_cond, "Predictor update marks conditional branch");
  expect(first_update_taken, "Predictor update marks taken branch");
}

static void test_store_load_forward(Vtb_backend *top, MemModel &mem) {
  std::array<uint32_t, 32> rf{};
  std::vector<uint32_t> commits;

  reset(top, mem);

  std::array<uint32_t, 4> group = {
      insn_addi(5, 0, 0x7F),   // x5 = 0x7F
      insn_sw(5, 0, 0),        // MEM[0] = x5
      insn_lw(6, 0, 0),        // x6 = MEM[0] (forwarded)
      insn_nop()};
  send_group(top, mem, rf, commits, 0x9000, group);

  bool ok = run_until(top, mem, rf, commits, [&]() {
    return rf[6] == 0x7F;
  }, 300);

  expect(ok, "Store -> Load forwarding");
}

static void test_load_miss_refill(Vtb_backend *top, MemModel &mem) {
  std::array<uint32_t, 32> rf{};
  std::vector<uint32_t> commits;

  reset(top, mem);

  uint32_t addr = 0x100;
  uint32_t line_addr = addr & ~(LINE_BYTES - 1);
  uint32_t expected = MemModel::make_pattern(line_addr);

  std::array<uint32_t, 4> group = {
      insn_lw(10, 0, addr),
      insn_nop(),
      insn_nop(),
      insn_nop()};
  send_group(top, mem, rf, commits, 0xA000, group);

  bool ok = run_until(top, mem, rf, commits, [&]() {
    return rf[10] == expected;
  }, 400);

  expect(ok, "Load miss -> refill -> commit");
}

static void test_call_ret_update(Vtb_backend *top, MemModel &mem) {
  std::array<uint32_t, 32> rf{};
  std::vector<uint32_t> commits;

  reset(top, mem);

  // JAL x1, +8  (call)
  send_group(top, mem, rf, commits, 0xB000,
             {insn_jal(1, 8), insn_nop(), insn_nop(), insn_nop()});

  bool call_seen = false;
  bool call_flag_ok = false;
  bool call_ras_seen = false;
  bool call_ras_flag_ok = false;
  for (int i = 0; i < 200; i++) {
    tick(top, mem);
    update_commits(top, rf, commits);
    if (top->bpu_update_valid_o && top->bpu_update_pc_o == 0xB000) {
      call_seen = true;
      call_flag_ok = (top->bpu_update_is_call_o == 1) &&
                     (top->bpu_update_is_ret_o == 0);
    }
    for (int slot = 0; slot < NRET; slot++) {
      bool ras_v = (top->bpu_ras_update_valid_o >> slot) & 0x1;
      if (ras_v && top->bpu_ras_update_pc_o[slot] == 0xB000) {
        call_ras_seen = true;
        call_ras_flag_ok = (((top->bpu_ras_update_is_call_o >> slot) & 0x1) == 1) &&
                           (((top->bpu_ras_update_is_ret_o >> slot) & 0x1) == 0);
      }
    }
    if (call_seen && call_ras_seen) {
      break;
    }
  }

  // JALR x0, x1, 0 (return)
  send_group(top, mem, rf, commits, 0xB008,
             {insn_jalr(0, 1, 0), insn_nop(), insn_nop(), insn_nop()});

  bool ret_seen = false;
  bool ret_flag_ok = false;
  bool ret_ras_seen = false;
  bool ret_ras_flag_ok = false;
  for (int i = 0; i < 200; i++) {
    tick(top, mem);
    update_commits(top, rf, commits);
    if (top->bpu_update_valid_o && top->bpu_update_pc_o == 0xB008) {
      ret_seen = true;
      ret_flag_ok = (top->bpu_update_is_call_o == 0) &&
                    (top->bpu_update_is_ret_o == 1);
    }
    for (int slot = 0; slot < NRET; slot++) {
      bool ras_v = (top->bpu_ras_update_valid_o >> slot) & 0x1;
      if (ras_v && top->bpu_ras_update_pc_o[slot] == 0xB008) {
        ret_ras_seen = true;
        ret_ras_flag_ok = (((top->bpu_ras_update_is_call_o >> slot) & 0x1) == 0) &&
                          (((top->bpu_ras_update_is_ret_o >> slot) & 0x1) == 1);
      }
    }
    if (ret_seen && ret_ras_seen) {
      break;
    }
  }

  expect(call_seen, "Call update observed at JAL commit");
  expect(call_flag_ok, "Call update carries is_call=1 is_ret=0");
  expect(call_ras_seen, "Call RAS batch update observed at JAL commit");
  expect(call_ras_flag_ok, "Call RAS batch update carries is_call=1 is_ret=0");
  expect(ret_seen, "Return update observed at JALR commit");
  expect(ret_flag_ok, "Return update carries is_call=0 is_ret=1");
  expect(ret_ras_seen, "Return RAS batch update observed at JALR commit");
  expect(ret_ras_flag_ok, "Return RAS batch update carries is_call=0 is_ret=1");
}

static void test_flush_stress_no_wrong_path_commit(Vtb_backend *top, MemModel &mem) {
  std::array<uint32_t, 32> rf{};
  std::vector<uint32_t> commits;

  reset(top, mem);

  // Group-0: slot1 is taken branch (always taken) but pred_npc is set to
  // fall-through, forcing a mispredict/flush. slot2/3 are wrong-path writes.
  const uint32_t base0 = 0xC000;
  const std::array<uint32_t, 4> g0 = {
      insn_addi(10, 10, 1),    // older-than-branch: should commit
      insn_beq(0, 0, 64),      // taken to far target
      insn_addi(2, 2, 1),      // wrong path
      insn_addi(3, 3, 1)       // wrong path
  };
  const std::array<uint32_t, 4> p0 = {
      base0 + 4, base0 + 8, base0 + 12, base0 + 16
  };

  // Group-1/2: injected quickly as additional wrong-path traffic.
  const uint32_t base1 = base0 + 16;
  const std::array<uint32_t, 4> g1 = {
      insn_addi(4, 4, 1), insn_addi(5, 5, 1), insn_addi(6, 6, 1), insn_addi(7, 7, 1)
  };
  const std::array<uint32_t, 4> p1 = {
      base1 + 4, base1 + 8, base1 + 12, base1 + 16
  };

  const uint32_t base2 = base1 + 16;
  const std::array<uint32_t, 4> g2 = {
      insn_addi(8, 8, 1), insn_addi(9, 9, 1), insn_addi(11, 11, 1), insn_addi(12, 12, 1)
  };
  const std::array<uint32_t, 4> p2 = {
      base2 + 4, base2 + 8, base2 + 12, base2 + 16
  };

  bool flush_seen = false;
  bool wrong_path_commit = false;
  send_group_with_pred(top, mem, rf, commits, base0, g0, p0, &flush_seen);
  send_group_with_pred(top, mem, rf, commits, base1, g1, p1, &flush_seen);
  send_group_with_pred(top, mem, rf, commits, base2, g2, p2, &flush_seen);

  for (int cyc = 0; cyc < 500; cyc++) {
    tick(top, mem);
    update_commits(top, rf, commits);
    if (top->rob_flush_o) {
      flush_seen = true;
    }
    for (uint32_t rd : commits) {
      if (rd == 2 || rd == 3 || rd == 4 || rd == 5 || rd == 6 || rd == 7 || rd == 8 || rd == 9 || rd == 11 ||
          rd == 12) {
        wrong_path_commit = true;
      }
    }
    commits.clear();
  }

  expect(flush_seen, "Flush stress: branch mispredict flush observed");
  expect(!wrong_path_commit, "Flush stress: wrong-path registers never committed");
  expect(rf[10] == 1, "Flush stress: older-than-branch instruction commits exactly once");
  expect(rf[2] == 0 && rf[3] == 0, "Flush stress: same-group younger writes are squashed");
  expect(rf[4] == 0 && rf[5] == 0 && rf[6] == 0 && rf[7] == 0, "Flush stress: next-group wrong-path writes are squashed");
  expect(rf[8] == 0 && rf[9] == 0 && rf[11] == 0 && rf[12] == 0,
         "Flush stress: additional wrong-path writes are squashed");
}

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  Vtb_backend *top = new Vtb_backend;
  MemModel mem;

  std::cout << "--- [START] Backend Verification ---" << std::endl;

  test_alu_and_deps(top, mem);
  test_branch_flush(top, mem);
  test_store_load_forward(top, mem);
  test_load_miss_refill(top, mem);
  test_call_ret_update(top, mem);
  test_flush_stress_no_wrong_path_commit(top, mem);

  std::cout << ANSI_RES_GRN << "--- [ALL BACKEND TESTS PASSED] ---" << ANSI_RES_RST << std::endl;
  delete top;
  return 0;
}
