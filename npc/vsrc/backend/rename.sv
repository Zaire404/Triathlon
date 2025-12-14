// vsrc/backend/rename.sv
import config_pkg::*;
import decode_pkg::*;

module rename #(
    parameter config_pkg::cfg_t Cfg = config_pkg::EmptyCfg,
    parameter int unsigned PHY_REG_ADDR_WIDTH = 6
) (
    input logic clk_i,
    input logic rst_ni,

    // --- From Decoder ---
    input logic [3:0] dec_valid_i,
    input decode_pkg::uop_t [3:0] dec_uops_i,
    output logic rename_ready_o, // 告诉 Decoder 可以发指令 (FreeList有空位 & ROB有空位)

    // --- To ROB (Dispatch Interface) ---
    output logic [3:0] rob_dispatch_valid_o,
    output logic [3:0][Cfg.PLEN-1:0] rob_dispatch_pc_o,
    output decode_pkg::fu_e [3:0]    rob_dispatch_fu_type_o,
    output logic [3:0][4:0]          rob_dispatch_areg_o,
    output logic [3:0][PHY_REG_ADDR_WIDTH-1:0] rob_dispatch_preg_o, // 新分配的
    output logic [3:0][PHY_REG_ADDR_WIDTH-1:0] rob_dispatch_opreg_o, // 被覆盖的旧的
    input  logic rob_ready_i,

    // --- To Issue Queue / Dispatcher (发送重命名后的指令去执行) ---
    output logic [3:0] issue_valid_o,
    output logic [3:0][PHY_REG_ADDR_WIDTH-1:0] issue_rs1_preg_o,
    output logic [3:0][PHY_REG_ADDR_WIDTH-1:0] issue_rs2_preg_o,
    output logic [3:0][PHY_REG_ADDR_WIDTH-1:0] issue_rd_preg_o,
    // ... 其他需要传给执行单元的信息 (imm, fu_type等)

    // --- From ROB Commit (用于回收物理寄存器) ---
    input logic [3:0] commit_valid_i,
    input logic [3:0][PHY_REG_ADDR_WIDTH-1:0] commit_opreg_i,

    input logic flush_i
);

    // 内部信号
    logic [3:0] alloc_req;
    logic [3:0][PHY_REG_ADDR_WIDTH-1:0] alloc_pregs;
    logic alloc_can_do;

    logic [3:0][PHY_REG_ADDR_WIDTH-1:0] rat_rs1_preg, rat_rs2_preg;
    logic [3:0][PHY_REG_ADDR_WIDTH-1:0] rat_old_preg; // Current RAT value for rd
    
    // 1. 实例化 Free List
    freelist #(
        .PHY_REG_NUM(64), // 假设
        .DISPATCH_WIDTH(4),
        .COMMIT_WIDTH(4)
    ) u_freelist (
        .clk_i, .rst_ni,
        .alloc_req_i(alloc_req),
        .alloc_pregs_o(alloc_pregs),
        .alloc_can_do_o(alloc_can_do),
        .commit_valid_i(commit_valid_i),
        .commit_opregs_i(commit_opreg_i),
        .flush_i(flush_i)
    );

    // 2. 实例化 RAT
    // 构造写信号：只有当指令有效且需要写回寄存器时才更新 RAT
    logic [3:0] rat_we;
    logic [3:0][4:0] rs1_idx, rs2_idx, rd_idx;
    logic [3:0][PHY_REG_ADDR_WIDTH-1:0] final_rd_preg; // 处理依赖后的最终分配

    always_comb begin
        for (int i=0; i<4; i++) begin
            alloc_req[i] = dec_valid_i[i] && dec_uops_i[i].has_rd && (dec_uops_i[i].rd != 0);
            rat_we[i]    = alloc_req[i]; // 这里的逻辑是一样的
            rs1_idx[i]   = dec_uops_i[i].rs1;
            rs2_idx[i]   = dec_uops_i[i].rs2;
            rd_idx[i]    = dec_uops_i[i].rd;
        end
    end

    rat u_rat (
        .clk_i, .rst_ni,
        .rs1_idx_i(rs1_idx), .rs2_idx_i(rs2_idx),
        .rs1_preg_o(rat_rs1_preg), .rs2_preg_o(rat_rs2_preg),
        .we_i(rat_we), .rd_idx_i(rd_idx), .rd_preg_i(final_rd_preg),
        .old_preg_o(rat_old_preg),
        .flush_i(flush_i)
    );

    // 3. 核心重命名逻辑 (处理组内依赖 Intra-group Dependency)
    // 这是多发射最难的地方：如果Instr 1写r5，Instr 2读r5，Instr 2必须读到Instr 1新分配的preg，而不是RAT里的旧preg
    
    always_comb begin
        // 默认：从 FreeList 获取新 Preg
        final_rd_preg = alloc_pregs; 

        // 默认：从 RAT 获取源操作数 Preg
        issue_rs1_preg_o = rat_rs1_preg;
        issue_rs2_preg_o = rat_rs2_preg;

        // --- 组内依赖检查 (Forwarding Logic in Rename) ---
        for (int i=1; i<4; i++) begin // 从第2条开始检查前面的
            for (int j=0; j<i; j++) begin
                // 检查 RS1 是否依赖前面的 RD
                if (alloc_req[j] && dec_uops_i[i].has_rs1 && (dec_uops_i[i].rs1 == dec_uops_i[j].rd)) begin
                    issue_rs1_preg_o[i] = alloc_pregs[j]; // Forward 新分配的 Preg
                end
                // 检查 RS2 是否依赖前面的 RD
                if (alloc_req[j] && dec_uops_i[i].has_rs2 && (dec_uops_i[i].rs2 == dec_uops_i[j].rd)) begin
                    issue_rs2_preg_o[i] = alloc_pregs[j];
                end
            end
        end
        
        // 注意：RAT 的写入端口需要按照程序顺序写入
        // 如果一组内多条指令写同一个寄存器 (WAW)，RAT 最终必须记录最后那条指令的 Preg
        // rat 模块内部如果使用简单的并发赋值可能会有竞争，
        // 严谨的 RAT 写逻辑应该在 rat 模块内部处理：如果 index 相同，index 大的覆盖 index 小的。
        // 为了简化，这里假设 rat 模块能处理或者我们在输入端就过滤掉被覆盖的写请求。
        // 但简单实现中，Verilog 的 last-write-wins (如果用循环顺序) 有时有效，但在并行块中需小心。
    end
    
    // 4. 输出打包给 ROB
    assign rename_ready_o = alloc_can_do && rob_ready_i; // 握手：资源都够才 Ready

    always_comb begin
        for (int i=0; i<4; i++) begin
            // 只有当握手成功且指令有效时，才发送给 ROB
            if (rename_ready_o && dec_valid_i[i]) begin
                rob_dispatch_valid_o[i]   = 1'b1;
                rob_dispatch_pc_o[i]      = dec_uops_i[i].pc;
                rob_dispatch_fu_type_o[i] = dec_uops_i[i].fu;
                rob_dispatch_areg_o[i]    = dec_uops_i[i].rd;
                
                // 如果有目标寄存器，则写入新分配的；否则为0
                rob_dispatch_preg_o[i]    = alloc_req[i] ? alloc_pregs[i] : '0;
                
                // 关键：OPreg 是从 RAT 读出来的“旧映射”，用于将来 Commit 时释放
                rob_dispatch_opreg_o[i]   = alloc_req[i] ? rat_old_preg[i] : '0;
                
                issue_rd_preg_o[i]        = alloc_req[i] ? alloc_pregs[i] : '0;
                issue_valid_o[i]          = 1'b1;
            end else begin
                rob_dispatch_valid_o[i]   = 0;
                // ... 其他清零
                issue_valid_o[i]          = 0;
            end
        end
    end

endmodule