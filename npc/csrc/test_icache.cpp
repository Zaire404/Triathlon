#include "Vtb_icache.h"
#include "verilated.h"
#include <cassert>
#include <iomanip>
#include <iostream>
#include <map>
#include <vector>

// =================================================================
// 常量定义 (应与配置匹配)
// =================================================================
// 这些值应与 Cfg 匹配
const int VLEN = 32;
const int ILEN = 32;
// 内部使用 64 位地址以避免 C++ 警告，并确保内存模拟器的地址空间足够
const int PLEN = 64;
const int INSTR_PER_FETCH = 4;
// ICACHE_LINE_WIDTH 在 test_config_pkg 中是 256
const int LINE_WIDTH_BITS = 256;
const int LINE_WIDTH_BYTES = LINE_WIDTH_BITS / 8;     // 32 bytes
const int LINE_WIDTH_WORDS_32 = LINE_WIDTH_BITS / 32; // 8 words

// 仿真时间
vluint64_t main_time = 0;

// =================================================================
// 内存模拟器
// =================================================================

class SimulatedMemory {
private:
  // (Line 地址, Cache Line 数据块)
  std::map<uint64_t, std::vector<uint32_t>> memory_data;
  int delay_counter;
  bool response_pending;
  std::vector<uint32_t> response_data;
  uint64_t last_req_addr;

public:
  SimulatedMemory()
      : delay_counter(-1), response_pending(false), last_req_addr(0) {}

  /**
   * @brief 在 tick() 开始时调用。处理内存响应（作为 DUT 的输入）。
   */
  void provide_response(Vtb_icache *top) {
    // 1. 内存始终准备好接收请求
    top->mem_rsp_ready_i = 1;

    // 2. 处理来自 ICache 的内存响应
    if (response_pending && delay_counter > 0) {
      delay_counter--;
    }

    if (response_pending && delay_counter == 0) {
      std::cout << "[" << main_time
                << "] MEM: -> ICache: 'mem_rsp_valid_i' = 1, Data sent for "
                   "Line Addr=0x"
                << std::hex << last_req_addr << std::endl;
      top->mem_rsp_valid_i = 1;

      // VlWide 赋值 (256-bit -> 8 x 32-bit words)
      for (int i = 0; i < LINE_WIDTH_WORDS_32; ++i) {
        top->mem_rsp_data_i[i] = response_data[i];
      }
      top->mem_rsp_is_prefetch_i = 0;

      response_pending = false; // 只发送一个周期
      delay_counter = -1;
    } else {
      top->mem_rsp_valid_i = 0;
    }
  }

  /**
   * @brief 在 tick() 中 clk=0, eval() 之后调用。捕获 ICache 请求（作为 DUT
   * 的输出）。
   */
  void capture_request(Vtb_icache *top) {
    // 3. 处理来自 ICache 的内存请求
    // 只有当 ICache 发送请求且内存模拟器准备好接收时才处理
    if (top->mem_req_valid_o && top->mem_rsp_ready_i) {
      uint64_t req_addr = top->mem_req_addr_o;
      // 地址对齐到 Cache Line 边界
      uint64_t line_addr = req_addr & ~((uint64_t)LINE_WIDTH_BYTES - 1);

      std::cout << "[" << main_time
                << "] MEM: <- ICache: 'mem_req_valid_o' = 1, Addr=0x"
                << std::hex << req_addr << " (Line Addr=0x" << line_addr << ")"
                << std::endl;

      if (memory_data.count(line_addr)) {
        response_data = memory_data[line_addr];
      } else {
        // 生成默认数据
        response_data.assign(LINE_WIDTH_WORDS_32, 0xBAD0BAD0);
        std::cout << "        WARNING: No data preloaded for address 0x"
                  << std::hex << line_addr << std::endl;
      }
      last_req_addr = line_addr;

      response_pending = true;
      delay_counter = 10; // 模拟 10 个周期的内存延迟
    }
  }

  /**
   * @brief 预加载内存数据到模拟器中
   */
  void preload_data(uint64_t addr, const std::vector<uint32_t> &data) {
    uint64_t line_addr = addr & ~((uint64_t)LINE_WIDTH_BYTES - 1);
    memory_data[line_addr] = data;
  }
};

