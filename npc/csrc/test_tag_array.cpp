// csrc/test_tag_array.cpp
#include "Vtb_tag_array.h" // 包含 Verilator 生成的模块头文件
#include "verilated.h"
#include <cassert>
#include <iomanip> // 为了使用 std::hex 和 std::setw
#include <iostream>

// 仿真时间跟踪
vluint64_t main_time = 0;

// 时钟滴答辅助函数
void tick(Vtb_tag_array *top) {
  top->clk_i = 0;
  top->eval();
  main_time++;
  top->clk_i = 1;
  top->eval();
  main_time++;
}

// 辅助函数：从 VlWide 输出中提取指定 Way 的 Tag
// Vtb_tag_array.h 显示 rdata_tag_o 是 VL_OUTW(&rdata_tag_o, 79, 0, 3);
// 这表示它是一个 3x32bit 的数组，总共 80 bits (way3_tag[19:0], way2_tag[19:0],
// way1_tag[19:0], way0_tag[19:0]) Way 0: bits [19:0]   -> top->rdata_tag_o[0] &
// 0xFFFFF Way 1: bits [39:20]  -> ((top->rdata_tag_o[1] << 12) |
// (top->rdata_tag_o[0] >> 20)) & 0xFFFFF Way 2: bits [59:40]  ->
// ((top->rdata_tag_o[2] << 24) | (top->rdata_tag_o[1] >> 8)) & 0xFFFFF Way 3:
// bits [79:60]  -> (top->rdata_tag_o[2] >> 4) & 0xFFFFF (注意：Verilator
// 可能将高位补零，所以顶部的 16 位可能在 top->rdata_tag_o[2] 的 [15:4] 位)
uint32_t get_tag(Vtb_tag_array *top, int way) {
  const int TAG_WIDTH = 20; // 与 tb_tag_array.sv 中的 TAG_WIDTH_TEST 匹配
  const uint32_t MASK = (1U << TAG_WIDTH) - 1;
  if (way == 0) {
    return top->rdata_tag_o[0] & MASK;
  } else if (way == 1) {
    // VlWide uses little-endian words, lowest word is index 0
    uint64_t combined =
        (uint64_t(top->rdata_tag_o[1]) << 32) | top->rdata_tag_o[0];
    return (combined >> 20) & MASK;
  } else if (way == 2) {
    uint64_t combined = (uint64_t(top->rdata_tag_o[1]) << 32) |
                        top->rdata_tag_o[0]; // Need word 1
    uint64_t combined2 = (uint64_t(top->rdata_tag_o[2]) << 32) |
                         top->rdata_tag_o[1]; // Need word 2 for upper bits
    uint64_t val =
        (combined2 << 8) | (combined >> 24); // Reconstruct across boundaries
    return (val >> 16) & MASK;               // Shift to get way 2 tag correctly
  } else if (way == 3) {
    // Way 3 starts at bit 60
    uint64_t combined = (uint64_t(top->rdata_tag_o[2]) << 32) |
                        top->rdata_tag_o[1]; // Need word 2
    return (combined >> 28) &
           MASK; // Bit 60 corresponds to shift 28 in combined word 1&2
  }
  return 0; // Should not happen
}

