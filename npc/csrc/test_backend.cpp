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
static const int DEFAULT_FTQ_ID_BITS = 3;
static const int DEFAULT_FETCH_EPOCH_BITS = 3;

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

static inline uint32_t insn_mul(uint32_t rd, uint32_t rs1, uint32_t rs2) {
  return enc_r(0x01, rs2, rs1, 0x0, rd, 0x33);
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
  bool block_miss_req = false;

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
    top->dcache_miss_req_ready_i = block_miss_req ? 0 : 1;
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

static uint32_t pack_meta_all_lanes(uint32_t value, int lane_bits) {
  uint32_t packed = 0;
  uint32_t mask = (1u << lane_bits) - 1u;
  for (int i = 0; i < INSTR_PER_FETCH; i++) {
    packed |= static_cast<uint32_t>((value & mask) << (i * lane_bits));
  }
  return packed;
}

static void set_frontend_meta(Vtb_backend *top, uint32_t ftq_id, uint32_t fetch_epoch) {
  int ftq_id_bits = top->dbg_cfg_ftq_id_bits_o ? static_cast<int>(top->dbg_cfg_ftq_id_bits_o)
                                                : DEFAULT_FTQ_ID_BITS;
  int fetch_epoch_bits = top->dbg_cfg_fetch_epoch_bits_o ?
                             static_cast<int>(top->dbg_cfg_fetch_epoch_bits_o) :
                             DEFAULT_FETCH_EPOCH_BITS;
  top->frontend_ibuf_ftq_id = pack_meta_all_lanes(ftq_id, ftq_id_bits);
  top->frontend_ibuf_fetch_epoch = pack_meta_all_lanes(fetch_epoch, fetch_epoch_bits);
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
  set_frontend_meta(top, 0, 0);
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
                       const std::array<uint32_t, 4> &instrs,
                       uint32_t ftq_id = 0,
                       uint32_t fetch_epoch = 0) {
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
    set_frontend_meta(top, ftq_id, fetch_epoch);
    bool ready = tick_sample_frontend_ready(top, mem);
    update_commits(top, rf, commit_log);
    if (ready) {
      sent = true;
    }
  }
  top->frontend_ibuf_valid = 0;
}

static void send_group_masked(Vtb_backend *top, MemModel &mem,
                              std::array<uint32_t, 32> &rf,
                              std::vector<uint32_t> &commit_log,
                              uint32_t base_pc,
                              const std::array<uint32_t, 4> &instrs,
                              uint32_t slot_valid_mask,
                              uint32_t ftq_id = 0,
                              uint32_t fetch_epoch = 0) {
  bool sent = false;
  while (!sent) {
    top->frontend_ibuf_valid = 1;
    top->frontend_ibuf_pc = base_pc;
    top->frontend_ibuf_slot_valid = 0;
    for (int i = 0; i < INSTR_PER_FETCH; i++) {
      top->frontend_ibuf_instrs[i] = instrs[i];
      if ((slot_valid_mask >> i) & 0x1u) {
        top->frontend_ibuf_slot_valid |= (1u << i);
      }
      top->frontend_ibuf_pred_npc[i] = base_pc + static_cast<uint32_t>((i + 1) * 4);
    }
    set_frontend_meta(top, ftq_id, fetch_epoch);
    bool ready = tick_sample_frontend_ready(top, mem);
    update_commits(top, rf, commit_log);
    if (ready) {
      sent = true;
    }
  }
  top->frontend_ibuf_valid = 0;
}

static bool try_send_group_limited(Vtb_backend *top, MemModel &mem,
                                   std::array<uint32_t, 32> &rf,
                                   std::vector<uint32_t> &commit_log,
                                   uint32_t base_pc,
                                   const std::array<uint32_t, 4> &instrs,
                                   int max_cycles,
                                   uint32_t ftq_id = 0,
                                   uint32_t fetch_epoch = 0) {
  for (int cyc = 0; cyc < max_cycles; cyc++) {
    top->frontend_ibuf_valid = 1;
    top->frontend_ibuf_pc = base_pc;
    top->frontend_ibuf_slot_valid = 0;
    for (int i = 0; i < INSTR_PER_FETCH; i++) {
      top->frontend_ibuf_instrs[i] = instrs[i];
      top->frontend_ibuf_slot_valid |= (1u << i);
      top->frontend_ibuf_pred_npc[i] = base_pc + static_cast<uint32_t>((i + 1) * 4);
    }
    set_frontend_meta(top, ftq_id, fetch_epoch);
    bool ready = tick_sample_frontend_ready(top, mem);
    update_commits(top, rf, commit_log);
    if (ready) {
      top->frontend_ibuf_valid = 0;
      return true;
    }
  }
  top->frontend_ibuf_valid = 0;
  return false;
}

