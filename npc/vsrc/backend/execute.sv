// vsrc/backend/execute_alu.sv
import config_pkg::*;
import decode_pkg::*;

module execute_alu #(
    parameter config_pkg::cfg_t Cfg = config_pkg::EmptyCfg // 假设 Cfg.XLEN = 32
) (
    input  logic                     clk_i,
    input  logic                     rst_ni,

    // 来自 Issue/Dispatch 阶段
    input  logic                     alu_valid_i,
    input  decode_pkg::uop_t         uop_i,
    input  logic [31:0]              rs1_data_i,
    input  logic [31:0]              rs2_data_i,

    // 写回结果端口 (Writeback)
    output logic                     alu_valid_o,
    output logic [31:0]              alu_result_o,
    output logic [4:0]               alu_rd_o,
    output logic                     alu_rd_wen_o,
    
    // 控制流输出 (给 Branch Unit 或前端)
    output logic [31:0]              alu_br_target_o,
    output logic                     alu_br_take_o
);

  // --- 1. 操作数准备 ---
  logic [31:0] op_a;
  logic [31:0] op_b;

  // Operand A 选择：通常是 rs1，但在 AUIPC 下是当前指令的 PC
  assign op_a = (uop_i.alu_op == ALU_AUIPC) ? uop_i.pc : rs1_data_i;

  // Operand B 选择：有 rs2 则选 rs2，否则选立即数（LUI/ADDI等）
  // 注意：对于 Branch 指令，op_b 通常用于比较，而立即数用于算地址
  assign op_b = (uop_i.has_rs2) ? rs2_data_i : uop_i.imm;

  // --- 2. 算术与逻辑核心 ---
  logic [31:0] alu_res;
  
  always_comb begin
    alu_res = '0;
    unique case (uop_i.alu_op)
      ALU_ADD:   alu_res = op_a + op_b;
      ALU_SUB:   alu_res = op_a - op_b;
      ALU_LUI:   alu_res = uop_i.imm;
      ALU_AUIPC: alu_res = op_a + op_b; // PC + Imm
      
      // 逻辑运算
      ALU_AND:   alu_res = op_a & op_b;
      ALU_OR:    alu_res = op_a | op_b;
      ALU_XOR:   alu_res = op_a ^ op_b;

      // 移位运算 (RV32I 移位量为 5 位)
      ALU_SLL:   alu_res = op_a <<  op_b[4:0];
      ALU_SRL:   alu_res = op_a >>  op_b[4:0];
      ALU_SRA:   alu_res = $signed(op_a) >>> op_b[4:0];

      // 比较运算 (SLT/SLTU)
      ALU_SLT:   alu_res = ($signed(op_a) < $signed(op_b)) ? 32'b1 : 32'b0;
      ALU_SLTU:  alu_res = (op_a < op_b) ? 32'b1 : 32'b0;

      default:   alu_res = '0;
    endcase
  end

  // --- 3. 跳转与分支处理 (Branch/Jump) ---
  // 地址计算：JAL/Branch 使用 PC+Imm，JALR 使用 rs1+Imm
  assign alu_br_target_o = (uop_i.br_op == BR_JALR) ? (rs1_data_i + uop_i.imm) : (uop_i.pc + uop_i.imm);

  // 分支比较逻辑
  always_comb begin
    alu_br_take_o = 1'b0;
    if (uop_i.is_branch) begin
      unique case (uop_i.br_op)
        BR_EQ:  alu_br_take_o = (rs1_data_i == rs2_data_i);
        BR_NE:  alu_br_take_o = (rs1_data_i != rs2_data_i);
        BR_LT:  alu_br_take_o = ($signed(rs1_data_i) <  $signed(rs2_data_i));
        BR_GE:  alu_br_take_o = ($signed(rs1_data_i) >= $signed(rs2_data_i));
        BR_LTU: alu_br_take_o = (rs1_data_i <  rs2_data_i);
        BR_GEU: alu_br_take_o = (rs1_data_i >= rs2_data_i);
        default: alu_br_take_o = 1'b0;
      endcase
    end else if (uop_i.is_jump) begin
      alu_br_take_o = 1'b1; // JAL 和 JALR 总是跳转
    end
  end

  // --- 4. 输出赋值 ---
  assign alu_valid_o  = alu_valid_i && uop_i.valid;
  
  // 对于 Jump 指令，写回寄存器的数据通常是 PC + 4 (返回地址)
  assign alu_result_o = (uop_i.is_jump) ? (uop_i.pc + 4) : alu_res;
  
  assign alu_rd_o     = uop_i.rd;
  assign alu_rd_wen_o = uop_i.has_rd && alu_valid_o;

endmodule