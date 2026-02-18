#include "Vtb_frontend.h"
#include "verilated.h"
#include <cassert>
#include <iomanip>
#include <iostream>
#include <map>
#include <vector>

// =================================================================
// 配置参数
// =================================================================
const int INSTR_PER_FETCH = 4;
const int NRET = 4;
const int LINE_WIDTH_BYTES = 32; // 256 bits
const int LINE_WIDTH_WORDS = LINE_WIDTH_BYTES / 4;

vluint64_t main_time = 0;

// =================================================================
// 内存模拟器 (支持自动 Refill)
// =================================================================
class SimulatedMemory {
private:
  std::map<uint32_t, std::vector<uint32_t>> memory_data;

  enum State { IDLE, WAIT_DELAY, SEND_REFILL };
  State state = IDLE;
  int delay_counter = 0;

  uint32_t pending_addr = 0;
  uint32_t pending_way = 0;

public:
  // 预加载数据到内存
  void preload(uint32_t start_addr, const std::vector<uint32_t> &instrs) {
    uint32_t line_addr = start_addr & ~(LINE_WIDTH_BYTES - 1);
    std::vector<uint32_t> line(LINE_WIDTH_WORDS, 0);

    if (memory_data.count(line_addr)) {
      line = memory_data[line_addr];
    }
    int offset_words = (start_addr - line_addr) / 4;
    for (size_t i = 0;
         i < instrs.size() && (offset_words + i) < LINE_WIDTH_WORDS; ++i) {
      line[offset_words + i] = instrs[i];
    }
    memory_data[line_addr] = line;
  }

  void eval(Vtb_frontend *top) {
    top->miss_req_ready_i = 1; // memory always ready
    top->refill_valid_i = 0;

    if (state == IDLE && top->miss_req_valid_o) {
      pending_addr = top->miss_req_paddr_o;
      pending_way = top->miss_req_victim_way_o;
      state = WAIT_DELAY;
      delay_counter = 3; // Memory Latency
      // std::cout << "[" << main_time << "] MEM: Miss Req 0x" << std::hex <<
      // pending_addr << std::endl;
    }

    if (state == WAIT_DELAY) {
      if (delay_counter > 0)
        delay_counter--;
      else
        state = SEND_REFILL;
    }

    if (state == SEND_REFILL) {
      top->refill_valid_i = 1;
      top->refill_paddr_i = pending_addr;
      top->refill_way_i = pending_way;

      uint32_t line_addr = pending_addr & ~(LINE_WIDTH_BYTES - 1);
      if (memory_data.count(line_addr)) {
        const auto &data = memory_data[line_addr];
        for (int i = 0; i < LINE_WIDTH_WORDS; ++i)
          top->refill_data_i[i] = data[i];
      } else {
        for (int i = 0; i < LINE_WIDTH_WORDS; ++i)
          top->refill_data_i[i] = 0xDEADBEEF;
      }

      if (top->refill_ready_o) {
        // std::cout << "[" << main_time << "] MEM: Refill Done 0x" << std::hex
        // << pending_addr << std::endl;
        state = IDLE;
      }
    }
  }
};

void tick(Vtb_frontend *top, SimulatedMemory &mem) {
  top->clk_i = 0;
  mem.eval(top);
  top->eval();
  main_time++;
  top->clk_i = 1;
  top->eval();
  main_time++;
}

uint32_t get_instr(Vtb_frontend *top, int index) {
  return top->ibuffer_data_o[index];
}

