// vsrc/backend/rob.sv
import config_pkg::*;
import decode_pkg::*;

module rob #(
    parameter config_pkg::cfg_t Cfg = config_pkg::EmptyCfg,
    parameter int unsigned ROB_DEPTH = 64,
    parameter int unsigned DISPATCH_WIDTH = Cfg.INSTR_PER_FETCH, 
    parameter int unsigned COMMIT_WIDTH = Cfg.NRET,    
    parameter int unsigned PHY_REG_ADDR_WIDTH = 6,     
    parameter int unsigned WB_WIDTH = 4                
) (
    input logic clk_i,
    input logic rst_ni,

    // ... (Dispatch 和 Writeback 接口保持不变) ...
    input  logic [DISPATCH_WIDTH-1:0] dispatch_valid_i,
    input  logic [DISPATCH_WIDTH-1:0][Cfg.PLEN-1:0] dispatch_pc_i,
    input  decode_pkg::fu_e [DISPATCH_WIDTH-1:0]    dispatch_fu_type_i,
    input  logic [DISPATCH_WIDTH-1:0][4:0]          dispatch_areg_i, 
    input  logic [DISPATCH_WIDTH-1:0][PHY_REG_ADDR_WIDTH-1:0] dispatch_preg_i, 
    input  logic [DISPATCH_WIDTH-1:0][PHY_REG_ADDR_WIDTH-1:0] dispatch_opreg_i, 
    
    output logic rob_ready_o, 
    output logic [DISPATCH_WIDTH-1:0][$clog2(ROB_DEPTH)-1:0] dispatch_rob_index_o,

    input logic [WB_WIDTH-1:0] wb_valid_i,
    input logic [WB_WIDTH-1:0][$clog2(ROB_DEPTH)-1:0] wb_rob_index_i, 
    input logic [WB_WIDTH-1:0] wb_exception_i,
    input logic [WB_WIDTH-1:0][4:0] wb_ecause_i,

    // =========================================================
    // 3. 提交阶段 (Commit Stage) - 已完善
    // =========================================================
    output logic [COMMIT_WIDTH-1:0] commit_valid_o,
    output logic [COMMIT_WIDTH-1:0][Cfg.PLEN-1:0] commit_pc_o, 
    
    // [FreeList 接口] 释放旧物理寄存器
    output logic [COMMIT_WIDTH-1:0][PHY_REG_ADDR_WIDTH-1:0] commit_opreg_o,
    
    // [新增 - ARAT 接口] 更新架构映射表
    // 告诉 ARAT: "架构寄存器 areg 现在对应物理寄存器 preg"
    output logic [COMMIT_WIDTH-1:0][4:0] commit_areg_o,
    output logic [COMMIT_WIDTH-1:0][PHY_REG_ADDR_WIDTH-1:0] commit_preg_o,

    output logic [COMMIT_WIDTH-1:0] commit_is_store_o, 

    output logic flush_o,
    output logic [Cfg.PLEN-1:0] flush_pc_o, 

    output logic rob_empty_o,
    output logic rob_full_o
);
    localparam int unsigned PTR_WIDTH = $clog2(ROB_DEPTH);

    typedef struct packed {
        logic complete;
        logic exception;
        logic [4:0] ecause;
        decode_pkg::fu_e fu_type; 
        logic [4:0] areg;       
        logic [PHY_REG_ADDR_WIDTH-1:0] preg;  
        logic [PHY_REG_ADDR_WIDTH-1:0] opreg;
        logic [Cfg.PLEN-1:0] pc; 
    } rob_entry_t;

    rob_entry_t [ROB_DEPTH-1:0] rob_ram;
    
    logic [PTR_WIDTH-1:0] head_ptr_q, head_ptr_d;
    logic [PTR_WIDTH-1:0] tail_ptr_q, tail_ptr_d;
    logic [$clog2(ROB_DEPTH+1)-1:0] count_q, count_d;

    // ... (rob_full/empty/ready 逻辑保持不变) ...
    assign rob_full_o  = (count_q > (ROB_DEPTH - DISPATCH_WIDTH));
    assign rob_empty_o = (count_q == 0);
    assign rob_ready_o = !rob_full_o;

    always_comb begin
        for (int i = 0; i < DISPATCH_WIDTH; i++) begin
            dispatch_rob_index_o[i] = tail_ptr_q + i[PTR_WIDTH-1:0];
        end
    end

    // =========================================================
    // 提交逻辑 (Commit Logic)
    // =========================================================
    logic stop_commit;
    
    always_comb begin
        stop_commit = 1'b0;
        flush_o = 1'b0;
        flush_pc_o = '0;

        for (int i = 0; i < COMMIT_WIDTH; i++) begin
            logic [PTR_WIDTH-1:0] idx;
            idx = head_ptr_q + i[PTR_WIDTH-1:0];

            // 默认输出清零
            commit_valid_o[i]    = 1'b0;
            commit_pc_o[i]       = rob_ram[idx].pc;
            commit_opreg_o[i]    = rob_ram[idx].opreg;
            
            // [新增] 输出当前指令的架构目标和物理目标
            commit_areg_o[i]     = rob_ram[idx].areg;
            commit_preg_o[i]     = rob_ram[idx].preg;
            
            commit_is_store_o[i] = (rob_ram[idx].fu_type == decode_pkg::FU_LSU) && 
                                   (rob_ram[idx].areg == '0); // 简单判断，或使用 decoder store 标志

            // 检查顺序提交条件
            if ((count_q > i) && !stop_commit) begin
                if (rob_ram[idx].complete) begin
                    if (rob_ram[idx].exception) begin
                        stop_commit = 1'b1;
                        flush_o = 1'b1;
                        flush_pc_o = rob_ram[idx].pc;
                    end else begin
                        commit_valid_o[i] = 1'b1;
                    end
                end else begin
                    stop_commit = 1'b1;
                end
            end
        end
    end

    // ... (后续 dispatch_cnt/commit_cnt 计算和 always_ff 更新逻辑保持不变) ...
    
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

            if (rob_ready_o) begin
                for (int i = 0; i < DISPATCH_WIDTH; i++) begin
                    if (dispatch_valid_i[i]) begin
                        logic [PTR_WIDTH-1:0] w_idx;
                        w_idx = tail_ptr_q + i[PTR_WIDTH-1:0];
                        rob_ram[w_idx].complete  <= 1'b0;
                        rob_ram[w_idx].exception <= 1'b0;
                        rob_ram[w_idx].ecause    <= '0;
                        rob_ram[w_idx].fu_type   <= dispatch_fu_type_i[i];
                        rob_ram[w_idx].areg      <= dispatch_areg_i[i];
                        rob_ram[w_idx].preg      <= dispatch_preg_i[i];
                        rob_ram[w_idx].opreg     <= dispatch_opreg_i[i];
                        rob_ram[w_idx].pc        <= dispatch_pc_i[i];
                    end
                end
            end

            for (int k = 0; k < WB_WIDTH; k++) begin
                if (wb_valid_i[k]) begin
                    rob_ram[wb_rob_index_i[k]].complete  <= 1'b1;
                    rob_ram[wb_rob_index_i[k]].exception <= wb_exception_i[k];
                    rob_ram[wb_rob_index_i[k]].ecause    <= wb_ecause_i[k];
                end
            end
        end
    end

endmodule