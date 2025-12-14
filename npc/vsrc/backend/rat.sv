// vsrc/backend/rat.sv
import config_pkg::*;

module rat #(
    parameter int unsigned PHY_REG_ADDR_WIDTH = 6,
    parameter int unsigned AREG_NUM = 32
) (
    input logic clk_i,
    input logic rst_ni,

    // --- Read Ports (Source Operands) ---
    // 4条指令，每条最多2个源操作数，共8个读端口
    input  logic [3:0][4:0]  rs1_idx_i,
    input  logic [3:0][4:0]  rs2_idx_i,
    output logic [3:0][PHY_REG_ADDR_WIDTH-1:0] rs1_preg_o,
    output logic [3:0][PHY_REG_ADDR_WIDTH-1:0] rs2_preg_o,

    // --- Write/Update Ports (Destination Operands) ---
    // 4条指令写回
    input logic [3:0]        we_i,
    input logic [3:0][4:0]   rd_idx_i,
    input logic [3:0][PHY_REG_ADDR_WIDTH-1:0] rd_preg_i,
    
    // --- Read Old Mapping (for ROB OPreg) ---
    // 在更新前，读取这些 rd 当前对应的物理寄存器，作为 opreg 返回
    output logic [3:0][PHY_REG_ADDR_WIDTH-1:0] old_preg_o,
    
    input logic flush_i // 冲刷时恢复 RAT (需要 Checkpoint 机制，此处简化)
);

    logic [PHY_REG_ADDR_WIDTH-1:0] map_table [AREG_NUM];

    // 1. Read Current Mappings (组合逻辑)
    always_comb begin
        for (int i=0; i<4; i++) begin
            rs1_preg_o[i] = (rs1_idx_i[i] == '0) ? '0 : map_table[rs1_idx_i[i]];
            rs2_preg_o[i] = (rs2_idx_i[i] == '0) ? '0 : map_table[rs2_idx_i[i]];
            
            // 读取旧映射用于 ROB 记录 (OPreg)
            old_preg_o[i] = (rd_idx_i[i]  == '0) ? '0 : map_table[rd_idx_i[i]];
        end
    end

    // 2. Update Mappings (时序逻辑)
    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            for (int i=0; i<AREG_NUM; i++) map_table[i] <= '0; // 初始 p0
        end else if (flush_i) begin
            // TODO: 从架构表(ARAT)恢复，或者从 Snapshot 恢复
        end else begin
            for (int i=0; i<4; i++) begin
                if (we_i[i] && rd_idx_i[i] != '0) begin
                    map_table[rd_idx_i[i]] <= rd_preg_i[i];
                end
            end
        end
    end
endmodule