static bool try_send_group_masked_limited(Vtb_backend *top, MemModel &mem,
                                          std::array<uint32_t, 32> &rf,
                                          std::vector<uint32_t> &commit_log,
                                          uint32_t base_pc,
                                          const std::array<uint32_t, 4> &instrs,
                                          uint32_t slot_valid_mask,
                                          int max_cycles,
                                          uint32_t ftq_id = 0,
                                          uint32_t fetch_epoch = 0) {
  for (int cyc = 0; cyc < max_cycles; cyc++) {
    top->frontend_ibuf_valid = 1;
    top->frontend_ibuf_pc = base_pc;
    top->frontend_ibuf_slot_valid = 0;
    for (int i = 0; i < INSTR_PER_FETCH; i++) {
      top->frontend_ibuf_instrs[i] = instrs[i];
      if ((slot_valid_mask >> i) & 0x1u) {
        top->frontend_ibuf_slot_valid |= (1u << i);
      }
      top->frontend_ibuf_pred_npc[i] = base_pc + static_cast<uint32_t>((i + 1) * 4);
    }
    set_frontend_meta(top, ftq_id, fetch_epoch);
    bool ready = tick_sample_frontend_ready(top, mem);
    update_commits(top, rf, commit_log);
    if (ready) {
      top->frontend_ibuf_valid = 0;
      return true;
    }
  }
  top->frontend_ibuf_valid = 0;
  return false;
}

