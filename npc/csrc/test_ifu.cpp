#include <iostream>
#include <memory>
#include <cassert>
#include <bitset>
#include <verilated.h>
#include <verilated_vcd_c.h>
#include "Vtb_ifu.h" // Verilator 生成的頂層測試平台頭文件


// --- 仿真控制 ---
vluint64_t sim_time = 0;
const vluint64_t SIM_TIMEOUT = 1000; // 增加超時時間

// --- 從 Verilator 模型中獲取參數 (請確保與 ifu_pkg 一致) ---
const int PredictWidth = ::PredictWidth;
const int VAddrBits = ::VAddrBits;
const int INST_BITS = ::INST_BITS;
const int DATA_WIDTH_WORDS = ::DATA_WIDTH / 32; // e.g., 512 / 32 = 16
const int CommitWidth = ::CommitWidth;
const int ROB_COMMIT_WORDS = (sizeof(Vtb_ifu::rob_commits) / sizeof(Vtb_ifu::rob_commits[0]));

// --- 輔助函數 ---

// 產生時鐘翻轉
void tick(Vtb_ifu* top, VerilatedVcdC* tfp) {
    top->clk = !top->clk;
    top->eval(); // 評估模型
    if (tfp) tfp->dump(sim_time); // 寫入波形
    sim_time++;
}

// 產生一個完整的時鐘週期
void cycle(Vtb_ifu* top, VerilatedVcdC* tfp) {
    tick(top, tfp);
    tick(top, tfp);
}

// 執行復位
void reset(Vtb_ifu* top, VerilatedVcdC* tfp) {
    top->rst = 1; // 保持復位
    top->eval();
    for (int i = 0; i < 5; i++) {
        cycle(top, tfp);
    }
    top->rst = 0; // 釋放復位
    top->eval();
}

// 初始化所有IFU的輸入信號
void init_inputs(Vtb_ifu* top) {
    // FTQ 請求
    top->ftq_req_valid = 0;
    top->ftq_req_start_addr = 0;
    top->ftq_req_ftqIdx_i = 0;
    top->ftq_predicted_taken_i = 0;
    top->ftq_predicted_idx_i = 0;
    top->ftq_predicted_target_i = 0;
    top->ftq_req_cross_cacheline = 0; // 
    top->from_bpu_f1_flush = 0;       // [cite: 157]
    
    // 沖刷信號
    top->ftq_flush_from_bpu = 0;
    top->backend_redirect = 0;

    // I-Cache 請求 (F0 握手)
    top->icache_resp_ready = 1; //  關鍵: 默認 I-Cache 準備好接收 F0 請求

    // I-Cache 響應 (F2 握手)
    top->icache_resp_valid = 0;
    top->is_mmio_from_icache_resp = 0;
    top->icache_vaddr_0 = 0;          // 

    // I-Buffer
    top->ibuffer_ready = 1; // 關鍵: 默認 I-Buffer 準備好接收 F3 數據

    // ROB 提交
    for(size_t i = 0; i < ROB_COMMIT_WORDS; ++i) {
        top->rob_commits[i] = 0;
    }

    // I-Cache 數據總線
    for(int i = 0; i < DATA_WIDTH_WORDS; i++) top->icache_data[i] = 0;
}


