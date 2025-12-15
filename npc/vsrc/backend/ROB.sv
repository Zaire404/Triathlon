// vsrc/backend/ROB.sv (Data-in-ROB Version)
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
    // 注意：不再需要输入 physical register (preg)
    input  logic [DISPATCH_WIDTH-1:0] dispatch_valid_i,
    input  logic [DISPATCH_WIDTH-1:0][Cfg.PLEN-1:0] dispatch_pc_i,
    input  decode_pkg::fu_e [DISPATCH_WIDTH-1:0]    dispatch_fu_type_i,
    input  logic [DISPATCH_WIDTH-1:0][4:0]          dispatch_areg_i, // 逻辑目标寄存器
    
    output logic rob_ready_o, 
    output logic [DISPATCH_WIDTH-1:0][$clog2(ROB_DEPTH)-1:0] dispatch_rob_index_o, // 返回 ROB ID 作为 Tag

    // =========================================================
    // 2. Writeback 阶段 (From ALU/LSU/CDB)
    // =========================================================
    input logic [WB_WIDTH-1:0] wb_valid_i,
    input logic [WB_WIDTH-1:0][$clog2(ROB_DEPTH)-1:0] wb_rob_index_i, 
    // [新增] 写回数据：指令执行结果直接存入 ROB
    input logic [WB_WIDTH-1:0][Cfg.XLEN-1:0] wb_data_i, 
    input logic [WB_WIDTH-1:0] wb_exception_i,
    input logic [WB_WIDTH-1:0][4:0] wb_ecause_i,

    // =========================================================
    // 3. Commit 阶段 (To ARF)
    // =========================================================
    output logic [COMMIT_WIDTH-1:0] commit_valid_o,
    output logic [COMMIT_WIDTH-1:0][Cfg.PLEN-1:0] commit_pc_o, 
    
    // [修改] 提交接口：告诉 ARF "把这个数据写入这个逻辑寄存器"
    output logic [COMMIT_WIDTH-1:0]       commit_we_o,    // 写使能
    output logic [COMMIT_WIDTH-1:0][4:0]  commit_areg_o,  // 逻辑寄存器号
    output logic [COMMIT_WIDTH-1:0][Cfg.XLEN-1:0] commit_wdata_o, // 数据 (从 ROB 搬移到 ARF)

    output logic [COMMIT_WIDTH-1:0] commit_is_store_o, 

    // Exception / Flush
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
        // logic [PHY_REG_ADDR_WIDTH-1:0] preg;  <-- 删除
        // logic [PHY_REG_ADDR_WIDTH-1:0] opreg; <-- 删除
        
        // [新增] 数据域：ROB 充当临时的物理寄存器
        logic [Cfg.XLEN-1:0] data; 
        
        logic [Cfg.PLEN-1:0] pc; 
    } rob_entry_t;

    rob_entry_t [ROB_DEPTH-1:0] rob_ram;
    
    logic [PTR_WIDTH-1:0] head_ptr_q, head_ptr_d;
    logic [PTR_WIDTH-1:0] tail_ptr_q, tail_ptr_d;
    logic [$clog2(ROB_DEPTH+1)-1:0] count_q, count_d;

    // ... (Flow Control 逻辑不变) ...
    assign rob_full_o  = (count_q > (ROB_DEPTH - DISPATCH_WIDTH));
    assign rob_empty_o = (count_q == 0);
    assign rob_ready_o = !rob_full_o;

    always_comb begin
        for (int i = 0; i < DISPATCH_WIDTH; i++) begin
            dispatch_rob_index_o[i] = tail_ptr_q + i[PTR_WIDTH-1:0];
        end
    end

    // =========================================================
    // Commit Logic (搬运数据 ROB -> ARF)
    // =========================================================
    logic stop_commit;
    
    always_comb begin
        stop_commit = 1'b0;
        flush_o = 1'b0;
        flush_pc_o = '0;

        for (int i = 0; i < COMMIT_WIDTH; i++) begin
            logic [PTR_WIDTH-1:0] idx;
            idx = head_ptr_q + i[PTR_WIDTH-1:0];

            commit_valid_o[i] = 1'b0;
            commit_pc_o[i]    = rob_ram[idx].pc;
            
            // 输出数据给 ARF
            commit_areg_o[i]  = rob_ram[idx].areg;
            commit_wdata_o[i] = rob_ram[idx].data; // 数据源自 ROB
            commit_we_o[i]    = 1'b0;              // 默认不写 ARF

            commit_is_store_o[i] = (rob_ram[idx].fu_type == decode_pkg::FU_LSU) && 
                                   (rob_ram[idx].areg == '0);

            if ((count_q > i) && !stop_commit) begin
                if (rob_ram[idx].complete) begin
                    if (rob_ram[idx].exception) begin
                        stop_commit = 1'b1;
                        flush_o = 1'b1;
                        flush_pc_o = rob_ram[idx].pc;
                    end else begin
                        commit_valid_o[i] = 1'b1;
                        // 只有当存在目标寄存器且不为 x0 时，才写 ARF
                        if (rob_ram[idx].areg != 0) begin
                            commit_we_o[i] = 1'b1;
                        end
                    end
                end else begin
                    stop_commit = 1'b1;
                end
            end
        end
    end

    // ... (Counter logic 不变) ...
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
                        
                        rob_ram[w_idx].complete  <= 1'b0;
                        rob_ram[w_idx].exception <= 1'b0;
                        rob_ram[w_idx].ecause    <= '0;
                        rob_ram[w_idx].fu_type   <= dispatch_fu_type_i[i];
                        rob_ram[w_idx].areg      <= dispatch_areg_i[i];
                        rob_ram[w_idx].pc        <= dispatch_pc_i[i];
                        // data 字段在这里不需要初始化，等 Writeback 写
                    end
                end
            end

            // 2. Writeback 写入 (存数据!)
            for (int k = 0; k < WB_WIDTH; k++) begin
                if (wb_valid_i[k]) begin
                    logic [PTR_WIDTH-1:0] wb_idx = wb_rob_index_i[k];
                    rob_ram[wb_idx].complete  <= 1'b1;
                    rob_ram[wb_idx].exception <= wb_exception_i[k];
                    rob_ram[wb_idx].ecause    <= wb_ecause_i[k];
                    // [新增] 保存计算结果
                    rob_ram[wb_idx].data      <= wb_data_i[k]; 
                end
            end
        end
    end

endmodule