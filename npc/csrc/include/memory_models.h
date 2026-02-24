#pragma once

#include "Vtb_triathlon.h"
#include "verilated.h"
#include "verilated_vcd_c.h"

#include <array>
#include <cstdint>
#include <deque>
#include <fstream>
#include <iostream>
#include <iterator>
#include <string>
#include <vector>

namespace npc {

inline constexpr uint32_t kPmemBase = 0x80000000u;
inline constexpr uint32_t kSerialPort = 0xA00003F8u;
inline constexpr uint32_t kRtcPortLow = 0xA0000048u;
inline constexpr uint32_t kRtcPortHigh = 0xA000004Cu;
inline constexpr uint32_t kPmemSize = 0x08000000u;
inline constexpr uint32_t kSeed4Addr = 0x80003C3Cu;

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
      case 7u:
        write_byte(addr, static_cast<uint8_t>(data & 0xffu));
        break;
      case 8u:
        write_half(addr, static_cast<uint16_t>(data & 0xffffu));
        break;
      case 9u:
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

inline void tick(Vtb_triathlon *top, MemSystem &mem, VerilatedVcdC *tfp,
                 vluint64_t &sim_time) {
  mem.drive(top);
  top->clk_i = 0;
  top->eval();
#if VM_TRACE
  if (tfp) tfp->dump(sim_time++);
#endif
  top->clk_i = 1;
  top->eval();
#if VM_TRACE
  if (tfp) tfp->dump(sim_time++);
#endif
  mem.observe(top);
}

inline void reset(Vtb_triathlon *top, MemSystem &mem, VerilatedVcdC *tfp,
                  vluint64_t &sim_time) {
  top->rst_ni = 0;
  mem.reset();
  for (int i = 0; i < 5; i++) tick(top, mem, tfp, sim_time);
  top->rst_ni = 1;
  for (int i = 0; i < 2; i++) tick(top, mem, tfp, sim_time);
}

}  // namespace npc
