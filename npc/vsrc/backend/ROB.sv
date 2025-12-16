// vsrc/backend/ROB.sv
import config_pkg::*;
import decode_pkg::*;

module rob #(
    parameter config_pkg::cfg_t Cfg = config_pkg::EmptyCfg,
    parameter int unsigned ROB_DEPTH = 64,
    parameter int unsigned DISPATCH_WIDTH = Cfg.INSTR_PER_FETCH, 
    parameter int unsigned COMMIT_WIDTH = Cfg.NRET,    
    parameter int unsigned WB_WIDTH = 4                
) (
    input logic clk_i,
    input logic rst_ni,

    // =========================================================
    // 1. Dispatch 阶段 (From Rename)
    // =========================================================
    input  logic [DISPATCH_WIDTH-1:0] dispatch_valid_i,
    input  logic [DISPATCH_WIDTH-1:0][Cfg.PLEN-1:0] dispatch_pc_i,
    input  decode_pkg::fu_e [DISPATCH_WIDTH-1:0]    dispatch_fu_type_i,
    input  logic [DISPATCH_WIDTH-1:0][4:0]          dispatch_areg_i,
    
    output logic rob_ready_o, 
    output logic [DISPATCH_WIDTH-1:0][$clog2(ROB_DEPTH)-1:0] dispatch_rob_index_o,

    // =========================================================
    // 2. Writeback 阶段 (From ALU/LSU/Branch Unit)
    // =========================================================
    input logic [WB_WIDTH-1:0] wb_valid_i,
    input logic [WB_WIDTH-1:0][$clog2(ROB_DEPTH)-1:0] wb_rob_index_i, 
    input logic [WB_WIDTH-1:0][Cfg.XLEN-1:0] wb_data_i, 
    
    // 异常接口
    input logic [WB_WIDTH-1:0] wb_exception_i,
    input logic [WB_WIDTH-1:0][4:0] wb_ecause_i,

    // 分支误预测接口
    input logic [WB_WIDTH-1:0] wb_is_mispred_i,  
    input logic [WB_WIDTH-1:0][Cfg.PLEN-1:0] wb_redirect_pc_i, 

    // =========================================================
    // 3. Commit 阶段 (To ARF & Controller & RAT)
    // =========================================================
    output logic [COMMIT_WIDTH-1:0] commit_valid_o,
    output logic [COMMIT_WIDTH-1:0][Cfg.PLEN-1:0] commit_pc_o, 
    
    // To ARF
    output logic [COMMIT_WIDTH-1:0]       commit_we_o,
    output logic [COMMIT_WIDTH-1:0][4:0]  commit_areg_o,
    output logic [COMMIT_WIDTH-1:0][Cfg.XLEN-1:0] commit_wdata_o,

    // To RAT: 输出退休指令在 ROB 中的 ID (Head Ptr)
    // 用于 RAT 判断 "Retired Instruction == Latest Mapping?"
    output logic [COMMIT_WIDTH-1:0][$clog2(ROB_DEPTH)-1:0] commit_rob_index_o,

    // To Store Buffer
    output logic [COMMIT_WIDTH-1:0] commit_is_store_o, 

    // Flush Interface (To Frontend & Backend)
    output logic flush_o,
    output logic [Cfg.PLEN-1:0] flush_pc_o, 
    output logic [4:0] flush_cause_o,

    // Status
    output logic rob_empty_o,
    output logic rob_full_o
);
    localparam int unsigned PTR_WIDTH = $clog2(ROB_DEPTH);

    // 定义每个周期允许退休的最大指令类型数量 (结构冒险限制)
    localparam int unsigned MAX_COMMIT_BR = 1; // 限制: 每周期最多 1 条分支 (更新 BPU)
    localparam int unsigned MAX_COMMIT_ST = 1; // 限制: 每周期最多 1 条 Store (写入 Store Buffer)
    localparam int unsigned MAX_COMMIT_LD = 2; // 限制: 每周期最多 2 条 Load

    typedef struct packed {
        logic complete;
        logic exception;
        logic [4:0] ecause;
        logic is_mispred;
        logic [Cfg.PLEN-1:0] redirect_pc;
        decode_pkg::fu_e fu_type; 
        logic [4:0] areg;       
        logic [Cfg.XLEN-1:0] data; 
        logic [Cfg.PLEN-1:0] pc; 
    } rob_entry_t;

    rob_entry_t [ROB_DEPTH-1:0] rob_ram;
    
    logic [PTR_WIDTH-1:0] head_ptr_q, head_ptr_d;
    logic [PTR_WIDTH-1:0] tail_ptr_q, tail_ptr_d;
    logic [$clog2(ROB_DEPTH+1)-1:0] count_q, count_d;

    // ... (Full/Empty 逻辑) ...
    assign rob_full_o  = (count_q > (ROB_DEPTH - DISPATCH_WIDTH));
    assign rob_empty_o = (count_q == 0);
    assign rob_ready_o = !rob_full_o;

    // 返回给 Rename 的 ROB ID
    always_comb begin
        for (int i = 0; i < DISPATCH_WIDTH; i++) begin
            dispatch_rob_index_o[i] = tail_ptr_q + i[PTR_WIDTH-1:0];
        end
    end

    // =========================================================
    // Commit Logic (Resource Limit & Masking)
    // =========================================================
    logic stop_commit;
    
    // 定义资源限制掩码
    logic [COMMIT_WIDTH-1:0] br_mask, st_mask, ld_mask;
    logic [COMMIT_WIDTH-1:0] commit_permitted_mask;

    always_comb begin
        stop_commit = 1'b0;
        flush_o = 1'b0;
        flush_pc_o = '0;
        flush_cause_o = '0;

        // 默认输出清零
        commit_valid_o = '0;
        commit_pc_o    = '0;
        commit_we_o    = '0;
        commit_areg_o  = '0;
        commit_wdata_o = '0;
        commit_is_store_o = '0;
        commit_rob_index_o = '0; 

        // -----------------------------------------------------------------
        // 1. 生成资源限制掩码 (Parallel Check Circuits)
        // -----------------------------------------------------------------
        // 使用 automatic 变量在组合逻辑中临时计数
        automatic int cnt_br = 0;
        automatic int cnt_st = 0;
        automatic int cnt_ld = 0;

        br_mask = '1; // 默认允许
        st_mask = '1;
        ld_mask = '1;

        for (int i = 0; i < COMMIT_WIDTH; i++) begin
            logic [PTR_WIDTH-1:0] check_idx;
            // 预测提交窗口内的指令索引
            check_idx = head_ptr_q + i[PTR_WIDTH-1:0];
            
            // 只有当 ROB 中该位置确实有有效指令时才检查
            if (count_q > i) begin
                // --- Check Branch Limit ---
                if (rob_ram[check_idx].fu_type == decode_pkg::FU_BRANCH) begin
                    if (cnt_br >= MAX_COMMIT_BR) br_mask[i] = 1'b0; // 超过配额，屏蔽该指令
                    cnt_br++;
                end

                // --- Check Store Limit ---
                // Store: LSU type and no destination register (rd=0)
                if (rob_ram[check_idx].fu_type == decode_pkg::FU_LSU && rob_ram[check_idx].areg == 0) begin 
                    if (cnt_st >= MAX_COMMIT_ST) st_mask[i] = 1'b0;
                    cnt_st++;
                end

                // --- Check Load Limit ---
                // Load: LSU type and has destination register (rd!=0)
                if (rob_ram[check_idx].fu_type == decode_pkg::FU_LSU && rob_ram[check_idx].areg != 0) begin
                    if (cnt_ld >= MAX_COMMIT_LD) ld_mask[i] = 1'b0;
                    cnt_ld++;
                end
            end
        end

        // 综合掩码：只要有一个资源受限，该指令就不能退休
        commit_permitted_mask = br_mask & st_mask & ld_mask;

        // -----------------------------------------------------------------
        // 2. 最终提交循环 (Final Commit Loop)
        // -----------------------------------------------------------------
        for (int i = 0; i < COMMIT_WIDTH; i++) begin
            logic [PTR_WIDTH-1:0] idx;
            idx = head_ptr_q + i[PTR_WIDTH-1:0];

            // 始终输出 ROB ID 给 RAT (无论是否退休)
            commit_rob_index_o[i] = idx; 

            // 退休条件：
            // 1. ROB 中有这条指令 (count > i)
            // 2. 之前的指令没有发生阻塞 (!stop_commit)
            // 3. 资源掩码允许 (commit_permitted_mask[i])
            if ((count_q > i) && !stop_commit && commit_permitted_mask[i]) begin
                
                // 检查指令是否执行完毕 (Complete)
                if (rob_ram[idx].complete) begin
                    
                    // --- Case A: 异常处理 (Exception) ---
                    if (rob_ram[idx].exception) begin
                        stop_commit   = 1'b1;
                        flush_o       = 1'b1;
                        flush_pc_o    = rob_ram[idx].pc;    // 异常时记录指令 PC (给 CSR mepc)
                        flush_cause_o = rob_ram[idx].ecause; // 异常原因
                    end 
                    
                    // --- Case B: 分支预测失败 (Misprediction) ---
                    else if (rob_ram[idx].is_mispred) begin
                        stop_commit   = 1'b1;
                        flush_o       = 1'b1;
                        flush_pc_o    = rob_ram[idx].redirect_pc; // 误预测时跳到正确目标
                    end
                    
                    // --- Case C: 正常退休 (Normal Retire) ---
                    else begin
                        commit_valid_o[i] = 1'b1;
                        commit_pc_o[i]    = rob_ram[idx].pc;
                        
                        // 写回 ARF
                        commit_areg_o[i]  = rob_ram[idx].areg;
                        commit_wdata_o[i] = rob_ram[idx].data;
                        if (rob_ram[idx].areg != 0) begin
                            commit_we_o[i] = 1'b1;
                        end

                        // 通知 Store Buffer
                        commit_is_store_o[i] = (rob_ram[idx].fu_type == decode_pkg::FU_LSU) && 
                                               (rob_ram[idx].areg == '0);
                    end

                end else begin
                    // 指令尚未执行完毕 (Complete = 0)
                    // 队头阻塞：这条指令和它之后的所有指令都不能退休
                    stop_commit = 1'b1;
                end
            end else begin
                // 指令不存在，或被前面的指令阻塞，或被资源掩码屏蔽
                stop_commit = 1'b1;
            end
        end
    end

    // =========================================================
    // Counter & Pointers Logic
    // =========================================================
    logic [$clog2(DISPATCH_WIDTH+1)-1:0] dispatch_cnt;
    logic [$clog2(COMMIT_WIDTH+1)-1:0]   commit_cnt;

    always_comb begin
        dispatch_cnt = 0;
        if (rob_ready_o) begin
            for (int i = 0; i < DISPATCH_WIDTH; i++) begin
                if (dispatch_valid_i[i]) dispatch_cnt++;
            end
        end
        commit_cnt = 0;
        for (int i = 0; i < COMMIT_WIDTH; i++) begin
            if (commit_valid_o[i]) commit_cnt++;
        end
    end

    assign tail_ptr_d = tail_ptr_q + PTR_WIDTH'(dispatch_cnt);
    assign head_ptr_d = head_ptr_q + PTR_WIDTH'(commit_cnt);
    assign count_d    = count_q + dispatch_cnt - commit_cnt;

    // =========================================================
    // Sequential Logic
    // =========================================================
    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            head_ptr_q <= '0;
            tail_ptr_q <= '0;
            count_q    <= '0;
        end else if (flush_o) begin
            // 收到 Flush 信号，立即清空 ROB
            head_ptr_q <= '0;
            tail_ptr_q <= '0;
            count_q    <= '0;
        end else begin
            head_ptr_q <= head_ptr_d;
            tail_ptr_q <= tail_ptr_d;
            count_q    <= count_d;

            // 1. Dispatch 写入
            if (rob_ready_o) begin
                for (int i = 0; i < DISPATCH_WIDTH; i++) begin
                    if (dispatch_valid_i[i]) begin
                        logic [PTR_WIDTH-1:0] w_idx;
                        w_idx = tail_ptr_q + i[PTR_WIDTH-1:0];
                        
                        rob_ram[w_idx].complete    <= 1'b0;
                        rob_ram[w_idx].exception   <= 1'b0;
                        rob_ram[w_idx].is_mispred  <= 1'b0;
                        rob_ram[w_idx].redirect_pc <= '0;
                        rob_ram[w_idx].ecause      <= '0;
                        rob_ram[w_idx].fu_type     <= dispatch_fu_type_i[i];
                        rob_ram[w_idx].areg        <= dispatch_areg_i[i];
                        rob_ram[w_idx].pc          <= dispatch_pc_i[i];
                        // data 在 Writeback 阶段写入
                    end
                end
            end

            // 2. Writeback 写入
            for (int k = 0; k < WB_WIDTH; k++) begin
                if (wb_valid_i[k]) begin
                    logic [PTR_WIDTH-1:0] wb_idx = wb_rob_index_i[k];
                    
                    rob_ram[wb_idx].complete  <= 1'b1;
                    rob_ram[wb_idx].exception <= wb_exception_i[k];
                    rob_ram[wb_idx].ecause    <= wb_ecause_i[k];
                    rob_ram[wb_idx].data      <= wb_data_i[k];
                    
                    rob_ram[wb_idx].is_mispred  <= wb_is_mispred_i[k];
                    rob_ram[wb_idx].redirect_pc <= wb_redirect_pc_i[k];
                end
            end
        end
    end

endmodule