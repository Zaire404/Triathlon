package decode_pkg;
  import config_pkg::*;

  typedef enum logic [2:0] {
    FU_NONE,
    FU_ALU,
    FU_BRANCH,
    FU_LSU,
    FU_MUL,
    FU_DIV,
    FU_CSR
  } fu_e;

  typedef enum logic [4:0] {
    ALU_ADD,
    ALU_SUB,
    ALU_SLT,
    ALU_SLTU,
    ALU_XOR,
    ALU_OR,
    ALU_AND,
    ALU_SLL,
    ALU_SRL,
    ALU_SRA,
    ALU_LUI,
    ALU_AUIPC,
    ALU_NOP
  } alu_op_e;

  typedef enum logic [2:0] {
    BR_EQ,
    BR_NE,
    BR_LT,
    BR_GE,
    BR_LTU,
    BR_GEU,
    BR_JAL,
    BR_JALR
  } branch_op_e;

  typedef enum logic [3:0] {
    LSU_LB,
    LSU_LH,
    LSU_LW,
    LSU_LD,
    LSU_LBU,
    LSU_LHU,
    LSU_LWU,
    LSU_SB,
    LSU_SH,
    LSU_SW,
    LSU_SD
  } lsu_op_e;

  typedef struct packed {
    // 基本信息
    logic valid;
    logic illegal;

    fu_e        fu;
    alu_op_e    alu_op;
    branch_op_e br_op;
    lsu_op_e    lsu_op;

    // 寄存器号（逻辑）
    logic [4:0] rs1;
    logic [4:0] rs2;
    logic [4:0] rd;

    logic has_rs1;
    logic has_rs2;
    logic has_rd;

    // 立即数（按 XLEN 展开）
    logic [Cfg.XLEN-1:0] imm;

    // PC & 控制流信息
    logic [Cfg.PLEN-1:0] pc;

    // 其它 flag（后面可以扩展）
    logic is_load;
    logic is_store;
    logic is_branch;
    logic is_jump;
    logic is_csr;
    logic is_fence;
    logic is_ecall;
    logic is_ebreak;
    logic is_mret;
  } uop_t;
endpackage : decode_pkg