/**
 * @brief 驱动一个完整的时钟周期，并处理内存接口时序
 * * @param top Verilator 顶层模块指针
 * @param memory 内存模拟器指针
 */
void tick(Vtb_icache *top, SimulatedMemory *memory) {
  // 1. 内存模拟器更新其输出信号 (mem_rsp_i.valid/data/ready)
  memory->provide_response(top);

  // 2. 时钟低电平
  top->clk_i = 0;
  top->eval(); // 组合逻辑计算出 mem_req_o

  // 3. 在时钟变高前，捕获ICache发出的请求 (单周期脉冲)
  // 捕获请求必须在 FSM 状态更新之前 (即 clk=0 eval 之后)
  memory->capture_request(top);
  main_time++;

  // 4. 时钟高电平 (触发寄存器更新)
  top->clk_i = 1;
  top->eval();
  main_time++;
}

// =================================================================
// 测试用例辅助函数
// =================================================================

/**
 * @brief 设置 IFU 请求
 */
void set_ifu_request(Vtb_icache *top, uint32_t addr0, uint32_t addr1,
                     uint32_t addr2, uint32_t addr3) {
  top->ifu_req_valid_i = 1;
  top->ifu_req_vaddr_i[0] = addr0;
  top->ifu_req_vaddr_i[1] = addr1;
  top->ifu_req_vaddr_i[2] = addr2;
  top->ifu_req_vaddr_i[3] = addr3;
}

/**
 * @brief 清除 IFU 请求
 */
void clear_ifu_request(Vtb_icache *top) {
  top->ifu_req_valid_i = 0;
  // 保持地址为非零以便于调试，但清除了有效位
}

/**
 * @brief 运行一个完整的测试场景（处理 Miss 并等待 Hit）
 */
bool run_test_case(Vtb_icache *top, SimulatedMemory *memory,
                   const char *test_name,
                   const std::vector<uint32_t> &req_addrs,
                   const std::vector<uint32_t> &expected_data) {

  std::cout << "\n--- Test Case: " << test_name << " ---" << std::endl;
  assert(req_addrs.size() == INSTR_PER_FETCH &&
         expected_data.size() == INSTR_PER_FETCH);

  // 1. 发起 IFU 请求
  set_ifu_request(top, req_addrs[0], req_addrs[1], req_addrs[2], req_addrs[3]);

  int max_cycles = 200;
  bool done = false;

  for (int i = 0; i < max_cycles; ++i) {
    tick(top, memory);

    // 2. 检查 IFU 响应
    if (top->ifu_rsp_ready_o) {
      std::cout << "[" << main_time
                << "] IFU: <- ICache: 'ifu_rsp_ready_o' = 1. Data received."
                << std::endl;
      done = true;
      for (int j = 0; j < INSTR_PER_FETCH; ++j) {
        if (top->ifu_rsp_data_o[j] != expected_data[j]) {
          std::cout << "    [ERROR] Instr " << j << " Fail. Got: 0x" << std::hex
                    << top->ifu_rsp_data_o[j] << " Expected: 0x"
                    << expected_data[j] << " at Vaddr: 0x" << req_addrs[j]
                    << std::endl;
          // 确保测试失败时停止
          assert(false);
        }
      }

      clear_ifu_request(top); // IFU 停止请求
      break;
    }
  }

  if (!done) {
    std::cout << "    [ERROR] Test failed: Timeout after " << max_cycles
              << " cycles." << std::endl;
  }

  return done;
}