int main(int argc, char** argv) {
    // 初始化 Verilator
    Verilated::commandArgs(argc, argv);

    // 實例化 DUT
    auto top = std::make_unique<Vtb_ifu>();

    // 初始化波形跟蹤 (VCD)
    Verilated::traceEverOn(true);
    auto tfp = std::make_unique<VerilatedVcdC>();
    top->trace(tfp.get(), 99);
    tfp->open("ifu_waves.vcd"); // 波形文件名

    // --- 1. 初始化 ---
    init_inputs(top.get());

    // ==========================================================
    // 場景 0: 復位測試 (Reset Test)
    // ==========================================================
    std::cout << "Testbench: [Scene 0] Running Reset Test..." << std::endl;
    reset(top.get(), tfp.get());

    // 檢查復位後的默認狀態
    // 因為 init_inputs 設置了 f1_ready=1 (隱含) 和 icache_resp_ready=1
    // 所以 ftq_req_ready 應該為 1
    assert(top->ftq_req_ready == 1 && "[Check FAILED]: ftq_req_ready should be 1 after reset.");
    assert(top->to_ibuffer_valid == 0 && "[Check FAILED]: to_ibuffer_valid should be 0 after reset.");
    assert(top->icache_req_valid == 0 && "[Check FAILED]: icache_req_valid should be 0 after reset.");
    std::cout << "Testbench: [Scene 0] Reset Test SUCCESS." << std::endl;


    // ==========================================================
    // 場景 1: 基本順序取指 (Sequential Fetch)
    // ==========================================================
    std::cout << "Testbench: [Scene 1] Running Sequential Fetch Test..." << std::endl;
    
    // 1.1 模擬 FTQ 發起請求 (預測不跳轉, 非跨行)
    top->ftq_req_valid = 1;
    top->ftq_req_start_addr = 0x80000000;
    top->ftq_req_ftqIdx_i = 1;
    top->ftq_predicted_taken_i = 0; // 預測不跳轉
    top->ftq_req_cross_cacheline = 0; // 驅動新添加的端口 

    // 1.2 等待 F0 握手
    while (!top->ftq_req_ready && sim_time < SIM_TIMEOUT) { cycle(top.get(), tfp.get()); }
    assert(sim_time < SIM_TIMEOUT && "[Timeout FAILED]: Waiting for ftq_req_ready");
    top->ftq_req_valid = 0; // 握手完成，拉低valid
    cycle(top.get(), tfp.get()); // 讓 f0_fire 傳播
    std::cout << "Testbench: F0 Handshake (FTQ -> IFU) complete." << std::endl;

    // 1.3 等待 IFU 向 I-Cache 發起請求
    while (!top->icache_req_valid && sim_time < SIM_TIMEOUT) { cycle(top.get(), tfp.get()); }
    assert(sim_time < SIM_TIMEOUT && "[Timeout FAILED]: Waiting for icache_req_valid");
    assert(top->icache_req_addr == 0x80000000 && "[Check FAILED]: I-Cache request address is incorrect.");
    assert(top->icache_req_double_line == 0 && "[Check FAILED]: icache_req_double_line should be 0 for non-crossline req.");
    std::cout << "Testbench: I-Cache Request (IFU -> ICache) received." << std::endl;

    // 1.4 模擬 I-Cache 返回數據 (4條指令)
    top->icache_resp_valid = 1;
    top->icache_vaddr_0 = 0x80000000; // 【關鍵】: 驅動地址驗證端口 
    
    // I-Cache 數據 (DATA_WIDTH = 512 bits)
    // 您的 F2 切取邏輯 [cite: 60-63] 是從 icache_data 低位開始切片
    top->icache_data[0] = 0x00100093; // Inst 0: lui a0, 0x100
    top->icache_data[1] = 0x00200113; // Inst 1: addi x2, x0, 2
    top->icache_data[2] = 0x11010111; // Inst 2: JAL x2, 0x5000 (這是一條分支) [cite: 130]
    top->icache_data[3] = 0x00300193; // Inst 3: addi x3, x0, 3 (這條應該被遮罩)

    // 1.5 等待 F2 握手
    while (!top->icache_resp_ready_o && sim_time < SIM_TIMEOUT) { cycle(top.get(), tfp.get()); }
    assert(sim_time < SIM_TIMEOUT && "[Timeout FAILED]: Waiting for icache_resp_ready_o");
    top->icache_resp_valid = 0; // 握手完成
    std::cout << "Testbench: F2 Handshake (ICache -> IFU) complete." << std::endl;

    // 1.6 等待指令包發送到 I-Buffer
    while (!top->to_ibuffer_valid && sim_time < SIM_TIMEOUT) { cycle(top.get(), tfp.get()); }
    assert(sim_time < SIM_TIMEOUT && "[Timeout FAILED]: Waiting for to_ibuffer_valid");
    std::cout << "Testbench: F3 Handshake (IFU -> IBuffer) complete." << std::endl;

    // 1.7 檢查 F3 輸出
    std::cout << "Testbench: Checking F3 outputs..." << std::endl;
    // 檢查有效位元遮罩 (F3的`f3_valid_mask`邏輯) [cite: 95-99]
    // JAL 在索引 2，所以 0, 1, 2 都有效，3 無效。遮罩應為 4'b1111 (0...3) -> 4'b0111 (LSB=0)
    assert(top->to_ibuffer_enqEnable == 0b0111 && "[Check FAILED]: Valid Mask (enqEnable) is incorrect. Should be 4'b0111.");

    // 檢查指令是否正確
    // to_ibuffer_instr 是 [127:0]，分為 [0] 到 [3] (32-bit words) [cite: 43, 67]
    assert(top->to_ibuffer_instr[0] == 0x00100093 && "[Check FAILED]: Instruction 0 is incorrect.");
    assert(top->to_ibuffer_instr[1] == 0x00200113 && "[Check FAILED]: Instruction 1 is incorrect.");
    assert(top->to_ibuffer_instr[2] == 0x11010111 && "[Check FAILED]: Instruction 2 (JAL) is incorrect.");

    // 檢查PC序列
    // to_ibuffer_pc 是 4x64-bit，分為 [0] 到 [7] (32-bit words) [cite: 40, 66]
    assert(top->to_ibuffer_pc[0] == 0x80000000 && "[Check FAILED]: PC 0 Low is incorrect.");
    assert(top->to_ibuffer_pc[1] == 0x0        && "[Check FAILED]: PC 0 High is incorrect.");
    assert(top->to_ibuffer_pc[2] == 0x80000004 && "[Check FAILED]: PC 1 Low is incorrect.");
    assert(top->to_ibuffer_pc[3] == 0x0        && "[Check FAILED]: PC 1 High is incorrect.");
    assert(top->to_ibuffer_pc[4] == 0x80000008 && "[Check FAILED]: PC 2 Low is incorrect.");
    assert(top->to_ibuffer_pc[5] == 0x0        && "[Check FAILED]: PC 2 High is incorrect.");

    // 1.8 檢查 WB 反饋 (PredChecker 的結果)
    // WB級在F3發射後一拍才有效
    cycle(top.get(), tfp.get());
    std::cout << "Testbench: Checking WB (PredChecker) outputs..." << std::endl;
    
    assert(top->ifu_wb_info_o.valid && "[Check FAILED]: WB info should be valid now.");
    // 檢查誤預測：BPU預測不跳轉(taken=0)，但F3發現了JAL(索引2)，這是誤預測
    assert(top->ifu_wb_info_o.mispredict && "[Check FAILED]: WB should have detected a mispredict.");
    
    // 檢查WB的FTQ索引是否匹配
    assert(top->ifu_wb_info_o.ftqIdx == 1 && "[Check FAILED]: WB ftqIdx mismatch.");

    std::cout << "Testbench: [Scene 1] Sequential Fetch Test (with mispredict) SUCCESS." << std::endl;

    // --- 結束仿真 ---
    cycle(top.get(), tfp.get());
    tfp->close();
    
    return 0;
}