#include "Vtb_execute.h"
#include "verilated.h"
#include <iostream>
#include <cassert>

void tick(Vtb_execute *top) {
    top->clk_i = 0; top->eval();
    top->clk_i = 1; top->eval();
}

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    Vtb_execute *top = new Vtb_execute;

    // 复位
    top->rst_ni = 0;
    tick(top);
    top->rst_ni = 1;

    // --- 测试 1: 基本加法与 Tag 透传 ---
    std::cout << "Checking ADD & Tag Pass-through..." << std::endl;
    top->alu_op_i = 0; // ALU_ADD
    top->rs1_data_i = 100;
    top->rs2_data_i = 200;
    top->rob_tag_in = 0x2A; // 42
    top->eval();
    
    assert(top->alu_result_o == 300);
    assert(top->rob_tag_out == 0x2A);

    // --- 测试 2: SLT (比较运算) ---
    std::cout << "Checking SLT (Signed Less Than)..." << std::endl;
    top->alu_op_i = 2; // ALU_SLT
    top->rs1_data_i = -50; 
    top->rs2_data_i = 10;
    top->eval();
    assert(top->alu_result_o == 1); // -50 < 10

    // --- 测试 3: Branch 预测失败检查 ---
    // 假设预测是不跳，但满足条件实际跳了
    std::cout << "Checking Branch Misprediction..." << std::endl;
    top->is_branch_i = 1;
    top->br_op_i = 0; // BR_EQ
    top->pc_i = 0x80000000;
    top->imm_i = 0x10;      // 跳转偏移
    top->rs1_data_i = 77;
    top->rs2_data_i = 77;   // 相等，应该跳转
    top->eval();

    assert(top->is_mispred_o == 1); // 预测是不跳，结果跳了，应报误判
    assert(top->redirect_pc_o == 0x80000010); // 正确目标是 PC+Imm

    // --- 测试 4: JAL 返回地址 ---
    std::cout << "Checking JAL Return Address (PC+4)..." << std::endl;
    top->is_branch_i = 0;
    top->is_jump_i = 1;
    top->pc_i = 0x1000;
    top->eval();
    assert(top->alu_result_o == 0x1004); // JAL 写回寄存器的是下一条指令地址

    std::cout << "--- [PASSED] Execute ALU test successful! ---" << std::endl;
    
    delete top;
    return 0;
}