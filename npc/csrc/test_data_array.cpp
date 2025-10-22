// File: npc/csrc/test_data_array.cpp
#include "Vtb_data_array.h" // 包含 Verilator 生成的模块头文件
#include "verilated.h"
#include <cassert>
#include <iomanip> // 为了格式化输出
#include <iostream>
#include <vector>

// --- 常量定义 (应与 tb_data_array.sv 中的参数匹配) ---
const int NUM_WAYS = 4;
const int BLOCK_WIDTH_BITS = 512;
const int BLOCK_WIDTH_WORDS =
    (BLOCK_WIDTH_BITS + 31) / 32; // 计算需要多少个 32 位字

// 仿真时间跟踪
vluint64_t main_time = 0;

// 时钟滴答辅助函数
void tick(Vtb_data_array *top) {
  top->clk_i = 0;
  top->eval();
  main_time++;
  top->clk_i = 1;
  top->eval();
  main_time++;
}

// --- 辅助函数：处理 VlWide 数据 ---

// 设置 VlWide 变量 (例如 wdata_i) 的值
// 为了简单起见，这里用一个简单的模式填充数据
void set_wide_data(uint32_t *dest, int num_words, uint32_t pattern_base) {
  for (int i = 0; i < num_words; ++i) {
    dest[i] = pattern_base + i; // 填充不同的值，便于区分
  }
  // 如果位数不是 32 的整数倍，需要清除最高 word 的未使用位 (这里 512 是 32
  // 的倍数，不需要)
}

// 比较两个 VlWide 变量是否相等
bool compare_wide_data(const uint32_t *actual, const uint32_t *expected,
                       int num_words) {
  for (int i = 0; i < num_words; ++i) {
    if (actual[i] != expected[i]) {
      return false;
    }
  }
  return true;
}

// 打印 VlWide 变量 (简化版，只打印部分)
void print_wide_data(const uint32_t *data, int num_words) {
  std::cout << "0x";
  // 打印最高和最低的 word 作为示例
  if (num_words > 1) {
    std::cout << std::hex << std::setw(8) << std::setfill('0')
              << data[num_words - 1] << "...";
  }
  std::cout << std::hex << std::setw(8) << std::setfill('0') << data[0];
}

// 从 rdata_o 中提取指定 way 的数据指针
// Vtb_data_array.h 会将 rdata_o 定义为 VL_OUTW(&rdata_o, 2047, 0, 64); (512*4 =
// 2048 bits) 它是一个包含 64 个 uint32_t 的数组 (2048 / 32 = 64) Way 0: words
// [15:0] Way 1: words [31:16] Way 2: words [47:32] Way 3: words [63:48]
const uint32_t *get_way_data_ptr(Vtb_data_array *top, int way) {
  // top->rdata_o 是指向整个 2048 位输出数据块的指针 (数组首地址)
  return top->rdata_o + (way * BLOCK_WIDTH_WORDS);
}

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  Vtb_data_array *top = new Vtb_data_array;

  std::cout << "--- [START] Running C++ test for DataArray module ---"
            << std::endl;

  // 1. 复位
  top->rst_ni = 0;
  top->bank_addr_i = 0;
  top->bank_sel_i = 0;
  top->we_way_mask_i = 0;
  // 初始化写数据输入 (即使复位时用不到)
  std::vector<uint32_t> wdata_buffer(BLOCK_WIDTH_WORDS, 0);
  set_wide_data(wdata_buffer.data(), BLOCK_WIDTH_WORDS, 0); // 初始设为 0
  memcpy(top->wdata_i, wdata_buffer.data(),
         BLOCK_WIDTH_WORDS * sizeof(uint32_t));

  tick(top);
  top->rst_ni = 1;
  std::cout << "[" << main_time << "] Reset complete." << std::endl;

  // --- 测试数据准备 ---
  int test_bank = 2;
  int test_addr = 0x5A;
  int test_way = 1;
  uint32_t write_pattern = 0xA0A0A0A0; // 用于填充写入数据的基准值
  std::vector<uint32_t> expected_data(BLOCK_WIDTH_WORDS);
  set_wide_data(expected_data.data(), BLOCK_WIDTH_WORDS, write_pattern);

  // --- 测试 1: 写入特定 Way/Bank/Addr ---
  std::cout << "--- Test 1: Write ---" << std::endl;
  std::cout << "[" << main_time << "] Writing data pattern starting with 0x"
            << std::hex << write_pattern << " to Bank " << std::dec << test_bank
            << ", Addr 0x" << std::hex << test_addr << ", Way " << std::dec
            << test_way << std::endl;

  top->bank_addr_i = test_addr;
  top->bank_sel_i = test_bank;
  top->we_way_mask_i = (1 << test_way); // 仅选中 Way 1
  memcpy(top->wdata_i, expected_data.data(),
         BLOCK_WIDTH_WORDS * sizeof(uint32_t)); // 设置写数据
  tick(top);                                    // 时钟上升沿写入

  // 停止写入，准备读取
  top->we_way_mask_i = 0;
  // 将 wdata_i 清零，以防后续读取错误地读到输入值（虽然不太可能）
  set_wide_data(wdata_buffer.data(), BLOCK_WIDTH_WORDS, 0);
  memcpy(top->wdata_i, wdata_buffer.data(),
         BLOCK_WIDTH_WORDS * sizeof(uint32_t));
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
  const uint32_t *read_data_w1_ptr = get_way_data_ptr(top, test_way);
  std::cout << "  Way " << test_way << " Data (partial): ";
  print_wide_data(read_data_w1_ptr, BLOCK_WIDTH_WORDS);
  std::cout << " (Expected pattern starting with: 0x" << std::hex
            << write_pattern << ")" << std::endl;
  assert(compare_wide_data(read_data_w1_ptr, expected_data.data(),
                           BLOCK_WIDTH_WORDS));

  // 检查未写入的 Way (例如 Way 3)
  int other_way = 3;
  const uint32_t *read_data_w3_ptr = get_way_data_ptr(top, other_way);
  std::vector<uint32_t> zero_data(BLOCK_WIDTH_WORDS, 0); // 期望是 0
  std::cout << "  Way " << other_way << " Data (partial): ";
  print_wide_data(read_data_w3_ptr, BLOCK_WIDTH_WORDS);
  std::cout << " (Expected pattern starting with: 0x0)" << std::endl;
  assert(
      compare_wide_data(read_data_w3_ptr, zero_data.data(), BLOCK_WIDTH_WORDS));

  // --- 测试 3: 读取未写入的地址 ---
  int unwritten_bank = 0;
  int unwritten_addr = 0xCC;
  int check_way = 0;
  std::cout << "--- Test 3: Read unwritten address ---" << std::endl;
  std::cout << "[" << main_time << "] Reading from Bank " << std::dec
            << unwritten_bank << ", Addr 0x" << std::hex << unwritten_addr
            << "..." << std::endl;

  top->bank_addr_i = unwritten_addr;
  top->bank_sel_i = unwritten_bank;
  top->eval(); // 组合逻辑读

  const uint32_t *read_data_uw_ptr = get_way_data_ptr(top, check_way);
  std::cout << "  Way " << check_way << " Data (partial): ";
  print_wide_data(read_data_uw_ptr, BLOCK_WIDTH_WORDS);
  std::cout << " (Expected pattern starting with: 0x0)" << std::endl;
  assert(
      compare_wide_data(read_data_uw_ptr, zero_data.data(), BLOCK_WIDTH_WORDS));

  std::cout << "--- [PASSED] All DataArray checks passed successfully! ---"
            << std::endl;

  delete top;
  return 0;
}