// vsrc/backend/decoder.sv
import global_config_pkg::*;
import config_pkg::*;
import decode_pkg::*;

module decoder #(
    parameter config_pkg::cfg_t Cfg = config_pkg::EmptyCfg,
    parameter int unsigned DECODE_WIDTH = Cfg.INSTR_PER_FETCH
) (
    input logic clk_i,
    input logic rst_ni,

    // 来自 IBuffer
    input  logic                                  ibuf2dec_valid_i,
    output logic                                  dec2ibuf_ready_o,
    input  logic [DECODE_WIDTH-1:0][Cfg.ILEN-1:0] ibuf_instrs_i,
    input  logic [DECODE_WIDTH-1:0][Cfg.PLEN-1:0] ibuf_pcs_i,

    // 输出到 Rename / Issue Stage
    output logic                    dec2backend_valid_o,
    input  logic                    backend2dec_ready_i,
    output logic [DECODE_WIDTH-1:0] dec_slot_valid_o,
    output uop_t [DECODE_WIDTH-1:0] dec_uops_o
);

  // ============================================================
  //  valid/ready：本版 decoder 做纯组合，1:1 透传
  // ============================================================

  assign dec2ibuf_ready_o = backend2dec_ready_i;  // 下游 ready 直接 back-pressure 到 IBuffer
  assign dec2backend_valid_o = ibuf2dec_valid_i;  // 上游 valid 直接传给下游

  // 每个 slot 是否 decode 出一条有效 uop
  // （目前只要 ibuf 这条指令在这个 slot 有效，就认为 valid）
  for (genvar i = 0; i < DECODE_WIDTH; i++) begin : g_slot_valid
    assign dec_slot_valid_o[i] = ibuf2dec_valid_i; // 后面可以加入“这条是不是 NOP/空洞”的逻辑
  end

  // ============================================================
  //  每个 lane 独立 decode
  // ============================================================

  for (genvar lane = 0; lane < DECODE_WIDTH; lane++) begin : g_decode_lane
    always_comb begin
      dec_uops_o[lane] = decode_one(ibuf_instrs_i[lane], ibuf_pcs_i[lane]);
      // 如果本 lane 实际上是“bubble”，可以在这里把 valid 清掉：
      // if (!ibuf_valid_i) dec_uops_o[lane].valid = 1'b0;
    end
  end

  // ============================================================
  //  辅助函数：立即数生成
  // ============================================================

  function automatic logic [Cfg.XLEN-1:0] imm_i(input logic [31:0] instr);
    logic [31:0] imm32;
    begin
      imm32 = {{20{instr[31]}}, instr[31:20]};
      imm_i = {{(Cfg.XLEN - 32) {imm32[31]}}, imm32};
    end
  endfunction

  function automatic logic [Cfg.XLEN-1:0] imm_s(input logic [31:0] instr);
    logic [31:0] imm32;
    begin
      imm32 = {{20{instr[31]}}, instr[31:25], instr[11:7]};
      imm_s = {{(Cfg.XLEN - 32) {imm32[31]}}, imm32};
    end
  endfunction

  function automatic logic [Cfg.XLEN-1:0] imm_b(input logic [31:0] instr);
    logic [31:0] imm32;
    begin
      imm32 = {{19{instr[31]}}, instr[31], instr[7], instr[30:25], instr[11:8], 1'b0};
      imm_b = {{(Cfg.XLEN - 32) {imm32[31]}}, imm32};
    end
  endfunction

  function automatic logic [Cfg.XLEN-1:0] imm_u(input logic [31:0] instr);
    logic [31:0] imm32;
    begin
      imm32 = {instr[31:12], 12'b0};
      imm_u = {{(Cfg.XLEN - 32) {imm32[31]}}, imm32};
    end
  endfunction

  function automatic logic [Cfg.XLEN-1:0] imm_j(input logic [31:0] instr);
    logic [31:0] imm32;
    begin
      imm32 = {{11{instr[31]}}, instr[31], instr[19:12], instr[20], instr[30:21], 1'b0};
      imm_j = {{(Cfg.XLEN - 32) {imm32[31]}}, imm32};
    end
  endfunction

  // ============================================================
  //  核心：单条指令 decode（可参考 CVA6 的 case 写法）
  // ============================================================

  function automatic uop_t decode_one(input logic [Cfg.ILEN-1:0] instr,
                                      input logic [Cfg.PLEN-1:0] pc);
    uop_t u;

    logic [6:0] opcode;
    logic [2:0] funct3;
    logic [6:0] funct7;
    logic [4:0] rs1, rs2, rd;

    begin
      opcode      = instr[6:0];
      funct3      = instr[14:12];
      funct7      = instr[31:25];
      rs1         = instr[19:15];
      rs2         = instr[24:20];
      rd          = instr[11:7];

      // 默认值
      u.valid     = 1'b1;
      u.illegal   = 1'b0;

      u.fu        = FU_ALU;
      u.alu_op    = ALU_NOP;
      u.br_op     = BR_EQ;
      u.lsu_op    = LSU_LW;

      u.rs1       = rs1;
      u.rs2       = rs2;
      u.rd        = rd;
      u.has_rs1   = 1'b0;
      u.has_rs2   = 1'b0;
      u.has_rd    = 1'b0;

      u.imm       = '0;
      u.pc        = pc;

      u.is_load   = 1'b0;
      u.is_store  = 1'b0;
      u.is_branch = 1'b0;
      u.is_jump   = 1'b0;
      u.is_csr    = 1'b0;
      u.is_fence  = 1'b0;
      u.is_ecall  = 1'b0;
      u.is_ebreak = 1'b0;
      u.is_mret   = 1'b0;

      // 主 decode
      unique case (opcode)
        // -------------------------
        // U-type: LUI / AUIPC
        // -------------------------
        7'b0110111: begin  // LUI
          u.fu     = FU_ALU;
          u.alu_op = ALU_LUI;
          u.has_rd = (rd != '0);
          u.imm    = imm_u(instr);
        end

        7'b0010111: begin  // AUIPC
          u.fu     = FU_ALU;
          u.alu_op = ALU_AUIPC;
          u.has_rd = (rd != '0);
          u.imm    = imm_u(instr);
        end

        // -------------------------
        // JAL / JALR
        // -------------------------
        7'b1101111: begin  // JAL
          u.fu        = FU_BRANCH;
          u.br_op     = BR_JAL;
          u.is_jump   = 1'b1;
          u.is_branch = 1'b1;
          u.has_rd    = (rd != '0);
          u.imm       = imm_j(instr);
        end

        7'b1100111: begin  // JALR
          u.fu        = FU_BRANCH;
          u.br_op     = BR_JALR;
          u.is_jump   = 1'b1;
          u.is_branch = 1'b1;
          u.has_rs1   = 1'b1;
          u.has_rd    = (rd != '0);
          u.imm       = imm_i(instr);
        end

        // -------------------------
        // Branch
        // -------------------------
        7'b1100011: begin  // BRANCH
          u.fu        = FU_BRANCH;
          u.is_branch = 1'b1;
          u.has_rs1   = 1'b1;
          u.has_rs2   = 1'b1;
          u.imm       = imm_b(instr);
          unique case (funct3)
            3'b000:  u.br_op = BR_EQ;  // BEQ
            3'b001:  u.br_op = BR_NE;  // BNE
            3'b100:  u.br_op = BR_LT;  // BLT
            3'b101:  u.br_op = BR_GE;  // BGE
            3'b110:  u.br_op = BR_LTU;  // BLTU
            3'b111:  u.br_op = BR_GEU;  // BGEU
            default: u.illegal = 1'b1;
          endcase
        end

        // -------------------------
        // Load / Store
        // -------------------------
        7'b0000011: begin  // LOAD
          u.fu      = FU_LSU;
          u.is_load = 1'b1;
          u.has_rs1 = 1'b1;
          u.has_rd  = (rd != '0);
          u.imm     = imm_i(instr);
          unique case (funct3)
            3'b000:  u.lsu_op = LSU_LB;
            3'b001:  u.lsu_op = LSU_LH;
            3'b010:  u.lsu_op = LSU_LW;
            3'b011:  u.lsu_op = LSU_LD;
            3'b100:  u.lsu_op = LSU_LBU;
            3'b101:  u.lsu_op = LSU_LHU;
            3'b110:  u.lsu_op = LSU_LWU;
            default: u.illegal = 1'b1;
          endcase
        end

        7'b0100011: begin  // STORE
          u.fu       = FU_LSU;
          u.is_store = 1'b1;
          u.has_rs1  = 1'b1;
          u.has_rs2  = 1'b1;
          u.imm      = imm_s(instr);
          unique case (funct3)
            3'b000:  u.lsu_op = LSU_SB;
            3'b001:  u.lsu_op = LSU_SH;
            3'b010:  u.lsu_op = LSU_SW;
            3'b011:  u.lsu_op = LSU_SD;
            default: u.illegal = 1'b1;
          endcase
        end

        // -------------------------
        // OP-IMM
        // -------------------------
        7'b0010011: begin  // OP-IMM
          u.fu      = FU_ALU;
          u.has_rs1 = 1'b1;
          u.has_rd  = (rd != '0);
          u.imm     = imm_i(instr);
          unique case (funct3)
            3'b000:  u.alu_op = ALU_ADD;  // ADDI
            3'b010:  u.alu_op = ALU_SLT;  // SLTI
            3'b011:  u.alu_op = ALU_SLTU;  // SLTIU
            3'b100:  u.alu_op = ALU_XOR;  // XORI
            3'b110:  u.alu_op = ALU_OR;  // ORI
            3'b111:  u.alu_op = ALU_AND;  // ANDI
            3'b001: begin  // SLLI
              u.alu_op = ALU_SLL;
            end
            3'b101: begin
              // SRLI/SRAI: 区分 funct7[5]
              if (funct7[5]) u.alu_op = ALU_SRA;
              else u.alu_op = ALU_SRL;
            end
            default: u.illegal = 1'b1;
          endcase
        end

        // -------------------------
        // OP (寄存器-寄存器), 包含 M 扩展
        // -------------------------
        7'b0110011: begin  // OP
          u.fu      = FU_ALU;
          u.has_rs1 = 1'b1;
          u.has_rs2 = 1'b1;
          u.has_rd  = (rd != '0);
          unique case ({
            funct7, funct3
          })
            // RV64I
            {7'b0000000, 3'b000} : u.alu_op = ALU_ADD;  // ADD
            {7'b0100000, 3'b000} : u.alu_op = ALU_SUB;  // SUB
            {7'b0000000, 3'b010} : u.alu_op = ALU_SLT;  // SLT
            {7'b0000000, 3'b011} : u.alu_op = ALU_SLTU;  // SLTU
            {7'b0000000, 3'b100} : u.alu_op = ALU_XOR;  // XOR
            {7'b0000000, 3'b110} : u.alu_op = ALU_OR;  // OR
            {7'b0000000, 3'b111} : u.alu_op = ALU_AND;  // AND
            {7'b0000000, 3'b001} : u.alu_op = ALU_SLL;  // SLL
            {7'b0000000, 3'b101} : u.alu_op = ALU_SRL;  // SRL
            {7'b0100000, 3'b101} : u.alu_op = ALU_SRA;  // SRA

            // RV64M：这里你可以把 fu 切成 FU_MUL/FU_DIV，如果你愿意
            {
              7'b0000001, 3'b000
            } : begin
              u.fu = FU_MUL;  /* MUL */
            end
            {
              7'b0000001, 3'b001
            } : begin
              u.fu = FU_MUL;  /* MULH */
            end
            {
              7'b0000001, 3'b010
            } : begin
              u.fu = FU_MUL;  /* MULHSU */
            end
            {
              7'b0000001, 3'b011
            } : begin
              u.fu = FU_MUL;  /* MULHU */
            end
            {
              7'b0000001, 3'b100
            } : begin
              u.fu = FU_DIV;  /* DIV */
            end
            {
              7'b0000001, 3'b101
            } : begin
              u.fu = FU_DIV;  /* DIVU */
            end
            {
              7'b0000001, 3'b110
            } : begin
              u.fu = FU_DIV;  /* REM */
            end
            {
              7'b0000001, 3'b111
            } : begin
              u.fu = FU_DIV;  /* REMU */
            end

            default: u.illegal = 1'b1;
          endcase
        end

        // -------------------------
        // FENCE / FENCE.I
        // -------------------------
        7'b0001111: begin
          u.fu       = FU_ALU;
          u.is_fence = 1'b1;
          // 你可以在后端直接把它当成 barrier，看系统需求
        end

        // -------------------------
        // SYSTEM (CSR / ECALL / EBREAK / MRET)
        // -------------------------
        7'b1110011: begin
          u.fu     = FU_CSR;
          u.is_csr = 1'b1;
          unique case (funct3)
            3'b000: begin
              // ECALL / EBREAK / MRET / WFI, 见 CSR 规范
              if (instr[31:20] == 12'h000) u.is_ecall = 1'b1;
              else if (instr[31:20] == 12'h001) u.is_ebreak = 1'b1;
              else if (instr[31:20] == 12'h302) u.is_mret = 1'b1;
              else u.illegal = 1'b1;
            end
            default: begin
              // 真正的 CSR 读写：CSRRS/CSRRC/CSRRW 等，你可以在这里扩展
              // RISCV-Reader p33
              u.has_rs1 = 1'b1;
              u.has_rd  = (rd != '0);
              // TODO: 增加 csr_op 枚举
            end
          endcase
        end

        default: begin
          u.illegal = 1'b1;
        end
      endcase

      decode_one = u;
    end
  endfunction

endmodule
