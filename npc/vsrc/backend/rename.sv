// vsrc/backend/rename.sv (Data-in-ROB Version with Flush Masking)
import config_pkg::*;
import decode_pkg::*;

module rename #(
    parameter config_pkg::cfg_t Cfg = config_pkg::EmptyCfg,
    parameter int unsigned ROB_DEPTH = 64,
    parameter int unsigned ROB_IDX_WIDTH = $clog2(ROB_DEPTH)
) (
    input logic clk_i,
    input logic rst_ni,

    // --- From Decoder ---
    input logic [3:0] dec_valid_i,
    input decode_pkg::uop_t [3:0] dec_uops_i,
    output logic rename_ready_o, // 告诉 Decoder 可以发指令 (ROB有空位)

    // --- To ROB (Dispatch Interface) ---
    // Rename 阶段顺便把指令分发给 ROB
    output logic [3:0] rob_dispatch_valid_o,
    output logic [3:0][Cfg.PLEN-1:0] rob_dispatch_pc_o,
    output decode_pkg::fu_e [3:0]    rob_dispatch_fu_type_o,
    output logic [3:0][4:0]          rob_dispatch_areg_o,
    
    // 输入 ROB 的状态，用于生成 Tag
    input  logic rob_ready_i,                 // ROB 不满
    input  logic [ROB_IDX_WIDTH-1:0] rob_tail_ptr_i, // ROB 当前的尾指针 (用于生成 Tag)

    // --- To Issue Queue / Dispatcher ---
    output logic [3:0] issue_valid_o,
    // 源操作数 Tag (如果 in_rob=1, 则是 ROB ID; 否则无效)
    output logic [3:0] issue_rs1_in_rob_o,
    output logic [3:0][ROB_IDX_WIDTH-1:0] issue_rs1_rob_idx_o,
    output logic [3:0] issue_rs2_in_rob_o,
    output logic [3:0][ROB_IDX_WIDTH-1:0] issue_rs2_rob_idx_o,
    // 目标 Tag (分配给这条指令的 ROB ID)
    output logic [3:0][ROB_IDX_WIDTH-1:0] issue_rd_rob_idx_o,

    // --- From ROB Commit (用于更新 RAT 状态) ---
    input logic [3:0] commit_valid_i,
    input logic [3:0][4:0] commit_areg_i,
    input logic [3:0][ROB_IDX_WIDTH-1:0] commit_rob_idx_i, // 退休指令的 ID

    input logic flush_i
);

    // ---------------------------------------------------------
    // 0. Flush 门控 (Flush Masking)
    // ---------------------------------------------------------
    // 关键逻辑：如果当前周期发生 flush，或者 Decoder 发来的指令无效，则不进行分配。
    // 这可以防止旧路径的指令在 Flush 发生的同一拍挤进 ROB。
    logic [3:0] dec_valid_masked;
    
    always_comb begin
        for (int i=0; i<4; i++) begin
            dec_valid_masked[i] = dec_valid_i[i] && !flush_i;
        end
    end

    // ---------------------------------------------------------
    // 1. 生成新的 Tags (物理寄存器号 / ROB ID)
    // ---------------------------------------------------------
    // 在 Data-in-ROB 架构中，Tag 就是 ROB ID。
    // 第 0 条指令分到的 Tag 是 Tail; 第 1 条是 Tail+1 ...
    logic [3:0][ROB_IDX_WIDTH-1:0] new_tags;
    logic [3:0] alloc_req;

    always_comb begin
        for (int i=0; i<4; i++) begin
            // 简单的加法计算 Tag (利用位宽溢出自动回绕，或者显式取模)
            new_tags[i] = (rob_tail_ptr_i + i) % ROB_DEPTH;
            
            // 只有有效且写寄存器的指令才需要更新 RAT
            // 注意：这里使用的是 masked 信号
            alloc_req[i] = dec_valid_masked[i] && dec_uops_i[i].has_rd && (dec_uops_i[i].rd != 0);
        end
    end

    // ---------------------------------------------------------
    // 2. RAT 读写 (查表 + 更新)
    // ---------------------------------------------------------
    logic [3:0]       rat_rs1_in_rob, rat_rs2_in_rob;
    logic [3:0][ROB_IDX_WIDTH-1:0] rat_rs1_tag, rat_rs2_tag;

    // RAT 实例化
    rat #(
        .ROB_DEPTH(ROB_DEPTH)
    ) u_rat (
        .clk_i, .rst_ni,
        // 读端口 (查源操作数)
        .rs1_idx_i(get_rs1_indices(dec_uops_i)), // 辅助函数提取 index
        .rs2_idx_i(get_rs2_indices(dec_uops_i)),
        .rs1_in_rob_o(rat_rs1_in_rob), .rs1_rob_idx_o(rat_rs1_tag),
        .rs2_in_rob_o(rat_rs2_in_rob), .rs2_rob_idx_o(rat_rs2_tag),

        // 写端口 (Allocation: 建立 逻辑寄存器 -> 新 ROB ID 的映射)
        .disp_we_i(alloc_req),
        .disp_rd_idx_i(get_rd_indices(dec_uops_i)),
        .disp_rob_idx_i(new_tags), // 直接写入计算出的 ROB ID

        // 提交端口 (Retirement: 清除旧的 Speculative 状态)
        .commit_we_i(commit_valid_i),
        .commit_rd_idx_i(commit_areg_i),
        .commit_rob_idx_i(commit_rob_idx_i),

        .flush_i(flush_i)
    );

    // ---------------------------------------------------------
    // 3. 组内依赖检查 (Intra-group Dependency Check)
    // ---------------------------------------------------------
    // 处理同一周期发射的指令之间的 RAW 依赖
    logic [3:0]       final_rs1_in_rob, final_rs2_in_rob;
    logic [3:0][ROB_IDX_WIDTH-1:0] final_rs1_tag, final_rs2_tag;

    always_comb begin
        // 默认来自 RAT
        final_rs1_in_rob = rat_rs1_in_rob;
        final_rs1_tag    = rat_rs1_tag;
        final_rs2_in_rob = rat_rs2_in_rob;
        final_rs2_tag    = rat_rs2_tag;

        // 检查前面的指令是否写了我的源寄存器
        for (int i=1; i<4; i++) begin
            for (int j=0; j<i; j++) begin
                // 如果 Instr i 的 RS1 依赖 Instr j 的 RD (且 Instr j 确实要写)
                if (alloc_req[j] && dec_uops_i[i].has_rs1 && (dec_uops_i[i].rs1 == dec_uops_i[j].rd)) begin
                    final_rs1_in_rob[i] = 1'b1;         // 数据肯定在 ROB (因为 Instr j 刚分进去)
                    final_rs1_tag[i]    = new_tags[j];  // 也就是 Instr j 分到的 ROB ID
                end
                // 检查 RS2
                if (alloc_req[j] && dec_uops_i[i].has_rs2 && (dec_uops_i[i].rs2 == dec_uops_i[j].rd)) begin
                    final_rs2_in_rob[i] = 1'b1;
                    final_rs2_tag[i]    = new_tags[j];
                end
            end
        end
    end

    // ---------------------------------------------------------
    // 4. 输出打包
    // ---------------------------------------------------------
    // 只要 ROB 没满，Rename 就 Ready (因为不需要等 FreeList)
    assign rename_ready_o = rob_ready_i;

    always_comb begin
        for (int i=0; i<4; i++) begin
            // 只有当 ROB 准备好，且指令有效（经过 Flush Masking）时才发送
            if (rename_ready_o && dec_valid_masked[i]) begin
                // 发送给 ROB
                rob_dispatch_valid_o[i]   = 1'b1;
                rob_dispatch_pc_o[i]      = dec_uops_i[i].pc;
                rob_dispatch_fu_type_o[i] = dec_uops_i[i].fu;
                rob_dispatch_areg_o[i]    = dec_uops_i[i].rd;
                // 注意：不再需要发送 preg 或 opreg 给 ROB，因为 ROB 自己知道自己的 ID

                // 发送给 Issue Queue
                issue_valid_o[i]       = 1'b1;
                issue_rs1_in_rob_o[i]  = final_rs1_in_rob[i];
                issue_rs1_rob_idx_o[i] = final_rs1_tag[i];
                issue_rs2_in_rob_o[i]  = final_rs2_in_rob[i];
                issue_rs2_rob_idx_o[i] = final_rs2_tag[i];
                // 目标 Tag 就是这条指令在 ROB 中的位置 (ROB ID)
                issue_rd_rob_idx_o[i]  = new_tags[i]; 

            end else begin
                rob_dispatch_valid_o[i] = 0;
                rob_dispatch_pc_o[i]    = '0;
                rob_dispatch_fu_type_o[i] = decode_pkg::FU_NONE;
                rob_dispatch_areg_o[i]  = '0;

                issue_valid_o[i]        = 0;
                issue_rs1_in_rob_o[i]   = 0;
                issue_rs1_rob_idx_o[i]  = '0;
                issue_rs2_in_rob_o[i]   = 0;
                issue_rs2_rob_idx_o[i]  = '0;
                issue_rd_rob_idx_o[i]   = '0;
            end
        end
    end

    // 辅助函数 (SystemVerilog 不支持在端口直接切片结构体数组)
    function automatic logic [3:0][4:0] get_rs1_indices(decode_pkg::uop_t [3:0] uops);
        for(int k=0; k<4; k++) get_rs1_indices[k] = uops[k].rs1;
    endfunction
    function automatic logic [3:0][4:0] get_rs2_indices(decode_pkg::uop_t [3:0] uops);
        for(int k=0; k<4; k++) get_rs2_indices[k] = uops[k].rs2;
    endfunction
    function automatic logic [3:0][4:0] get_rd_indices(decode_pkg::uop_t [3:0] uops);
        for(int k=0; k<4; k++) get_rd_indices[k] = uops[k].rd;
    endfunction

endmodule