// vsrc/backend/execute/alu.sv
import config_pkg::*;
import decode_pkg::*;

module execute_alu #(
    parameter config_pkg::cfg_t Cfg = config_pkg::EmptyCfg,
    parameter TAG_W = 6,
    // [改进] 提取通用参数，避免代码中到处写 Cfg.XLEN
    parameter XLEN = Cfg.XLEN,
    parameter PC_W = Cfg.PLEN
) (
    input logic clk_i,
    input logic rst_ni,

    // 来自 Issue 阶段
    input logic                         alu_valid_i,
    input decode_pkg::uop_t             uop_i,
    input logic             [ XLEN-1:0] rs1_data_i,   // [改进] 使用参数化位宽
    input logic             [ XLEN-1:0] rs2_data_i,
    input logic             [TAG_W-1:0] rob_tag_i,

    // 写回结果端口
    output logic             alu_valid_o,
    output logic [TAG_W-1:0] alu_rob_tag_o,
    output logic [ XLEN-1:0] alu_result_o,

    // 控制流信息
    output logic            alu_is_mispred_o,
    output logic [PC_W-1:0] alu_redirect_pc_o
);

  // [改进] 定义常量，方便后续扩展（如支持压缩指令时可改为变量）
  localparam logic [PC_W-1:0] INSTR_SIZE = 'd4;
  localparam SHAMT_W = $clog2(XLEN);  // 移位量位宽 (32位为5, 64位为6)

  // --- 1. 操作数准备 ---
  logic [XLEN-1:0] op_a;
  logic [XLEN-1:0] op_b;

  // Operand A 选择
  // [注意] PC 需要扩展到 XLEN 宽度参与运算
  assign op_a = (uop_i.alu_op == ALU_AUIPC) ? XLEN'(uop_i.pc) : rs1_data_i;

  // Operand B 选择
  assign op_b = (uop_i.has_rs2) ? rs2_data_i : uop_i.imm;

  // --- 2. 算术与逻辑核心 ---
  logic [XLEN-1:0] alu_res;
  logic [31:0]     alu_res_w;
  logic [31:0]     op_a_w;
  logic [31:0]     op_b_w;
  logic signed [XLEN-1:0] op_a_s;
  logic signed [XLEN-1:0] op_b_s;
  logic [XLEN-1:0] op_a_u;
  logic [XLEN-1:0] op_b_u;
  logic signed [XLEN:0] mul_a_ss;
  logic signed [XLEN:0] mul_b_ss;
  logic signed [XLEN:0] mul_b_su;
  logic [XLEN:0] mul_a_uu;
  logic [XLEN:0] mul_b_uu;
  logic signed [2*XLEN+1:0] mul_prod_ss;
  logic signed [2*XLEN+1:0] mul_prod_su;
  logic [2*XLEN+1:0] mul_prod_uu;
  logic [XLEN-1:0] min_int;

  assign op_a_s = $signed(op_a);
  assign op_b_s = $signed(op_b);
  assign op_a_u = op_a;
  assign op_b_u = op_b;
  assign mul_a_ss = {op_a[XLEN-1], op_a};
  assign mul_b_ss = {op_b[XLEN-1], op_b};
  assign mul_b_su = $signed({1'b0, op_b});
  assign mul_a_uu = {1'b0, op_a};
  assign mul_b_uu = {1'b0, op_b};
  assign mul_prod_ss = mul_a_ss * mul_b_ss;
  assign mul_prod_su = mul_a_ss * mul_b_su;
  assign mul_prod_uu = mul_a_uu * mul_b_uu;
  assign min_int = {1'b1, {(XLEN - 1) {1'b0}}};

  always_comb begin
    alu_res = '0;
    alu_res_w = '0;
    op_a_w = op_a[31:0];
    op_b_w = op_b[31:0];

    if (uop_i.is_word_op) begin
      unique case (uop_i.alu_op)
        ALU_ADD:   alu_res_w = op_a_w + op_b_w;
        ALU_SUB:   alu_res_w = op_a_w - op_b_w;
        ALU_SLL:   alu_res_w = op_a_w << op_b_w[4:0];
        ALU_SRL:   alu_res_w = op_a_w >> op_b_w[4:0];
        ALU_SRA:   alu_res_w = $signed(op_a_w) >>> op_b_w[4:0];
        default:   alu_res_w = '0;
      endcase
      alu_res = {{(XLEN-32){alu_res_w[31]}}, alu_res_w};
    end else begin
      unique case (uop_i.alu_op)
        ALU_ADD:   alu_res = op_a + op_b;
        ALU_SUB:   alu_res = op_a - op_b;
        ALU_LUI:   alu_res = uop_i.imm;
        ALU_AUIPC: alu_res = op_a + op_b;
        ALU_AND:   alu_res = op_a & op_b;
        ALU_OR:    alu_res = op_a | op_b;
        ALU_XOR:   alu_res = op_a ^ op_b;
        // [改进] 移位操作数位宽使用 SHAMT_W 截断，避免硬编码 [4:0]
        ALU_SLL:   alu_res = op_a << op_b[SHAMT_W-1:0];
        ALU_SRL:   alu_res = op_a >> op_b[SHAMT_W-1:0];
        ALU_SRA:   alu_res = $signed(op_a) >>> op_b[SHAMT_W-1:0];
        // [改进] 比较结果使用 XLEN'(1) 适配位宽
        ALU_SLT:   alu_res = ($signed(op_a) < $signed(op_b)) ? XLEN'(1) : '0;
        ALU_SLTU:  alu_res = (op_a < op_b) ? XLEN'(1) : '0;
        ALU_MUL:   alu_res = mul_prod_uu[XLEN-1:0];
        ALU_MULH:  alu_res = mul_prod_ss[2*XLEN-1:XLEN];
        ALU_MULHSU: alu_res = mul_prod_su[2*XLEN-1:XLEN];
        ALU_MULHU: alu_res = mul_prod_uu[2*XLEN-1:XLEN];
        ALU_DIV: begin
          if (op_b_u == '0) begin
            alu_res = '1;
          end else if ((op_a_u == min_int) && (op_b_u == {XLEN{1'b1}})) begin
            alu_res = min_int;
          end else begin
            alu_res = op_a_s / op_b_s;
          end
        end
        ALU_DIVU: begin
          if (op_b_u == '0) begin
            alu_res = '1;
          end else begin
            alu_res = op_a_u / op_b_u;
          end
        end
        ALU_REM: begin
          if (op_b_u == '0) begin
            alu_res = op_a_u;
          end else if ((op_a_u == min_int) && (op_b_u == {XLEN{1'b1}})) begin
            alu_res = '0;
          end else begin
            alu_res = op_a_s % op_b_s;
          end
        end
        ALU_REMU: begin
          if (op_b_u == '0) begin
            alu_res = op_a_u;
          end else begin
            alu_res = op_a_u % op_b_u;
          end
        end
        default:   alu_res = '0;
      endcase
    end
  end

  // --- 3. 跳转与分支处理 ---
  logic [PC_W-1:0] br_target;
  logic            br_take;

  // 正确的跳转目标计算
  assign br_target = (uop_i.br_op == BR_JALR) ?
      // [改进] JALR 最低位清零使用位宽参数
      ((rs1_data_i + uop_i.imm) & ~XLEN'(1)) : (uop_i.pc + uop_i.imm);

  // 实际分支执行结果
  always_comb begin
    br_take = 1'b0;
    if (uop_i.is_branch) begin
      unique case (uop_i.br_op)
        BR_EQ: br_take = (rs1_data_i == rs2_data_i);
        BR_NE: br_take = (rs1_data_i != rs2_data_i);
        BR_LT: br_take = ($signed(rs1_data_i) < $signed(rs2_data_i));
        BR_GE: br_take = ($signed(rs1_data_i) >= $signed(rs2_data_i));
        BR_LTU: br_take = (rs1_data_i < rs2_data_i);
        BR_GEU: br_take = (rs1_data_i >= rs2_data_i);
        BR_JAL, BR_JALR: br_take = 1'b1;
        default: br_take = 1'b0;
      endcase
    end else if (uop_i.is_jump) begin
      br_take = 1'b1;
    end
  end

  // --- 4. 预测错误判断 (给 ROB) ---
  logic            control_uop;
  logic [PC_W-1:0] actual_npc;

  assign control_uop = uop_i.is_branch || uop_i.is_jump;
  assign actual_npc = br_take ? br_target : (uop_i.pc + INSTR_SIZE);

  always_comb begin
    alu_is_mispred_o  = 1'b0;
    alu_redirect_pc_o = '0;

    if (alu_valid_i && control_uop) begin
      alu_redirect_pc_o = actual_npc;
      alu_is_mispred_o  = (actual_npc != uop_i.pred_npc);
    end
  end

  // --- 5. 输出赋值 ---
  assign alu_valid_o = alu_valid_i;
  assign alu_rob_tag_o = rob_tag_i;

  // [改进] 使用 PC_W 截断和常量
  assign alu_result_o = (uop_i.is_jump)   ? XLEN'(uop_i.pc + INSTR_SIZE) :
                        (uop_i.is_branch) ? '0 : alu_res;

endmodule
