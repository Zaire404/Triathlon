// vsrc/backend/issue_queue.sv
import config_pkg::*;
import decode_pkg::*;

module issue_queue #(
    parameter config_pkg::cfg_t Cfg = config_pkg::EmptyCfg,
    parameter int unsigned QUEUE_DEPTH = 16,
    parameter int unsigned ISSUE_WIDTH = 4, // 发射宽度 (To ALU)
    parameter int unsigned DISPATCH_WIDTH = 4, // 分发宽度 (From Rename)
    parameter int unsigned WB_WIDTH = 4,    // 写回宽度 (From CDB)
    parameter int unsigned ROB_IDX_WIDTH = $clog2(64)
) (
    input logic clk_i,
    input logic rst_ni,

    // =========================================================
    // 1. Dispatch Interface (From Rename/Read Operands)
    // =========================================================
    // 注意：这里的 operand_data 必须在外部通过读 ROB/ARF 准备好
    input logic [DISPATCH_WIDTH-1:0]      disp_valid_i,
    input decode_pkg::uop_t [DISPATCH_WIDTH-1:0] disp_uops_i,
    input logic [DISPATCH_WIDTH-1:0][ROB_IDX_WIDTH-1:0] disp_rob_idx_i, // 指令自身的 ROB ID
    
    // 源操作数 1 状态
    input logic [DISPATCH_WIDTH-1:0]      disp_rs1_ready_i, // 1: 数据已就绪(在data中); 0: 未就绪(用tag)
    input logic [DISPATCH_WIDTH-1:0][ROB_IDX_WIDTH-1:0] disp_rs1_tag_i,
    input logic [DISPATCH_WIDTH-1:0][Cfg.XLEN-1:0]       disp_rs1_data_i, // 从 ARF/ROB 读到的初始值

    // 源操作数 2 状态
    input logic [DISPATCH_WIDTH-1:0]      disp_rs2_ready_i,
    input logic [DISPATCH_WIDTH-1:0][ROB_IDX_WIDTH-1:0] disp_rs2_tag_i,
    input logic [DISPATCH_WIDTH-1:0][Cfg.XLEN-1:0]       disp_rs2_data_i,

    output logic full_o, // 队列满，停止 Rename

    // =========================================================
    // 2. Writeback / CDB Interface (For Wakeup & Capture)
    // =========================================================
    // 监听旁路网络，捕捉数据
    input logic [WB_WIDTH-1:0]       wb_valid_i,
    input logic [WB_WIDTH-1:0][ROB_IDX_WIDTH-1:0] wb_tag_i,
    input logic [WB_WIDTH-1:0][Cfg.XLEN-1:0]      wb_data_i,

    // =========================================================
    // 3. Issue Interface (To Execute)
    // =========================================================
    output logic [ISSUE_WIDTH-1:0]       issue_valid_o,
    output decode_pkg::uop_t [ISSUE_WIDTH-1:0] issue_uops_o,
    // 发射出去的指令直接携带了源操作数数据
    output logic [ISSUE_WIDTH-1:0][Cfg.XLEN-1:0] issue_rs1_data_o, 
    output logic [ISSUE_WIDTH-1:0][Cfg.XLEN-1:0] issue_rs2_data_o,
    output logic [ISSUE_WIDTH-1:0][ROB_IDX_WIDTH-1:0] issue_rob_idx_o,

    // Control
    input logic flush_i
);

    // --- Issue Queue Entry 结构定义 ---
    typedef struct packed {
        logic valid;
        decode_pkg::uop_t uop;
        logic [ROB_IDX_WIDTH-1:0] rob_idx;

        // 源操作数 1 (Payload RAM 部分)
        logic s1_ready;
        logic [ROB_IDX_WIDTH-1:0] s1_tag;
        logic [Cfg.XLEN-1:0]      s1_data; // 捕捉到的数据

        // 源操作数 2 (Payload RAM 部分)
        logic s2_ready;
        logic [ROB_IDX_WIDTH-1:0] s2_tag;
        logic [Cfg.XLEN-1:0]      s2_data; // 捕捉到的数据
    } entry_t;

    entry_t [QUEUE_DEPTH-1:0] queue;
    logic   [QUEUE_DEPTH-1:0] allocated_mask; // 辅助逻辑，标记本周期刚分配的槽位

    // 计算空闲数量
    logic [$clog2(QUEUE_DEPTH):0] count;
    assign full_o = (count > (QUEUE_DEPTH - DISPATCH_WIDTH));

    // =========================================================
    // Main Logic
    // =========================================================
    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            for(int i=0; i<QUEUE_DEPTH; i++) queue[i].valid <= 1'b0;
            count <= 0;
        end else if (flush_i) begin
            for(int i=0; i<QUEUE_DEPTH; i++) queue[i].valid <= 1'b0;
            count <= 0;
        end else begin
            
            // -------------------------------------------------
            // 1. Wakeup & Capture Logic (CDB 监听)
            // -------------------------------------------------
            // 遍历所有 Valid 的条目，检查 Tag 是否匹配 CDB
            for (int i = 0; i < QUEUE_DEPTH; i++) begin
                if (queue[i].valid) begin
                    // 检查 4 个写回通道
                    for (int w = 0; w < WB_WIDTH; w++) begin
                        if (wb_valid_i[w]) begin
                            // Capture Source 1
                            if (!queue[i].s1_ready && queue[i].s1_tag == wb_tag_i[w]) begin
                                queue[i].s1_ready <= 1'b1;
                                queue[i].s1_data  <= wb_data_i[w]; // 【数据捕捉】
                            end
                            // Capture Source 2
                            if (!queue[i].s2_ready && queue[i].s2_tag == wb_tag_i[w]) begin
                                queue[i].s2_ready <= 1'b1;
                                queue[i].s2_data  <= wb_data_i[w]; // 【数据捕捉】
                            end
                        end
                    end
                end
            end

            // -------------------------------------------------
            // 2. Allocation Logic (Dispatch)
            // -------------------------------------------------
            // 简单的分配逻辑：寻找 valid=0 的空槽
            // 注意：这里需要处理 "Dispatch 数据" 和 "CDB 数据" 在同一周期到达的 Corner Case
            automatic int alloc_ptr = 0;
            
            for (int d = 0; d < DISPATCH_WIDTH; d++) begin
                if (disp_valid_i[d]) begin
                    // 寻找下一个空闲位置
                    while (alloc_ptr < QUEUE_DEPTH && queue[alloc_ptr].valid) begin
                        alloc_ptr++;
                    end
                    
                    if (alloc_ptr < QUEUE_DEPTH) begin
                        queue[alloc_ptr].valid   <= 1'b1;
                        queue[alloc_ptr].uop     <= disp_uops_i[d];
                        queue[alloc_ptr].rob_idx <= disp_rob_idx_i[d];

                        // --- Source 1 初始化 ---
                        if (disp_rs1_ready_i[d]) begin
                            queue[alloc_ptr].s1_ready <= 1'b1;
                            queue[alloc_ptr].s1_data  <= disp_rs1_data_i[d];
                        end else begin
                            // 检查是否刚好在 CDB 上 (Forwarding during Dispatch)
                            logic match_cdb = 0;
                            logic [Cfg.XLEN-1:0] fwd_data;
                            for (int w=0; w<WB_WIDTH; w++) begin
                                if (wb_valid_i[w] && wb_tag_i[w] == disp_rs1_tag_i[d]) begin
                                    match_cdb = 1;
                                    fwd_data = wb_data_i[w];
                                end
                            end
                            
                            if (match_cdb) begin
                                queue[alloc_ptr].s1_ready <= 1'b1;
                                queue[alloc_ptr].s1_data  <= fwd_data;
                            end else begin
                                queue[alloc_ptr].s1_ready <= 1'b0;
                                queue[alloc_ptr].s1_tag   <= disp_rs1_tag_i[d];
                            end
                        end

                        // --- Source 2 初始化 (同上) ---
                        if (disp_rs2_ready_i[d]) begin
                            queue[alloc_ptr].s2_ready <= 1'b1;
                            queue[alloc_ptr].s2_data  <= disp_rs2_data_i[d];
                        end else begin
                             logic match_cdb = 0;
                             logic [Cfg.XLEN-1:0] fwd_data;
                             for (int w=0; w<WB_WIDTH; w++) begin
                                if (wb_valid_i[w] && wb_tag_i[w] == disp_rs2_tag_i[d]) begin
                                    match_cdb = 1;
                                    fwd_data = wb_data_i[w];
                                end
                            end

                            if (match_cdb) begin
                                queue[alloc_ptr].s2_ready <= 1'b1;
                                queue[alloc_ptr].s2_data  <= fwd_data;
                            end else begin
                                queue[alloc_ptr].s2_ready <= 1'b0;
                                queue[alloc_ptr].s2_tag   <= disp_rs2_tag_i[d];
                            end
                        end
                        
                        // 标记该位置已被暂用，避免下一次循环重复使用
                        // (SystemVerilog 仿真中 loop 内的变量不是立即更新的，这里简化处理)
                        alloc_ptr++; 
                    end
                end
            end

            // -------------------------------------------------
            // 3. Issue / Deallocation (Select)
            // -------------------------------------------------
            // 简单的选择逻辑：选择 valid 且两个操作数都 ready 的指令
            // 这里的 issue_granted 是组合逻辑计算的结果 (见下方 always_comb)
            for (int i = 0; i < QUEUE_DEPTH; i++) begin
                if (issue_granted[i]) begin
                    queue[i].valid <= 1'b0; // 发射后释放条目
                end
            end
            
            // 更新计数 (简化计算)
            // count <= ...
        end
    end

    // =========================================================
    // Select Logic (Combinational)
    // =========================================================
    logic [QUEUE_DEPTH-1:0] issue_granted;
    
    always_comb begin
        issue_valid_o   = '0;
        issue_uops_o    = '0;
        issue_rs1_data_o= '0;
        issue_rs2_data_o= '0;
        issue_rob_idx_o = '0;
        issue_granted   = '0;

        automatic int issued_cnt = 0;

        for (int i = 0; i < QUEUE_DEPTH; i++) begin
            // 检查是否准备好发射：Valid + Src1 Ready + Src2 Ready
            if (queue[i].valid && queue[i].s1_ready && queue[i].s2_ready && issued_cnt < ISSUE_WIDTH) begin
                
                // 简单的 First-Ready-First-Issue 策略
                // 实际硬件可能需要 Age-based 或者 Matrix Scheduler
                
                issue_valid_o[issued_cnt]    = 1'b1;
                issue_uops_o[issued_cnt]     = queue[i].uop;
                issue_rs1_data_o[issued_cnt] = queue[i].s1_data; // 直接发送 Payload RAM 中的数据
                issue_rs2_data_o[issued_cnt] = queue[i].s2_data;
                issue_rob_idx_o[issued_cnt]  = queue[i].rob_idx;
                
                issue_granted[i] = 1'b1; // 标记以便在时序逻辑中清除 valid
                issued_cnt++;
            end
        end
    end

endmodule