static void send_group_with_pred(Vtb_backend *top, MemModel &mem,
                                 std::array<uint32_t, 32> &rf,
                                 std::vector<uint32_t> &commit_log,
                                 uint32_t base_pc,
                                 const std::array<uint32_t, 4> &instrs,
                                 const std::array<uint32_t, 4> &pred_npcs,
                                 bool *flush_seen = nullptr,
                                 uint32_t ftq_id = 0,
                                 uint32_t fetch_epoch = 0) {
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
    set_frontend_meta(top, ftq_id, fetch_epoch);
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

static void test_manual_flush_blocks_stale_branch_update_with_metadata(Vtb_backend *top,
                                                                       MemModel &mem) {
  std::array<uint32_t, 32> rf{};
  std::vector<uint32_t> commits;

  reset(top, mem);

  const uint32_t stale_pc = 0x8400;
  const uint32_t fresh_pc = 0x8440;
  const uint32_t stale_ftq_id = 3;
  const uint32_t stale_epoch = 1;
  const uint32_t fresh_ftq_id = 5;
  const uint32_t fresh_epoch = 2;

  const std::array<uint32_t, 4> branch_group = {
      insn_beq(0, 0, 8), insn_nop(), insn_nop(), insn_nop()};

  // Inject one branch bundle with stale metadata.
  send_group_masked(top, mem, rf, commits, stale_pc, branch_group, 0x1u, stale_ftq_id, stale_epoch);

  // Force flush before stale branch can retire.
  top->flush_from_backend = 1;
  tick(top, mem);
  update_commits(top, rf, commits);
  top->flush_from_backend = 0;

  // Inject a fresh branch bundle with new metadata.
  send_group_masked(top, mem, rf, commits, fresh_pc, branch_group, 0x1u, fresh_ftq_id, fresh_epoch);

  bool stale_update_seen = false;
  bool fresh_update_seen = false;
  bool stale_meta_seen = false;
  bool fresh_meta_seen = false;
  for (int i = 0; i < 300; i++) {
    tick(top, mem);
    update_commits(top, rf, commits);
    if (top->bpu_update_valid_o) {
      if (top->bpu_update_pc_o == stale_pc) {
        stale_update_seen = true;
      }
      if (top->bpu_update_pc_o == fresh_pc) {
        fresh_update_seen = true;
      }
      if ((top->dbg_bpu_update_ftq_id_o == stale_ftq_id) &&
          (top->dbg_bpu_update_fetch_epoch_o == stale_epoch)) {
        stale_meta_seen = true;
      }
      if ((top->dbg_bpu_update_ftq_id_o == fresh_ftq_id) &&
          (top->dbg_bpu_update_fetch_epoch_o == fresh_epoch)) {
        fresh_meta_seen = true;
      }
    }
    if (fresh_update_seen && fresh_meta_seen) break;
  }

  expect(!stale_update_seen, "Manual flush: stale pre-flush branch does not update predictor");
  expect(!stale_meta_seen, "Manual flush: stale pre-flush metadata does not update predictor");
  expect(fresh_update_seen, "Manual flush: fresh post-flush branch updates predictor");
  expect(fresh_meta_seen, "Manual flush: fresh post-flush metadata updates predictor");
}

static void test_bpu_update_metadata_aligns_with_selected_commit_slot(Vtb_backend *top,
                                                                       MemModel &mem) {
  std::array<uint32_t, 32> rf{};
  std::vector<uint32_t> commits;

  reset(top, mem);

  const uint32_t base_pc = 0x8480;
  const uint32_t ftq_id = 6;
  const uint32_t epoch = 3;
  const std::array<uint32_t, 4> group = {
      insn_addi(1, 0, 1), insn_beq(0, 0, 8), insn_nop(), insn_nop()};

  send_group_masked(top, mem, rf, commits, base_pc, group, 0x3u, ftq_id, epoch);

  bool update_seen = false;
  uint32_t sel_idx = 0;
  uint32_t update_pc = 0;
  uint32_t update_ftq = 0;
  uint32_t update_epoch = 0;
  for (int i = 0; i < 300; i++) {
    tick(top, mem);
    update_commits(top, rf, commits);
    if (top->bpu_update_valid_o) {
      update_seen = true;
      sel_idx = top->dbg_bpu_update_sel_idx_o;
      update_pc = top->bpu_update_pc_o;
      update_ftq = top->dbg_bpu_update_ftq_id_o;
      update_epoch = top->dbg_bpu_update_fetch_epoch_o;
      break;
    }
  }

  expect(update_seen, "BPU update observed for mixed commit bundle");
  expect(sel_idx == 1u, "BPU update selects the branch commit slot");
  expect(update_pc == (base_pc + 4), "BPU update PC aligns with selected commit slot");
  expect(update_ftq == ftq_id, "BPU update ftq_id aligns with selected commit slot");
  expect(update_epoch == epoch, "BPU update epoch aligns with selected commit slot");
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
  bool sent_g1_before_flush = false;
  bool sent_g2_before_flush = false;
  send_group_with_pred(top, mem, rf, commits, base0, g0, p0, &flush_seen);
  if (!flush_seen) {
    send_group_with_pred(top, mem, rf, commits, base1, g1, p1, &flush_seen);
    sent_g1_before_flush = true;
  }
  if (!flush_seen) {
    send_group_with_pred(top, mem, rf, commits, base2, g2, p2, &flush_seen);
    sent_g2_before_flush = true;
  }

  for (int cyc = 0; cyc < 500; cyc++) {
    tick(top, mem);
    update_commits(top, rf, commits);
    if (top->rob_flush_o) {
      flush_seen = true;
    }
    for (int slot = 0; slot < NRET; slot++) {
      bool v = (top->commit_valid_o >> slot) & 0x1;
      bool we = (top->commit_we_o >> slot) & 0x1;
      uint32_t rd = (top->commit_areg_o >> (slot * 5)) & 0x1F;
      bool is_wrong = (rd == 2 || rd == 3);
      if (sent_g1_before_flush) {
        is_wrong = is_wrong || (rd == 4 || rd == 5 || rd == 6 || rd == 7);
      }
      if (sent_g2_before_flush) {
        is_wrong = is_wrong || (rd == 8 || rd == 9 || rd == 11 || rd == 12);
      }
      if (v && we && is_wrong) {
        wrong_path_commit = true;
      }
    }
    commits.clear();
  }

  expect(flush_seen, "Flush stress: branch mispredict flush observed");
  expect(!wrong_path_commit, "Flush stress: wrong-path registers never committed");
  expect(rf[10] == 1, "Flush stress: older-than-branch instruction commits exactly once");
  expect(rf[2] == 0 && rf[3] == 0, "Flush stress: same-group younger writes are squashed");
  if (sent_g1_before_flush) {
    expect(rf[4] == 0 && rf[5] == 0 && rf[6] == 0 && rf[7] == 0,
           "Flush stress: next-group wrong-path writes are squashed");
  }
  if (sent_g2_before_flush) {
    expect(rf[8] == 0 && rf[9] == 0 && rf[11] == 0 && rf[12] == 0,
           "Flush stress: additional wrong-path writes are squashed");
  }
}

static void test_partial_dispatch_accepts_non_lsu_prefix_when_lsu_blocked(Vtb_backend *top, MemModel &mem) {
  std::array<uint32_t, 32> rf{};
  std::vector<uint32_t> commits;

  reset(top, mem);
  mem.block_miss_req = true;

  const std::array<uint32_t, 4> load_group = {
      insn_lw(10, 0, 0x100),
      insn_lw(11, 0, 0x104),
      insn_lw(12, 0, 0x108),
      insn_lw(13, 0, 0x10c)};

  bool saw_backpressure = false;
  int accepted_load_groups = 0;
  for (int g = 0; g < 32; g++) {
    uint32_t pc = 0xD000 + static_cast<uint32_t>(g * 16);
    bool accepted = try_send_group_limited(top, mem, rf, commits, pc, load_group, 20);
    if (!accepted) {
      saw_backpressure = true;
      break;
    }
    accepted_load_groups++;
  }
  expect(saw_backpressure || accepted_load_groups == 32,
         "LSU pressure: load-only groups either backpressure or sustain all injected groups");

  const std::array<uint32_t, 4> mixed_group = {
      insn_addi(1, 0, 1),
      insn_addi(2, 0, 2),
      insn_lw(3, 0, 0x110),
      insn_lw(4, 0, 0x114)};

  bool mixed_accepted = try_send_group_limited(top, mem, rf, commits, 0xE000, mixed_group, 40);
  expect(mixed_accepted, "Partial dispatch: mixed group accepted under LSU pressure");
  mem.block_miss_req = false;
}

static void test_dual_lane_can_hold_two_blocked_loads(Vtb_backend *top, MemModel &mem) {
  std::array<uint32_t, 32> rf{};
  std::vector<uint32_t> commits;

  reset(top, mem);
  mem.block_miss_req = true;

  send_group(top, mem, rf, commits, 0xF000,
             {insn_lw(10, 0, 0x100), insn_nop(), insn_nop(), insn_nop()});

  bool first_lane_busy = run_until(top, mem, rf, commits, [&]() {
    return (top->dbg_lsu_grp_lane_busy_o & 0x1) != 0;
  }, 200);
  expect(first_lane_busy, "Dual lane: first blocked load occupies lane0");

  send_group(top, mem, rf, commits, 0xF010,
             {insn_lw(11, 0, 0x104), insn_nop(), insn_nop(), insn_nop()});

  uint32_t max_busy_mask = 0;
  for (int i = 0; i < 200; i++) {
    tick(top, mem);
    update_commits(top, rf, commits);
    max_busy_mask |= static_cast<uint32_t>(top->dbg_lsu_grp_lane_busy_o);
  }

  expect((max_busy_mask & 0x3u) == 0x3u,
         "Dual lane: two blocked loads can occupy two lanes simultaneously");
  mem.block_miss_req = false;
}

static void test_pending_replay_allows_decoder_progress(Vtb_backend *top, MemModel &mem) {
  std::array<uint32_t, 32> rf{};
  std::vector<uint32_t> commits;

  reset(top, mem);

  // slot1 invalid forces rename stop_accept, slot2/3 replay into pending.
  // FU_MUL is currently not implemented, so pending replay remains active.
  const std::array<uint32_t, 4> replay_seed = {
      insn_addi(10, 0, 1),
      insn_nop(),
      insn_mul(11, 0, 0),
      insn_mul(12, 0, 0)};

  send_group_masked(top, mem, rf, commits, 0x11000, replay_seed, 0xDu);

  bool replay_seen = run_until(top, mem, rf, commits, [&]() {
    return top->dbg_ren_src_from_pending_o != 0;
  }, 300);
  expect(replay_seen, "Replay path: pending-replay becomes active");

  const std::array<uint32_t, 4> addi_group = {
      insn_addi(14, 0, 14),
      insn_addi(15, 0, 15),
      insn_addi(16, 0, 16),
      insn_addi(17, 0, 17)};

  int dec_ready_while_pending = 0;
  int pending_cycles = 0;
  for (int cyc = 0; cyc < 80; cyc++) {
    top->frontend_ibuf_valid = 1;
    top->frontend_ibuf_pc = 0x11010;
    top->frontend_ibuf_slot_valid = 0;
    for (int i = 0; i < INSTR_PER_FETCH; i++) {
      top->frontend_ibuf_instrs[i] = addi_group[i];
      top->frontend_ibuf_slot_valid |= (1u << i);
      top->frontend_ibuf_pred_npc[i] = top->frontend_ibuf_pc + static_cast<uint32_t>((i + 1) * 4);
    }

    mem.drive(top);
    top->clk_i = 0;
    top->eval();
    bool pending = top->dbg_ren_src_from_pending_o != 0;
    bool dec_ready = top->dbg_dec_ready_o != 0;
    uint32_t src_count = static_cast<uint32_t>(top->dbg_ren_src_count_o);
    top->clk_i = 1;
    top->eval();
    mem.observe(top);
    update_commits(top, rf, commits);

    if (pending && src_count < INSTR_PER_FETCH) {
      pending_cycles++;
    }
    if (pending && src_count < INSTR_PER_FETCH && dec_ready) {
      dec_ready_while_pending++;
      break;
    }
  }
  top->frontend_ibuf_valid = 0;

  if (dec_ready_while_pending == 0) {
    std::cout << "    [DEBUG] pending_cycles=" << pending_cycles
              << " src_count=" << static_cast<uint32_t>(top->dbg_ren_src_count_o)
              << " dec_ready=" << static_cast<int>(top->dbg_dec_ready_o)
              << " pending=" << static_cast<int>(top->dbg_ren_src_from_pending_o)
              << std::endl;
  }

  expect(dec_ready_while_pending > 0,
         "Replay path: decoder can make progress while pending replay has free slots");
}

static void test_pending_replay_buffer_can_absorb_multiple_single_slot_groups(Vtb_backend *top, MemModel &mem) {
  std::array<uint32_t, 32> rf{};
  std::vector<uint32_t> commits;

  reset(top, mem);

  const std::array<uint32_t, 4> replay_seed = {
      insn_addi(10, 0, 1),
      insn_nop(),
      insn_mul(11, 0, 0),
      insn_mul(12, 0, 0)};

  send_group_masked(top, mem, rf, commits, 0x12000, replay_seed, 0xDu);

  bool replay_seen = run_until(top, mem, rf, commits, [&]() {
    return top->dbg_ren_src_from_pending_o != 0;
  }, 200);
  expect(replay_seen, "Replay depth: pending-replay becomes active");

  int accepted_single_slot_groups = 0;
  const std::array<uint32_t, 4> one_slot_group = {
      insn_addi(20, 0, 20),
      insn_nop(),
      insn_nop(),
      insn_nop()};

  for (int g = 0; g < 6; g++) {
    uint32_t pc = 0x12010 + static_cast<uint32_t>(g * 16);
    bool accepted = try_send_group_masked_limited(
        top, mem, rf, commits, pc, one_slot_group, 0x1u, 40);
    if (!accepted) break;
    accepted_single_slot_groups++;
  }

  if (accepted_single_slot_groups < 4) {
    std::cout << "    [DEBUG] accepted_single_slot_groups=" << accepted_single_slot_groups
              << " pending=" << static_cast<int>(top->dbg_ren_src_from_pending_o)
              << " src_count=" << static_cast<uint32_t>(top->dbg_ren_src_count_o)
              << std::endl;
  }
  expect(accepted_single_slot_groups >= 4,
         "Replay depth: pending buffer absorbs >=4 single-slot groups while replay active");
}

static void test_pending_replay_buffer_depth_scales_for_single_slot_groups(Vtb_backend *top, MemModel &mem) {
  std::array<uint32_t, 32> rf{};
  std::vector<uint32_t> commits;

  reset(top, mem);

  const std::array<uint32_t, 4> replay_seed = {
      insn_addi(10, 0, 1),
      insn_nop(),
      insn_mul(11, 0, 0),
      insn_mul(12, 0, 0)};
  send_group_masked(top, mem, rf, commits, 0x13000, replay_seed, 0xDu);

  bool replay_seen = run_until(top, mem, rf, commits, [&]() {
    return top->dbg_ren_src_from_pending_o != 0;
  }, 200);
  expect(replay_seen, "Replay depth scale: pending-replay becomes active");

  const std::array<uint32_t, 4> one_slot_group = {
      insn_addi(20, 0, 20),
      insn_nop(),
      insn_nop(),
      insn_nop()};

  int accepted_single_slot_groups = 0;
  for (int g = 0; g < 12; g++) {
    uint32_t pc = 0x13010 + static_cast<uint32_t>(g * 16);
    bool accepted = try_send_group_masked_limited(
        top, mem, rf, commits, pc, one_slot_group, 0x1u, 40);
    if (!accepted) break;
    accepted_single_slot_groups++;
  }

  if (accepted_single_slot_groups < 10) {
    std::cout << "    [DEBUG] accepted_single_slot_groups=" << accepted_single_slot_groups
              << " pending=" << static_cast<int>(top->dbg_ren_src_from_pending_o)
              << " src_count=" << static_cast<uint32_t>(top->dbg_ren_src_count_o)
              << std::endl;
  }
  expect(accepted_single_slot_groups >= 10,
         "Replay depth scale: pending buffer absorbs >=10 single-slot groups while replay active");
}

static void test_memdep_violation_requests_replay_without_deadlock(Vtb_backend *top, MemModel &mem) {
  std::array<uint32_t, 32> rf{};
  std::vector<uint32_t> commits;

  reset(top, mem);

  send_group(top, mem, rf, commits, 0x14000,
             {insn_addi(1, 0, 0x100), insn_addi(2, 0, 0x55), insn_nop(), insn_nop()});
  send_group(top, mem, rf, commits, 0x14010,
             {insn_sw(2, 1, 0), insn_lw(3, 1, 0), insn_addi(4, 0, 1), insn_nop()});

  bool replay_seen = run_until(top, mem, rf, commits, [&]() {
    return top->dbg_mem_dep_replay_o != 0;
  }, 300);
  expect(replay_seen, "Mem-dep replay: violation request observed");

  bool committed_after_replay = run_until(top, mem, rf, commits, [&]() {
    for (int i = 0; i < NRET; i++) {
      if (((top->commit_valid_o >> i) & 0x1) != 0) return true;
    }
    return false;
  }, 300);
  expect(committed_after_replay, "Mem-dep replay: backend still commits after replay request");
}

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  Vtb_backend *top = new Vtb_backend;
  MemModel mem;

  std::cout << "--- [START] Backend Verification ---" << std::endl;

  test_alu_and_deps(top, mem);
  test_branch_flush(top, mem);
  test_manual_flush_blocks_stale_branch_update_with_metadata(top, mem);
  test_bpu_update_metadata_aligns_with_selected_commit_slot(top, mem);
  test_store_load_forward(top, mem);
  test_load_miss_refill(top, mem);
  test_call_ret_update(top, mem);
  test_flush_stress_no_wrong_path_commit(top, mem);
  test_partial_dispatch_accepts_non_lsu_prefix_when_lsu_blocked(top, mem);
  test_dual_lane_can_hold_two_blocked_loads(top, mem);
  test_pending_replay_allows_decoder_progress(top, mem);
  test_pending_replay_buffer_can_absorb_multiple_single_slot_groups(top, mem);
  test_pending_replay_buffer_depth_scales_for_single_slot_groups(top, mem);
  test_memdep_violation_requests_replay_without_deadlock(top, mem);

  std::cout << ANSI_RES_GRN << "--- [ALL BACKEND TESTS PASSED] ---" << ANSI_RES_RST << std::endl;
  delete top;
  return 0;
}
