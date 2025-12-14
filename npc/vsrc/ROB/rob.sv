module ROB #(
    parameter ROB_SIZE = 8,  // 定义重排序缓冲区（ROB）的大小
    parameter NUM_REGISTERS = 32, // 定义架构寄存器的数量
    parameter ISSUE_WIDTH = 4 // 每周期发射4条指令
)(
    input logic clk,
    input logic rst_n,
    input logic [31:0] instruction_ids [0:ISSUE_WIDTH-1], // 4条指令的ID
    input logic [4:0] src_regs [0:ISSUE_WIDTH-1][0:2], // 每条指令的3个源寄存器
    input logic [4:0] dst_regs [0:ISSUE_WIDTH-1], // 每条指令的目标寄存器
    input logic write_enable,  // 写入ROB的使能信号
    input logic commit_enable, // 提交指令的使能信号
    input logic branch_predict_fail, // 分支预测失败信号
    output logic [31:0] physical_reg_out [0:ISSUE_WIDTH-1], // 输出映射到的物理寄存器
    output logic rob_full, // 表示ROB是否已满
    output logic [31:0] rob_state // 用于调试，显示ROB的当前状态
);

    // 定义ROB条目的结构体
    typedef struct packed {
        logic [31:0] instruction_id;  // 指令ID
        logic [31:0] physical_reg;    // 物理寄存器
        logic ready;                  // 指令是否准备好提交
        logic [31:0] dependent_id;    // 当前指令的依赖指令ID
        logic [31:0] source_regs [0:2];  // 每条指令的源寄存器
        logic dest_reg;           // 目标寄存器
        logic [31:0] old_physical_reg; // 保存旧物理寄存器映射，用于恢复
    } rob_entry_t;

    // 定义ROB数组
    rob_entry_t rob [0:ROB_SIZE-1];
    // 架构寄存器到物理寄存器的重命名表（sRAT）
    logic [31:0] rename_table [0:NUM_REGISTERS-1]; // 每个架构寄存器映射到物理寄存器
    // 存储每个逻辑寄存器在ROB或ARF中的位置
    logic [31:0] rat_table [0:NUM_REGISTERS-1]; // 重命名映射表：指示每个寄存器存储的位置（ROB或ARF）
    // 物理寄存器空闲标志
    logic [31:0] free_physical_registers; // 空闲物理寄存器位图

    // 初始化ROB和重命名表
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            // 重置ROB条目
            for (int i = 0; i < ROB_SIZE; i++) begin
                rob[i].instruction_id = 32'b0;
                rob[i].physical_reg = 32'b0;
                rob[i].ready = 1'b0;
                rob[i].dependent_id = 32'b0;
                rob[i].dest_reg = 32'b0;
                rob[i].old_physical_reg = 32'b0;
            end
            // 重置重命名表
            for (int i = 0; i < NUM_REGISTERS; i++) begin
                rename_table[i] = 32'b0;
                rat_table[i] = 32'b0; // 默认所有寄存器都存储在ARF中
            end
            free_physical_registers = 32'hFFFFFFFF; // 默认所有物理寄存器都为空闲状态
        end else begin
            if (write_enable) begin
                // 进行寄存器重命名并处理依赖关系
                process_dependencies_and_rename(instruction_ids, src_regs, dst_regs);
            end

            if (commit_enable) begin
                // 提交ROB中准备好的条目
                commit_rob();
            end

            // 如果发生分支预测失败，恢复RAT
            if (branch_predict_fail) begin
                restore_rat();
            end
        end
    end

    // 处理依赖关系并进行寄存器重命名
    task process_dependencies_and_rename(input logic [31:0] inst_ids[0:ISSUE_WIDTH-1], 
                                          input logic [4:0] src_regs[0:ISSUE_WIDTH-1][0:2], 
                                          input logic [4:0] dst_regs[0:ISSUE_WIDTH-1]);
        logic [31:0] updated_src_regs [0:ISSUE_WIDTH-1][0:2]; // 存储更新后的源寄存器
        logic [31:0] temp_src_regs [0:2]; // 临时保存源寄存器

        // 并行处理四条指令的依赖关系
        for (int i = 0; i < ISSUE_WIDTH; i++) begin
            // 复制当前指令的源寄存器
            temp_src_regs = src_regs[i];

            // 检查每条指令的RAW依赖
            for (int j = 0; j < ISSUE_WIDTH; j++) begin
                if (i != j) begin
                    // 如果指令i的源寄存器依赖于指令j的目标寄存器
                    for (int k = 0; k < 3; k++) begin
                        if (src_regs[i][k] == dst_regs[j]) begin
                            // 将源寄存器映射到目标寄存器
                            temp_src_regs[k] = rename_table[dst_regs[j]];
                        end
                    end
                end
            end

            // 更新指令i的源寄存器（使用映射后的值）
            updated_src_regs[i] = temp_src_regs;

            // 寄存器重命名：将目标寄存器映射为新的物理寄存器
            rename_table[dst_regs[i]] = allocate_physical_register(dst_regs[i]);
            // 保存旧映射关系，用于恢复
            rob[i].old_physical_reg = rat_table[dst_regs[i]]; 
            // 更新RAT：指示目标寄存器在ROB中的位置
            rat_table[dst_regs[i]] = rob[i].physical_reg;
        end

        // 更新四条指令的源寄存器
        for (int i = 0; i < ISSUE_WIDTH; i++) begin
            src_regs[i] = updated_src_regs[i];
        end
    endtask

    // 分配一个新的物理寄存器
    function automatic logic [31:0] allocate_physical_register(input logic [4:0] arch_reg);
        // 如果重命名表中已有该映射，直接返回对应的物理寄存器
        if (rename_table[arch_reg] != 32'b0) begin
            return rename_table[arch_reg];
        end else begin
            // 否则，分配一个新的物理寄存器
            return next_free_reg++;
        end
    endfunction

    // 提交ROB中准备好的条目
    task commit_rob();
        for (int i = 0; i < ROB_SIZE; i++) begin
            if (rob[i].ready) begin
                // 将ROB中指令的结果写入ARF，并更新RAT
                rat_table[rob[i].dest_reg] = rob[i].physical_reg;
                rob[i].instruction_id = 32'b0;
                rob[i].physical_reg = 32'b0;
                rob[i].ready = 1'b0;
                rob[i].dependent_id = 32'b0;
                rob[i].dest_reg = 32'b0;
            end
        end
    endtask

    // 恢复RAT
    task restore_rat();
        for (int i = 0; i < ROB_SIZE; i++) begin
            // 如果有分支预测失败，恢复RAT中的映射关系
            if (rob[i].ready) begin
                rat_table[rob[i].dest_reg] = rob[i].old_physical_reg;
            end
        end
    endtask

    // 检查ROB是否已满
    assign rob_full = (rob[ROB_SIZE-1].instruction_id != 32'b0);

    // 调试输出：显示当前ROB的状态
    assign rob_state = {rob[0].instruction_id, rob[1].instruction_id, rob[2].instruction_id, rob[3].instruction_id};

endmodule
