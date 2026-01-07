// vsrc/backend/execute_alu.sv
import config_pkg::*;
import decode_pkg::*;

module execute_alu #(
    parameter config_pkg::cfg_t Cfg = config_pkg::EmptyCfg,
    parameter TAG_W = 6
) (
    input  logic                     clk_i,
    input  logic                     rst_ni,

    // 来自 Issue 阶段
    input  logic                     alu_valid_i,
    input  decode_pkg::uop_t         uop_i,
    input  logic [31:0]              rs1_data_i,
    input  logic [31:0]              rs2_data_i,
    input  logic [TAG_W-1:0]         rob_tag_i,    // 接收指令在 ROB 中的索引

    // 写回结果端口 (连接到 ROB 的 wb_valid/wb_data/wb_rob_index 等)
    output logic                     alu_valid_o,
    output logic [TAG_W-1:0]         alu_rob_tag_o, // 透传 ROB ID
    output logic [31:0]              alu_result_o,  // 写回寄存器的数据
    
    // 控制流信息 (统一交给 ROB，由 ROB 发起 Flush)
    output logic                     alu_is_mispred_o,  // 告知 ROB 发生分支预测错误
    output logic [31:0]              alu_redirect_pc_o  // 告知 ROB 正确的跳转地址
);

  // --- 1. 操作数准备 ---
  logic [31:0] op_a;
  logic [31:0] op_b;

  // Operand A 选择
  assign op_a = (uop_i.alu_op == ALU_AUIPC) ? uop_i.pc : rs1_data_i;

  // Operand B 选择
  assign op_b = (uop_i.has_rs2) ? rs2_data_i : uop_i.imm;

  // --- 2. 算术与逻辑核心 ---
  logic [31:0] alu_res;
  
  always_comb begin
    alu_res = '0;
    unique case (uop_i.alu_op)
      ALU_ADD:   alu_res = op_a + op_b;  
      ALU_SUB:   alu_res = op_a - op_b;  
      ALU_LUI:   alu_res = uop_i.imm;    
      ALU_AUIPC: alu_res = op_a + op_b;  
      ALU_AND:   alu_res = op_a & op_b;  
      ALU_OR:    alu_res = op_a | op_b;  
      ALU_XOR:   alu_res = op_a ^ op_b;  
      ALU_SLL:   alu_res = op_a <<  op_b[4:0];
      ALU_SRL:   alu_res = op_a >>  op_b[4:0];
      ALU_SRA:   alu_res = $signed(op_a) >>> op_b[4:0];
      ALU_SLT:   alu_res = ($signed(op_a) < $signed(op_b)) ? 32'b1 : 32'b0;
      ALU_SLTU:  alu_res = (op_a < op_b) ? 32'b1 : 32'b0;
      default:   alu_res = '0;
    endcase
  end

  // --- 3. 跳转与分支处理 ---
  logic [31:0] br_target;
  logic        br_take;

  // 正确的跳转目标计算
  assign br_target = (uop_i.br_op == BR_JALR) ? (rs1_data_i + uop_i.imm) : (uop_i.pc + uop_i.imm);

  // 实际分支执行结果
  always_comb begin
    br_take = 1'b0;
    if (uop_i.is_branch) begin
      unique case (uop_i.br_op)
        BR_EQ:  br_take = (rs1_data_i == rs2_data_i);
        BR_NE:  br_take = (rs1_data_i != rs2_data_i);
        BR_LT:  br_take = ($signed(rs1_data_i) <  $signed(rs2_data_i));
        BR_GE:  br_take = ($signed(rs1_data_i) >= $signed(rs2_data_i));
        BR_LTU: br_take = (rs1_data_i <  rs2_data_i);
        BR_GEU: br_take = (rs1_data_i >= rs2_data_i);
        default: br_take = 1'b0;
      endcase
    end else if (uop_i.is_jump) begin
      br_take = 1'b1;
    end
  end

  // --- 4. 预测错误判断 (给 ROB) ---
  always_comb begin
    alu_is_mispred_o  = 1'b0;
    alu_redirect_pc_o = '0;
    
    if (alu_valid_i && (uop_i.is_branch || uop_i.is_jump)) begin
        // 这里应与 uop_i 中的预测信息对比。
        // 假设目前没有预测器信息，默认前端预测不跳转(Not Taken)，
        // 则只要实际跳转(br_take)，就是误判。
        if (br_take) begin
            alu_is_mispred_o  = 1'b1; 
            alu_redirect_pc_o = br_target;
        end
    end
  end

  // --- 5. 输出赋值 ---
  assign alu_valid_o   = alu_valid_i;
  assign alu_rob_tag_o = rob_tag_i;
  // Jump 指令写回的是 PC+4 (返回地址)
  assign alu_result_o  = (uop_i.is_jump) ? (uop_i.pc + 4) : alu_res;

endmodule