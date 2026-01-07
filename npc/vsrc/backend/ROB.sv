// vsrc/backend/ROB.sv
import config_pkg::*;
import decode_pkg::*;

module rob #(
    parameter config_pkg::cfg_t Cfg = config_pkg::EmptyCfg,
    parameter int unsigned ROB_DEPTH = 64,
    parameter int unsigned DISPATCH_WIDTH = Cfg.INSTR_PER_FETCH, 
    parameter int unsigned COMMIT_WIDTH = Cfg.NRET,    
    parameter int unsigned WB_WIDTH = 4,
    // [新增] Store Buffer 参数
    parameter int unsigned SB_DEPTH = 16,
    parameter int unsigned SB_IDX_WIDTH = $clog2(SB_DEPTH)
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
    
    // [新增] 接收 Store Buffer ID
    // 只有当指令是 Store 时，这个信号才有效；否则忽略
    input  logic [DISPATCH_WIDTH-1:0]               dispatch_is_store_i,
    input  logic [DISPATCH_WIDTH-1:0][SB_IDX_WIDTH-1:0] dispatch_sb_id_i,

    output logic rob_ready_o, 
    output logic [DISPATCH_WIDTH-1:0][$clog2(ROB_DEPTH)-1:0] dispatch_rob_index_o,

    // =========================================================
    // 2. Writeback 阶段 (From ALU/LSU/Branch Unit)
    // =========================================================
    input logic [WB_WIDTH-1:0] wb_valid_i,
    input logic [WB_WIDTH-1:0][$clog2(ROB_DEPTH)-1:0] wb_rob_index_i, 
    input logic [WB_WIDTH-1:0][Cfg.XLEN-1:0] wb_data_i, 
    
    input logic [WB_WIDTH-1:0] wb_exception_i,
    input logic [WB_WIDTH-1:0][4:0] wb_ecause_i,
    input logic [WB_WIDTH-1:0] wb_is_mispred_i,  
    input logic [WB_WIDTH-1:0][Cfg.PLEN-1:0] wb_redirect_pc_i, 

    // =========================================================
    // 3. Commit 阶段 (To ARF & Controller & RAT & SB)
    // =========================================================
    output logic [COMMIT_WIDTH-1:0] commit_valid_o,
    output logic [COMMIT_WIDTH-1:0][Cfg.PLEN-1:0] commit_pc_o, 
    
    // To ARF
    output logic [COMMIT_WIDTH-1:0]       commit_we_o,
    output logic [COMMIT_WIDTH-1:0][4:0]  commit_areg_o,
    output logic [COMMIT_WIDTH-1:0][Cfg.XLEN-1:0] commit_wdata_o,

    // To RAT
    output logic [COMMIT_WIDTH-1:0][$clog2(ROB_DEPTH)-1:0] commit_rob_index_o,

    // To Store Buffer [修复核心]
    output logic [COMMIT_WIDTH-1:0] commit_is_store_o, 
    // [新增] 告诉 Store Buffer 哪条指令退休了
    output logic [COMMIT_WIDTH-1:0][SB_IDX_WIDTH-1:0] commit_sb_id_o,

    // Flush Interface
    output logic flush_o,
    output logic [Cfg.PLEN-1:0] flush_pc_o, 
    output logic [4:0] flush_cause_o,

    output logic rob_empty_o,
    output logic rob_full_o
);
    localparam int unsigned PTR_WIDTH = $clog2(ROB_DEPTH);

    // 资源限制参数
    localparam int unsigned MAX_COMMIT_BR = 1; 
    localparam int unsigned MAX_COMMIT_ST = 1; 
    localparam int unsigned MAX_COMMIT_LD = 2; 

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
        
        // [新增] 存储该指令对应的 Store Buffer ID
        logic is_store;
        logic [SB_IDX_WIDTH-1:0] sb_id;
    } rob_entry_t;

    rob_entry_t [ROB_DEPTH-1:0] rob_ram;
    
    logic [PTR_WIDTH-1:0] head_ptr_q, head_ptr_d;
    logic [PTR_WIDTH-1:0] tail_ptr_q, tail_ptr_d;
    logic [$clog2(ROB_DEPTH+1)-1:0] count_q, count_d;

    assign rob_full_o  = (count_q > (ROB_DEPTH - DISPATCH_WIDTH));
    assign rob_empty_o = (count_q == 0);
    assign rob_ready_o = !rob_full_o;

    always_comb begin
        for (int i = 0; i < DISPATCH_WIDTH; i++) begin
            dispatch_rob_index_o[i] = tail_ptr_q + i[PTR_WIDTH-1:0];
        end
    end

    // =========================================================
    // Commit Logic
    // =========================================================
    logic stop_commit;
    logic [COMMIT_WIDTH-1:0] br_mask, st_mask, ld_mask;
    logic [COMMIT_WIDTH-1:0] commit_permitted_mask;

    always_comb begin
        automatic int cnt_br = 0;
        automatic int cnt_st = 0;
        automatic int cnt_ld = 0;

        stop_commit = 1'b0;
        flush_o = 1'b0;
        flush_pc_o = '0;
        flush_cause_o = '0;

        commit_valid_o = '0;
        commit_pc_o    = '0;
        commit_we_o    = '0;
        commit_areg_o  = '0;
        commit_wdata_o = '0;
        commit_is_store_o = '0;
        commit_sb_id_o    = '0; // 默认清零
        commit_rob_index_o = '0; 

        // --- 1. Resource Check ---

        br_mask = '1; st_mask = '1; ld_mask = '1;

        for (int i = 0; i < COMMIT_WIDTH; i++) begin
            logic [PTR_WIDTH-1:0] check_idx;
            check_idx = head_ptr_q + i[PTR_WIDTH-1:0];
            
            if (count_q > i) begin
                if (rob_ram[check_idx].fu_type == decode_pkg::FU_BRANCH) begin
                    if (cnt_br >= MAX_COMMIT_BR) br_mask[i] = 1'b0;
                    cnt_br++;
                end
                // 使用内部存储的 is_store 位判断
                if (rob_ram[check_idx].is_store) begin 
                    if (cnt_st >= MAX_COMMIT_ST) st_mask[i] = 1'b0;
                    cnt_st++;
                end
                if (rob_ram[check_idx].fu_type == decode_pkg::FU_LSU && !rob_ram[check_idx].is_store) begin
                    if (cnt_ld >= MAX_COMMIT_LD) ld_mask[i] = 1'b0;
                    cnt_ld++;
                end
            end
        end
        commit_permitted_mask = br_mask & st_mask & ld_mask;

        // --- 2. Final Commit ---
        for (int i = 0; i < COMMIT_WIDTH; i++) begin
            logic [PTR_WIDTH-1:0] idx;
            idx = head_ptr_q + i[PTR_WIDTH-1:0];
            commit_rob_index_o[i] = idx; 

            if ((count_q > i) && !stop_commit && commit_permitted_mask[i]) begin
                if (rob_ram[idx].complete) begin
                    if (rob_ram[idx].exception) begin
                        stop_commit   = 1'b1;
                        flush_o       = 1'b1;
                        flush_pc_o    = rob_ram[idx].pc;
                        flush_cause_o = rob_ram[idx].ecause;
                    end 
                    else if (rob_ram[idx].is_mispred) begin
                        stop_commit   = 1'b1;
                        flush_o       = 1'b1;
                        flush_pc_o    = rob_ram[idx].redirect_pc;
                    end
                    else begin
                        // 正常退休
                        commit_valid_o[i] = 1'b1;
                        commit_pc_o[i]    = rob_ram[idx].pc;
                        
                        commit_areg_o[i]  = rob_ram[idx].areg;
                        commit_wdata_o[i] = rob_ram[idx].data;
                        if (rob_ram[idx].areg != 0) begin
                            commit_we_o[i] = 1'b1;
                        end

                        // [修复] 输出 Store Buffer ID
                        commit_is_store_o[i] = rob_ram[idx].is_store;
                        commit_sb_id_o[i]    = rob_ram[idx].sb_id;
                    end
                end else begin
                    stop_commit = 1'b1;
                end
            end else begin
                stop_commit = 1'b1;
            end
        end
    end

    // ... Pointers Logic (Unchanged) ...
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

    // ... Sequential Logic ...
    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            head_ptr_q <= '0;
            tail_ptr_q <= '0;
            count_q    <= '0;
        end else if (flush_o) begin
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
                        
                        // [新增] 保存 SB ID
                        rob_ram[w_idx].is_store    <= dispatch_is_store_i[i];
                        rob_ram[w_idx].sb_id       <= dispatch_sb_id_i[i];
                    end
                end
            end

            // 2. Writeback 写入 (保持不变)
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