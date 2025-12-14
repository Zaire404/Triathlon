// vsrc/backend/freelist.sv
import config_pkg::*;

module freelist #(
    parameter int unsigned PHY_REG_NUM = 96,        // 物理寄存器总数 (如 32个架构 + 64个ROB)
    parameter int unsigned PHY_REG_ADDR_WIDTH = $clog2(PHY_REG_NUM),
    parameter int unsigned DISPATCH_WIDTH = 4,      // 分配宽度
    parameter int unsigned COMMIT_WIDTH = 4         // 回收宽度
) (
    input logic clk_i,
    input logic rst_ni,
    
    // --- Allocate (From Rename) ---
    input  logic [DISPATCH_WIDTH-1:0] alloc_req_i,  // 请求分配使能 (每条指令一位)
    output logic [DISPATCH_WIDTH-1:0][PHY_REG_ADDR_WIDTH-1:0] alloc_pregs_o, // 分配到的寄存器号
    output logic alloc_can_do_o,                    // 是否有足够的空闲寄存器供分配

    // --- Deallocate (From ROB Commit) ---
    input  logic [COMMIT_WIDTH-1:0] commit_valid_i, // 提交使能
    input  logic [COMMIT_WIDTH-1:0][PHY_REG_ADDR_WIDTH-1:0] commit_opregs_i, // 归还的旧物理寄存器
    
    // --- Flush (From Backend Controller) ---
    input logic flush_i // 异常发生时，需要恢复FreeList状态 (这通常较复杂，这里简化为不处理或需配合RAT快照)
    // 注意：真正的乱序处理器通常通过 "Walk RAT" 或 "Snapshot" 恢复 FreeList，这里暂略复杂恢复逻辑
);

    logic [PHY_REG_ADDR_WIDTH-1:0] mem [PHY_REG_NUM];
    logic [$clog2(PHY_REG_NUM):0] head_ptr, tail_ptr;
    logic [$clog2(PHY_REG_NUM):0] count;

    // 简单计算空闲数量
    assign alloc_can_do_o = (count >= DISPATCH_WIDTH);

    // 逻辑：多端口 FIFO
    // 这是一个行为级描述，综合时需注意多端口RAM的实现，或者用 Banked 结构优化
    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            head_ptr <= '0;
            tail_ptr <= '0;
            count    <= PHY_REG_NUM; 
            // 初始化：把所有 p1..p95 放入 FreeList
            for (int i=1; i<PHY_REG_NUM; i++) mem[i] <= i[PHY_REG_ADDR_WIDTH-1:0];
        end else begin
            // 【修复点 1 & 2】
            // 将变量声明移到 else 块的最顶端，并添加 automatic 关键字
            automatic int pop_cnt = 0;
            automatic int push_cnt = 0;

            // 1. Allocate (Pop)
            if (alloc_can_do_o) begin
                for (int i=0; i<DISPATCH_WIDTH; i++) begin
                    if (alloc_req_i[i]) begin
                        // 注意：这里使用阻塞赋值更新 pop_cnt 是正确的，
                        // 但 mem 读取使用的是当前周期的 head_ptr
                        alloc_pregs_o[i] <= mem[(head_ptr + pop_cnt) % PHY_REG_NUM];
                        pop_cnt++;
                    end
                end
                // 更新 head 指针
                head_ptr <= (head_ptr + pop_cnt) % PHY_REG_NUM;
            end

            // 2. Deallocate (Push)
            for (int i=0; i<COMMIT_WIDTH; i++) begin
                // p0 永远不进 FreeList
                if (commit_valid_i[i] && commit_opregs_i[i] != '0) begin
                    mem[(tail_ptr + push_cnt) % PHY_REG_NUM] <= commit_opregs_i[i];
                    push_cnt++;
                end
            end
            // 更新 tail 指针
            tail_ptr <= (tail_ptr + push_cnt) % PHY_REG_NUM;

            // Update Count
            count <= count - pop_cnt + push_cnt;
        end
    end
endmodule