// 辅助函数：获取指定 Way 的 Valid 位
bool get_valid(Vtb_tag_array *top, int way) {
  // rdata_valid_o 是 4 位输出
  return (top->rdata_valid_o >> way) & 1;
}

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  Vtb_tag_array *top = new Vtb_tag_array;

  std::cout << "--- [START] Running C++ test for TagArray module ---"
            << std::endl;

  // 1. 复位
  top->rst_ni = 0;
  top->bank_addr_i = 0;
  top->bank_sel_i = 0;
  top->we_way_mask_i = 0;
  top->wdata_tag_i = 0;
  top->wdata_valid_i = 0;
  tick(top);
  top->rst_ni = 1;
  std::cout << "[" << main_time << "] Reset complete." << std::endl;

  // --- 测试 1: 写入特定 Way/Bank/Addr ---
  int test_bank = 1;
  int test_addr = 0x42;
  int test_way = 2;
  uint32_t test_tag = 0xABCD;
  bool test_valid = 1;

  std::cout << "--- Test 1: Write ---" << std::endl;
  std::cout << "[" << main_time << "] Writing Tag=0x" << std::hex << test_tag
            << ", Valid=" << test_valid << " to Bank " << std::dec << test_bank
            << ", Addr 0x" << std::hex << test_addr << ", Way " << std::dec
            << test_way << std::endl;

  top->bank_addr_i = test_addr;
  top->bank_sel_i = test_bank;
  top->we_way_mask_i = (1 << test_way); // 仅选中要写的 Way
  top->wdata_tag_i = test_tag;
  top->wdata_valid_i = test_valid;
  tick(top); // 时钟上升沿写入

  // 停止写入，准备读取
  top->we_way_mask_i = 0;
  top->eval(); // 确保写使能已经拉低

  // --- 测试 2: 读回写入的数据 ---
  std::cout << "--- Test 2: Read back written data ---" << std::endl;
  std::cout << "[" << main_time << "] Reading from Bank " << std::dec
            << test_bank << ", Addr 0x" << std::hex << test_addr << "..."
            << std::endl;

  top->bank_addr_i = test_addr;
  top->bank_sel_i = test_bank;
  top->eval(); // 组合逻辑读

  // 检查写入的 Way
  uint32_t read_tag_w2 = get_tag(top, test_way);
  bool read_valid_w2 = get_valid(top, test_way);
  std::cout << "  Way " << test_way << " Tag:   0x" << std::hex << std::setw(5)
            << std::setfill('0') << read_tag_w2 << " (Expected: 0x" << std::hex
            << test_tag << ")" << std::endl;
  std::cout << "  Way " << test_way << " Valid: " << std::dec << read_valid_w2
            << " (Expected: " << test_valid << ")" << std::endl;
  assert(read_tag_w2 == test_tag);
  assert(read_valid_w2 == test_valid);

  // 检查未写入的 Way (例如 Way 0)
  int other_way = 0;
  uint32_t read_tag_w0 = get_tag(top, other_way);
  bool read_valid_w0 = get_valid(top, other_way);
  std::cout << "  Way " << other_way << " Tag:   0x" << std::hex << std::setw(5)
            << std::setfill('0') << read_tag_w0 << " (Expected: 0x0)"
            << std::endl;
  std::cout << "  Way " << other_way << " Valid: " << std::dec << read_valid_w0
            << " (Expected: 0)" << std::endl;
  assert(read_tag_w0 == 0); // 假设 Verilator 初始化为 0
  assert(read_valid_w0 == 0);

  // --- 测试 3: 读取未写入的地址 ---
  int unwritten_bank = 3;
  int unwritten_addr = 0x88;
  int check_way = 1;
  std::cout << "--- Test 3: Read unwritten address ---" << std::endl;
  std::cout << "[" << main_time << "] Reading from Bank " << std::dec
            << unwritten_bank << ", Addr 0x" << std::hex << unwritten_addr
            << "..." << std::endl;

  top->bank_addr_i = unwritten_addr;
  top->bank_sel_i = unwritten_bank;
  top->eval(); // 组合逻辑读

  uint32_t read_tag_uw = get_tag(top, check_way);
  bool read_valid_uw = get_valid(top, check_way);
  std::cout << "  Way " << check_way << " Tag:   0x" << std::hex << std::setw(5)
            << std::setfill('0') << read_tag_uw << " (Expected: 0x0)"
            << std::endl;
  std::cout << "  Way " << check_way << " Valid: " << std::dec << read_valid_uw
            << " (Expected: 0)" << std::endl;
  assert(read_tag_uw == 0);
  assert(read_valid_uw == 0);

  std::cout << "--- [PASSED] All TagArray checks passed successfully! ---"
            << std::endl;

  delete top;
  return 0;
}