// =================================================================
// Main Test
// =================================================================
int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  Vtb_frontend *top = new Vtb_frontend;
  SimulatedMemory mem;

  std::cout << "============================================================="
            << std::endl;
  std::cout << " TEST: Sequential -> Flush -> Block(Stall) -> Unblock"
            << std::endl;
  std::cout << "============================================================="
            << std::endl;

  // 1. 预加载数据
  // Group 1 (0x00)
  mem.preload(0x80000000, {0x00000013, 0x00100093, 0x00200113, 0x00300193});
  // Group 2 (0x10)
  mem.preload(0x80000010, {0x00400213, 0x00500293, 0x00600313, 0x00700393});
  // Group 3 (0x20) - Flush Target
  mem.preload(0x80000020, {0x00800413, 0x00900493, 0x00A00513, 0x00B00593});
  // Group 4 (0x30) - Blocking Test Target
  mem.preload(0x80000030,
              {0x00C00613, 0x00D00693, 0x00E00713, 0x00F00793}); // Li x12...
  // Group 5 (0x40) - Recovery Target
  mem.preload(0x80000040,
              {0x01000813, 0x01100893, 0x01200913, 0x01300993}); // Li x16...

  // 2. 复位
  top->rst_ni = 0;
  top->ibuffer_ready_i = 0;
  top->flush_i = 0;
  top->redirect_pc_i = 0;
  top->bpu_update_valid_i = 0;
  top->bpu_update_pc_i = 0;
  top->bpu_update_is_cond_i = 0;
  top->bpu_update_taken_i = 0;
  top->bpu_update_target_i = 0;
  top->bpu_update_is_call_i = 0;
  top->bpu_update_is_ret_i = 0;
  top->bpu_ras_update_valid_i = 0;
  top->bpu_ras_update_is_call_i = 0;
  top->bpu_ras_update_is_ret_i = 0;
  for (int i = 0; i < NRET; i++) {
    top->bpu_ras_update_pc_i[i] = 0;
  }
  for (int i = 0; i < 5; i++)
    tick(top, mem);
  top->rst_ni = 1;

  // 3. 开始测试
  // 初始状态：IBuffer Ready
  top->ibuffer_ready_i = 1;

  int stage = 0;
  int stall_counter = 0;
  int max_cycles = 300;

  for (int i = 0; i < max_cycles; ++i) {
    tick(top, mem);
    std::cout << "stage = " << stage << std::endl;
    // ====================================================
    // 状态机检测逻辑
    // ====================================================
    if (top->ibuffer_valid_o) {
      uint32_t pc = top->ibuffer_pc_o;
      uint32_t instr0 = get_instr(top, 0);

      // ------------------------------------------------
      // Stage 0: Fetch 1 (0x00)
      // ------------------------------------------------
      if (stage == 0) {
        std::cout << "[" << main_time
                  << "] [Stage 0] Fetch 0x80000000. Instr0=" << std::hex
                  << instr0 << std::endl;
        assert(pc == 0x80000000);
        stage = 1;
      }
      // ------------------------------------------------
      // Stage 1: Fetch 2 (0x10) -> Trigger Flush
      // ------------------------------------------------
      else if (stage == 1) {
        if (pc == 0x80000010) {
          std::cout << "[" << main_time
                    << "] [Stage 1] Fetch 0x80000010. TRIGGERING FLUSH -> 0x20"
                    << std::endl;
          // 在这里触发 Flush
          top->flush_i = 1;
          top->redirect_pc_i = 0x80000020;
          stage = 2;
        }
      }
      // ------------------------------------------------
      // Stage 3: Fetch 3 (0x20) (Redirected) -> Prepare to Block
      // ------------------------------------------------
      else if (stage == 3) {
        if (pc == 0x80000020) {
          std::cout << "[" << main_time
                    << "] [Stage 3] Fetch 0x80000020 (Redirected). PASS."
                    << std::endl;
          assert(instr0 == 0x00800413); // 验证数据

          // 准备在下一条指令 (0x30) 到来前拉低 Ready
          // 注意：这里如果不拉低，下一拍 IFU 就会认为握手成功并更新 PC
          // 我们想要测试 0x30 被阻塞，所以必须在 0x20 握手完成后（或同时）改变
          // Ready 状态 但由于我们在循环里 tick 已经执行过了，现在的 Ready=1
          // 意味着 0x20 已经握手成功。 下一拍 IFU 会尝试取 0x30。我们现在拉低
          // Ready。

          std::cout << "[" << main_time
                    << "] [Action] Asserting IBuffer BUSY (Ready=0)..."
                    << std::endl;
          top->ibuffer_ready_i = 0;
          stage = 4;
          stall_counter = 0;
        }
      }
      // ------------------------------------------------
      // Stage 4: Fetch 4 (0x30) - BLOCKING TEST
      // ------------------------------------------------
      else if (stage == 4) {
        std::cout << " PC = " << pc << std::endl;
        // 此时 IFU 应该输出了 0x30 的数据，但是因为
        // Ready=0，它应该保持这个状态 我们多等几个周期，确保它一直卡在这里
        if (pc == 0x80000030) {
          if (stall_counter == 0) {
            std::cout << "[" << main_time
                      << "] [Stage 4] Fetch 0x80000030 Arrived. Holding..."
                      << std::endl;
            assert(instr0 == 0x00C00613); // 验证是 0x30 的数据
          }

          stall_counter++;
          std::cout << "stall_counter = " << stall_counter << std::endl;
          // 检查是否“滑移” (PC 变成了 0x40 ?)
          // 如果逻辑正确，在 Ready=0 期间，PC 应该一直保持 0x30，Valid 一直为 1
          assert(pc == 0x80000030 && "PC Advanced despite Ready=0!");

          if (stall_counter >= 10) {
            std::cout
                << "[" << main_time
                << "] [Stage 4] Stall verified for 10 cycles. Unblocking..."
                << std::endl;
            top->ibuffer_ready_i = 1; // 解除阻塞
            stage = 5;
          }
        }
      }
      // ------------------------------------------------
      // Stage 5: Fetch 5 (0x40) - RECOVERY TEST
      // ------------------------------------------------
      else if (stage == 5) {
        // 阻塞解除后，0x30 应该在上一拍完成握手，现在应该拿到 0x40
        if (pc == 0x80000040) {
          std::cout
              << "[" << main_time
              << "] [Stage 5] Fetch 0x80000040 Arrived. Unblock Successful!"
              << std::endl;
          assert(instr0 == 0x01000813);
          std::cout << "--- ALL TESTS PASSED ---" << std::endl;
          delete top;
          return 0;
        }
      }
    }

    // 处理 Flush 信号的撤销 (在 Stage 2 等待一拍后)
    if (stage == 2) {
      // 此时 flush_i 已经保持了一个时钟沿
      top->flush_i = 0;
      top->redirect_pc_i = 0;
      stage = 3; // 等待新的指令流
    }
  }

  std::cout << "--- [TIMEOUT] Stage " << stage << " not completed ---"
            << std::endl;
  delete top;
  return 1;
}
