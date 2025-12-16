// vsrc/backend/rename.sv
import config_pkg::*;
import decode_pkg::*;

module rename #(
    parameter config_pkg::cfg_t Cfg = config_pkg::EmptyCfg,
    parameter int unsigned ROB_DEPTH = 64,
    parameter int unsigned ROB_IDX_WIDTH = $clog2(ROB_DEPTH),
    parameter int unsigned SB_DEPTH = 16,               // Store Buffer 深度
    parameter int unsigned SB_IDX_WIDTH = $clog2(SB_DEPTH)
) (
    input logic clk_i,
    input logic rst_ni,

    // --- From Decoder ---
    input logic [3:0] dec_valid_i,
    input decode_pkg::uop_t [3:0] dec_uops_i,
    output logic rename_ready_o, // 告诉 Decoder 可以发指令

    // --- To ROB (Dispatch Interface) ---
    output logic [3:0] rob_dispatch_valid_o,
    output logic [3:0][Cfg.PLEN-1:0] rob_dispatch_pc_o,
    output decode_pkg::fu_e [3:0]    rob_dispatch_fu_type_o,
    output logic [3:0][4:0]          rob_dispatch_areg_o,
    output logic [3:0]               rob_dispatch_is_store_o, // 告知 ROB 这是 Store
    output logic [3:0][SB_IDX_WIDTH-1:0] rob_dispatch_sb_id_o, // 告知 ROB 分配到的 SB ID
    
    // 输入 ROB 的状态
    input  logic rob_ready_i,
    input  logic [ROB_IDX_WIDTH-1:0] rob_tail_ptr_i,

    // --- To Store Buffer (Allocation Interface) ---
    output logic sb_alloc_req_o,          // 请求分配 SB Entry
    input  logic sb_alloc_gnt_i,          // SB 允许分配
    input  logic [SB_IDX_WIDTH-1:0] sb_alloc_id_i, // 分配到的 SB ID

    // --- To Issue Queue / Dispatcher ---
    output logic [3:0] issue_valid_o,
    output logic [3:0] issue_rs1_in_rob_o,
    output logic [3:0][ROB_IDX_WIDTH-1:0] issue_rs1_rob_idx_o,
    output logic [3:0] issue_rs2_in_rob_o,
    output logic [3:0][ROB_IDX_WIDTH-1:0] issue_rs2_rob_idx_o,
    output logic [3:0][ROB_IDX_WIDTH-1:0] issue_rd_rob_idx_o,

    // --- From ROB Commit (用于更新 RAT 状态) ---
    input logic [3:0] commit_valid_i,
    input logic [3:0][4:0] commit_areg_i,
    input logic [3:0][ROB_IDX_WIDTH-1:0] commit_rob_idx_i,

    input logic flush_i
);

    // ---------------------------------------------------------
    // 0. Flush Masking & Store Detection
    // ---------------------------------------------------------
    logic [3:0] dec_valid_masked;
    logic has_store;
    
    always_comb begin
        has_store = 1'b0;
        for (int i=0; i<4; i++) begin
            dec_valid_masked[i] = dec_valid_i[i] && !flush_i;
            
            // 检查是否有有效的 Store 指令
            if (dec_valid_masked[i] && dec_uops_i[i].is_store) begin
                has_store = 1'b1;
            end
        end
    end

    // ---------------------------------------------------------
    // 1. Ready & Handshake Logic (支持 Store Buffer 反压)
    // ---------------------------------------------------------
    // 如果包含 Store 指令，必须等待 Store Buffer 有空位 (sb_alloc_gnt_i)
    // 注意：这里假设 store_buffer 每周期只能分配 1 个条目。
    // 如果 dec_uops_i 中包含 >1 条 Store，此处逻辑需要扩展为串行化或 stall，
    // 这里简化为：只要有 Store 且 SB Ready 就发 (隐含假设 decode 限制或 SB 够快)
    assign rename_ready_o = rob_ready_i && (!has_store || sb_alloc_gnt_i);

    // 向 Store Buffer 发起分配请求
    // 条件：Rename 阶段握手成功 且 确实有 Store 指令
    assign sb_alloc_req_o = rename_ready_o && has_store;

    // ---------------------------------------------------------
    // 2. 生成新的 Tags (ROB ID)
    // ---------------------------------------------------------
    logic [3:0][ROB_IDX_WIDTH-1:0] new_tags;
    logic [3:0] alloc_req; // 是否需要分配 RAT 映射 (写寄存器)

    always_comb begin
        for (int i=0; i<4; i++) begin
            // Tag = ROB Tail + Offset
            new_tags[i] = (rob_tail_ptr_i + i) % ROB_DEPTH;
            
            // 写有效寄存器才更新 RAT
            alloc_req[i] = dec_valid_masked[i] && dec_uops_i[i].has_rd && (dec_uops_i[i].rd != 0);
        end
    end

    // ---------------------------------------------------------
    // 3. RAT 读写 (查表 + 更新)
    // ---------------------------------------------------------
    logic [3:0]       rat_rs1_in_rob, rat_rs2_in_rob;
    logic [3:0][ROB_IDX_WIDTH-1:0] rat_rs1_tag, rat_rs2_tag;

    rat #(
        .ROB_DEPTH(ROB_DEPTH)
    ) u_rat (
        .clk_i, .rst_ni,
        .rs1_idx_i(get_rs1_indices(dec_uops_i)),
        .rs2_idx_i(get_rs2_indices(dec_uops_i)),
        .rs1_in_rob_o(rat_rs1_in_rob), .rs1_rob_idx_o(rat_rs1_tag),
        .rs2_in_rob_o(rat_rs2_in_rob), .rs2_rob_idx_o(rat_rs2_tag),

        .disp_we_i(alloc_req),
        .disp_rd_idx_i(get_rd_indices(dec_uops_i)),
        .disp_rob_idx_i(new_tags),

        .commit_we_i(commit_valid_i),
        .commit_rd_idx_i(commit_areg_i),
        .commit_rob_idx_i(commit_rob_idx_i),

        .rob_dispatch_is_store_o(rob_dispatch_is_store_o),
        .rob_dispatch_sb_id_o(rob_dispatch_sb_id_o),
        
        .flush_i(flush_i)
    );

    // ---------------------------------------------------------
    // 4. 组内依赖检查 (Intra-group Dependency Check)
    // ---------------------------------------------------------
    logic [3:0]       final_rs1_in_rob, final_rs2_in_rob;
    logic [3:0][ROB_IDX_WIDTH-1:0] final_rs1_tag, final_rs2_tag;

    always_comb begin
        final_rs1_in_rob = rat_rs1_in_rob;
        final_rs1_tag    = rat_rs1_tag;
        final_rs2_in_rob = rat_rs2_in_rob;
        final_rs2_tag    = rat_rs2_tag;

        for (int i=1; i<4; i++) begin
            for (int j=0; j<i; j++) begin
                if (alloc_req[j] && dec_uops_i[i].has_rs1 && (dec_uops_i[i].rs1 == dec_uops_i[j].rd)) begin
                    final_rs1_in_rob[i] = 1'b1;
                    final_rs1_tag[i]    = new_tags[j];
                end
                if (alloc_req[j] && dec_uops_i[i].has_rs2 && (dec_uops_i[i].rs2 == dec_uops_i[j].rd)) begin
                    final_rs2_in_rob[i] = 1'b1;
                    final_rs2_tag[i]    = new_tags[j];
                end
            end
        end
    end

    // ---------------------------------------------------------
    // 5. 输出打包
    // ---------------------------------------------------------
    always_comb begin
        for (int i=0; i<4; i++) begin
            if (rename_ready_o && dec_valid_masked[i]) begin
                // --- To ROB ---
                rob_dispatch_valid_o[i]   = 1'b1;
                rob_dispatch_pc_o[i]      = dec_uops_i[i].pc;
                rob_dispatch_fu_type_o[i] = dec_uops_i[i].fu;
                rob_dispatch_areg_o[i]    = dec_uops_i[i].rd;
                rob_dispatch_is_store_o[i]= dec_uops_i[i].is_store;
                
                // 将分配到的 SB ID 传给 ROB
                // 注意：如果这组指令里有多条 Store，这里需要更复杂的逻辑来分配多个 ID。
                // 现在的逻辑假设：如果有 Store，就用 sb_alloc_id_i；非 Store 指令该字段无效。
                if (dec_uops_i[i].is_store) begin
                    rob_dispatch_sb_id_o[i] = sb_alloc_id_i;
                end else begin
                    rob_dispatch_sb_id_o[i] = '0;
                end

                // --- To Issue Queue ---
                issue_valid_o[i]       = 1'b1;
                issue_rs1_in_rob_o[i]  = final_rs1_in_rob[i];
                issue_rs1_rob_idx_o[i] = final_rs1_tag[i];
                issue_rs2_in_rob_o[i]  = final_rs2_in_rob[i];
                issue_rs2_rob_idx_o[i] = final_rs2_tag[i];
                issue_rd_rob_idx_o[i]  = new_tags[i]; 

            end else begin
                rob_dispatch_valid_o[i] = 0;
                rob_dispatch_pc_o[i]    = '0;
                rob_dispatch_fu_type_o[i] = decode_pkg::FU_NONE;
                rob_dispatch_areg_o[i]  = '0;
                rob_dispatch_is_store_o[i] = 1'b0;
                rob_dispatch_sb_id_o[i] = '0;

                issue_valid_o[i]        = 0;
                issue_rs1_in_rob_o[i]   = 0;
                issue_rs1_rob_idx_o[i]  = '0;
                issue_rs2_in_rob_o[i]   = 0;
                issue_rs2_rob_idx_o[i]  = '0;
                issue_rd_rob_idx_o[i]   = '0;
            end
        end
    end

    // 辅助函数
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