// =================================================================
// Main
// =================================================================

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  Vtb_icache *top = new Vtb_icache;
  SimulatedMemory memory;

  std::cout << "--- [START] Running C++ test for ICache ---" << std::endl;

  // 1. 预加载内存数据
  // Line 1: 0x80000000 ~ 0x8000001F (Index 0x00)
  std::vector<uint32_t> line_data1(LINE_WIDTH_WORDS_32);
  for (int i = 0; i < LINE_WIDTH_WORDS_32; ++i)
    line_data1[i] = 0x80000000 + i * 4;
  memory.preload_data(0x80000000, line_data1);

  // Line 2: 0x80000020 ~ 0x8000003F (Index 0x01)
  std::vector<uint32_t> line_data2(LINE_WIDTH_WORDS_32);
  for (int i = 0; i < LINE_WIDTH_WORDS_32; ++i)
    line_data2[i] = 0x80000020 + i * 4;
  memory.preload_data(0x80000020, line_data2);

  // Line 3: 0x80000040 ~ 0x8000005F (Index 0x02)
  std::vector<uint32_t> line_data3(LINE_WIDTH_WORDS_32);
  for (int i = 0; i < LINE_WIDTH_WORDS_32; ++i)
    line_data3[i] = 0x80000040 + i * 4;
  memory.preload_data(0x80000040, line_data3);

  // --- 为置换测试预加载数据 ---
  // 地址的 [9:5] 位是 index。以下地址的 index 都为 1。
  // Tag = addr[31:10]
  // Addr A: 0x80000020 -> Index=1, Tag=0x20000
  // Addr B: 0x80000420 -> Index=1, Tag=0x20001
  // Addr C: 0x80000820 -> Index=1, Tag=0x20002
  // Addr D: 0x80000C20 -> Index=1, Tag=0x20003
  // Addr E: 0x80001020 -> Index=1, Tag=0x20004 (用于触发置换)

  uint32_t repl_addr_A = 0x80000020; // 已在 line_data2 中预加载
  uint32_t repl_addr_B = 0x80000420;
  uint32_t repl_addr_C = 0x80000820;
  uint32_t repl_addr_D = 0x80000C20;
  uint32_t repl_addr_E = 0x80001020;

  std::vector<uint32_t> repl_data_B(LINE_WIDTH_WORDS_32);
  for (int i = 0; i < LINE_WIDTH_WORDS_32; ++i)
    repl_data_B[i] = repl_addr_B + i * 4;
  memory.preload_data(repl_addr_B, repl_data_B);

  std::vector<uint32_t> repl_data_C(LINE_WIDTH_WORDS_32);
  for (int i = 0; i < LINE_WIDTH_WORDS_32; ++i)
    repl_data_C[i] = repl_addr_C + i * 4;
  memory.preload_data(repl_addr_C, repl_data_C);

  std::vector<uint32_t> repl_data_D(LINE_WIDTH_WORDS_32);
  for (int i = 0; i < LINE_WIDTH_WORDS_32; ++i)
    repl_data_D[i] = repl_addr_D + i * 4;
  memory.preload_data(repl_addr_D, repl_data_D);

  std::vector<uint32_t> repl_data_E(LINE_WIDTH_WORDS_32);
  for (int i = 0; i < LINE_WIDTH_WORDS_32; ++i)
    repl_data_E[i] = repl_addr_E + i * 4;
  memory.preload_data(repl_addr_E, repl_data_E);

  // 2. 复位
  top->rst_ni = 0;
  clear_ifu_request(top);
  top->ftq_req_valid_i = 0;
  memory.provide_response(top);
  top->clk_i = 0;
  top->eval();
  memory.capture_request(top);
  main_time++;

  top->clk_i = 1;
  top->eval();
  top->rst_ni = 1;
  main_time++;
  std::cout << "[" << main_time << "] Reset complete." << std::endl;

  // =================================================================
  //  Test 1: 单行 Miss (Addr 0x80000000)
  // =================================================================
  bool test1_passed =
      run_test_case(top, &memory, "1: Single Line Miss (0x80000000)",
                    {0x80000000, 0x80000004, 0x80000008, 0x8000000C},
                    {0x80000000, 0x80000004, 0x80000008, 0x8000000C});
  assert(test1_passed);
  std::cout << "--- Test 1 PASSED ---" << std::endl;

  // 清理: 运行一个周期，清除状态
  tick(top, &memory);

  // =================================================================
  //  Test 2: 单行 Hit (Addr 0x80000010, 仍在 Line 1)
  // =================================================================
  bool test2_passed =
      run_test_case(top, &memory, "2: Single Line Hit (0x80000010)",
                    {0x80000010, 0x80000014, 0x80000018, 0x8000001C},
                    {0x80000010, 0x80000014, 0x80000018, 0x8000001C});
  assert(test2_passed);
  std::cout << "--- Test 2 PASSED ---" << std::endl;

  // 清理: 运行一个周期，清除状态
  tick(top, &memory);

  // =================================================================
  //  Test 3: 跨行 Hit-Miss (Addr 0x80000018 & 0x80000020)
  // =================================================================
  // Line 1 (0x80000000) Hit, Line 2 (0x80000020) Miss
  bool test3_passed = run_test_case(
      top, &memory, "3: Cross-Line Hit-Miss (0x80000018/0x80000020)",
      {0x80000018, 0x8000001C, 0x80000020, 0x80000024},
      {0x80000018, 0x8000001C, 0x80000020, 0x80000024});
  assert(test3_passed);
  std::cout << "--- Test 3 PASSED ---" << std::endl;

  // 清理: 运行一个周期，清除状态
  tick(top, &memory);

  // =================================================================
  //  Test 4: 跨行 Hit-Miss (Addr 0x80000038 & 0x80000040)
  // =================================================================
  // Line 2 (0x80000020) Hit, Line 3 (0x80000040) Miss
  bool test4_passed = run_test_case(
      top, &memory, "4: Cross-Line Hit-Miss (0x80000038/0x80000040)",
      {0x80000038, 0x8000003C, 0x80000040, 0x80000044},
      {0x80000038, 0x8000003C, 0x80000040, 0x80000044});
  assert(test4_passed);
  std::cout << "--- Test 4 PASSED ---" << std::endl;

  // 清理: 运行一个周期，清除状态
  tick(top, &memory);

  // =================================================================
  //  Test 5: Cache Line Replacement
  // =================================================================
  std::cout << "\n--- Test Case: 5: Cache Line Replacement ---" << std::endl;
  // 1: 访问 Addr B, C, D，填满 Index=1 的所有 way (Addr A 已经在 Test 3 中加载)
  run_test_case(
      top, &memory, "5.1: Fill Set 1 (Addr B)",
      {repl_addr_B, repl_addr_B + 4, repl_addr_B + 8, repl_addr_B + 12},
      {repl_addr_B, repl_addr_B + 4, repl_addr_B + 8, repl_addr_B + 12});
  tick(top, &memory);
  run_test_case(
      top, &memory, "5.2: Fill Set 1 (Addr C)",
      {repl_addr_C, repl_addr_C + 4, repl_addr_C + 8, repl_addr_C + 12},
      {repl_addr_C, repl_addr_C + 4, repl_addr_C + 8, repl_addr_C + 12});
  tick(top, &memory);
  run_test_case(
      top, &memory, "5.3: Fill Set 1 (Addr D)",
      {repl_addr_D, repl_addr_D + 4, repl_addr_D + 8, repl_addr_D + 12},
      {repl_addr_D, repl_addr_D + 4, repl_addr_D + 8, repl_addr_D + 12});
  tick(top, &memory);

  // 2: 访问 Addr E，这会替换掉 Set 1 中的某一个 Line
  std::cout << "--- Now requesting Addr E to trigger replacement ---"
            << std::endl;
  run_test_case(
      top, &memory, "5.4: Trigger Replacement (Addr E)",
      {repl_addr_E, repl_addr_E + 4, repl_addr_E + 8, repl_addr_E + 12},
      {repl_addr_E, repl_addr_E + 4, repl_addr_E + 8, repl_addr_E + 12});
  tick(top, &memory);

  // 3: 再次访问 Addr A (或 B,C,D 中的任何一个)。它现在应该是 Miss
  std::cout << "--- Now requesting Addr A again, expecting a miss ---"
            << std::endl;
  bool test5_passed =
      run_test_case(top, &memory, "5.5: Verify Replacement (Re-fetch Addr A)",
                    {0x80000020, 0x80000024, 0x80000028, 0x8000002C},
                    {0x80000020, 0x80000024, 0x80000028, 0x8000002C});
  assert(test5_passed);
  std::cout << "--- Test 5 PASSED ---" << std::endl;

  std::cout << "\n--- [END] All tests PASSED for ICache ---" << std::endl;
  delete top;
  return 0;
}