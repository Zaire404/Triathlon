module ysyx_25050141_DE (
    input clk,
    input rst,
    input [`ysyx_25050141_IF_TO_DE_WIDTH - 1:0] IF_to_DE_bus,
    input [`ysyx_25050141_ME_TO_DE_WIDTH - 1:0] ME_to_DE_bus,
    output [`ysyx_25050141_DE_TO_EX_WIDTH - 1:0] DE_to_EX_bus
);
  wire [`ysyx_25050141_XLEN - 1:0] rs1_data;
  wire [`ysyx_25050141_XLEN - 1:0] rs2_data;
  wire [`ysyx_25050141_XLEN - 1:0] ME_res;
  wire [`ysyx_25050141_INSTR_WIDTH - 1:0] IF_instr;
  wire [`ysyx_25050141_PC_WIDTH - 1:0] IF_pc;
  wire [`ysyx_25050141_XLEN - 1:0] ME_valE_csr;
  wire [`ysyx_25050141_XLEN - 1:0] ME_wen_csr_index;

  wire ME_wen_csr;
  wire ME_need_dstE;
  assign {IF_pc, IF_instr} = IF_to_DE_bus;
  assign {ME_wen_csr_index, ME_wen_csr, ME_valE_csr, ME_need_dstE, ME_res} = ME_to_DE_bus;
  //译码
  //指令分解
  wire [6:0] opcode = IF_instr[6:0];
  wire [2:0] fun3 = IF_instr[14:12];
  wire [6:0] fun7 = IF_instr[31:25];
  //操作码
  wire op_branch = (opcode == `ysyx_25050141_branch);
  wire op_jal = (opcode == `ysyx_25050141_jal);
  wire op_jalr = (opcode == `ysyx_25050141_jalr);
  wire op_store = (opcode == `ysyx_25050141_store);
  wire op_load = (opcode == `ysyx_25050141_load);
  wire op_alur = (opcode == `ysyx_25050141_alur);
  wire op_alui = (opcode == `ysyx_25050141_alui);
  wire op_lui = (opcode == `ysyx_25050141_lui);
  wire op_auipc = (opcode == `ysyx_25050141_auipc);
  wire op_system = (opcode == `ysyx_25050141_system);
  wire [`ysyx_25050141_OP_WIDTH - 1:0] epcode = {
    op_system, op_auipc, op_lui, op_alui, op_alur, op_load, op_store, op_jalr, op_jal, op_branch
  };
  //alu操作
  //reg and i
  wire rv_addi = (op_alui) & (fun3 == `ysyx_25050141_ALU_add);
  wire rv_slti = (op_alui) & (fun3 == `ysyx_25050141_ALU_slt);
  wire rv_sltiu = (op_alui) & (fun3 == `ysyx_25050141_ALU_sltu);
  wire rv_xori = (op_alui) & (fun3 == `ysyx_25050141_ALU_xor);
  wire rv_ori = (op_alui) & (fun3 == `ysyx_25050141_ALU_or);
  wire rv_andi = (op_alui) & (fun3 == `ysyx_25050141_ALU_and);
  wire rv_slli = (op_alui) & (fun3 == `ysyx_25050141_ALU_sll) & (fun7 == 7'b0000000);
  wire rv_srli = (op_alui) & (fun3 == `ysyx_25050141_ALU_srl) & (fun7 == 7'b0000000);
  wire rv_srai = (op_alui) & (fun3 == `ysyx_25050141_ALU_sra) & (fun7 == 7'b0100000);

  //reg and reg
  wire rv_add = (op_alur) & (fun3 == `ysyx_25050141_ALU_add) & (fun7 == 7'b0000000);
  wire rv_sub = (op_alur) & (fun3 == `ysyx_25050141_ALU_sub) & (fun7 == 7'b0100000);
  wire rv_slt = (op_alur) & (fun3 == `ysyx_25050141_ALU_slt) & (fun7 == 7'b0000000);
  wire rv_sltu = (op_alur) & (fun3 == `ysyx_25050141_ALU_sltu) & (fun7 == 7'b0000000);
  wire rv_xor = (op_alur) & (fun3 == `ysyx_25050141_ALU_xor) & (fun7 == 7'b0000000);
  wire rv_sll = (op_alur) & (fun3 == `ysyx_25050141_ALU_sll) & (fun7 == 7'b0000000);
  wire rv_srl = (op_alur) & (fun3 == `ysyx_25050141_ALU_srl) & (fun7 == 7'b0000000);
  wire rv_sra = (op_alur) & (fun3 == `ysyx_25050141_ALU_sra) & (fun7 == 7'b0100000);
  wire rv_or = (op_alur) & (fun3 == `ysyx_25050141_ALU_or) & (fun7 == 7'b0000000);
  wire rv_and = (op_alur) & (fun3 == `ysyx_25050141_ALU_and) & (fun7 == 7'b0000000);

  //alu op
  wire ALU_add = rv_addi | rv_add;
  wire ALU_sub = rv_sub;
  wire ALU_slt = rv_slt | rv_slti;
  wire ALU_sltu = rv_sltu | rv_sltiu;
  wire ALU_xor = rv_xor | rv_xori;
  wire ALU_or = rv_or | rv_ori;
  wire ALU_and = rv_and | rv_andi;
  wire ALU_sll = rv_sll | rv_slli;
  wire ALU_sra = rv_sra | rv_srai;
  wire ALU_srl = rv_srl | rv_srli;

  wire [`ysyx_25050141_ALU_WIDTH - 1:0] ALU_op = {
    ALU_and, ALU_or, ALU_sra, ALU_srl, ALU_xor, ALU_sltu, ALU_slt, ALU_sll, ALU_sub, ALU_add
  };
  //branch操作
  wire ne = (op_branch) & (fun3 == `ysyx_25050141_ne);
  wire eq = (op_branch) & (fun3 == `ysyx_25050141_eq);
  wire lt = (op_branch) & (fun3 == `ysyx_25050141_lt);
  wire ge = (op_branch) & (fun3 == `ysyx_25050141_ge);
  wire ltu = (op_branch) & (fun3 == `ysyx_25050141_ltu);
  wire geu = (op_branch) & (fun3 == `ysyx_25050141_geu);
  wire [`ysyx_25050141_BRANCH_WIDTH - 1 : 0] branch_op = {geu, ltu, ge, lt, ne, eq};
  //立即数
  wire [`ysyx_25050141_XLEN - 1 : 0] I_imme = {{21{IF_instr[31]}}, IF_instr[30:20]};
  wire [`ysyx_25050141_XLEN - 1 : 0] S_imme = {
    {21{IF_instr[31]}}, IF_instr[30:25], IF_instr[11:8], IF_instr[7]
  };
  wire [`ysyx_25050141_XLEN - 1 : 0] B_imme = {
    {20{IF_instr[31]}}, IF_instr[7], IF_instr[30:25], IF_instr[11:8], 1'b0
  };
  wire [`ysyx_25050141_XLEN - 1 : 0] U_imme = {IF_instr[31:12], 12'b0};
  wire [`ysyx_25050141_XLEN - 1 : 0] J_imme = {
    {12{IF_instr[31]}}, IF_instr[19:12], IF_instr[20], IF_instr[30:21], 1'b0
  };
  wire I_type = op_load | op_alui | op_jalr | op_system;
  wire S_type = op_store;
  wire J_type = op_jal;
  wire U_type = op_auipc | op_lui;
  wire B_type = op_branch;
  //选择立即数
  wire [`ysyx_25050141_XLEN - 1:0] imme = 	({`ysyx_25050141_XLEN{I_type}} & I_imme) |
					({`ysyx_25050141_XLEN{S_type}} & S_imme) |
					({`ysyx_25050141_XLEN{B_type}} & B_imme) |
					({`ysyx_25050141_XLEN{U_type}} & U_imme) |
					({`ysyx_25050141_XLEN{J_type}} & J_imme);
  //load op
  wire lb = op_load & (fun3 == `ysyx_25050141_lb);
  wire lh = op_load & (fun3 == `ysyx_25050141_lh);
  wire lw = op_load & (fun3 == `ysyx_25050141_lw);
  wire lbu = op_load & (fun3 == `ysyx_25050141_lbu);
  wire lhu = op_load & (fun3 == `ysyx_25050141_lhu);
  wire [`ysyx_25050141_LOAD_WIDTH - 1:0] load_op = {lhu, lbu, lw, lh, lb};
  //store op
  wire sb = op_store & (fun3 == `ysyx_25050141_sb);
  wire sh = op_store & (fun3 == `ysyx_25050141_sh);
  wire sw = op_store & (fun3 == `ysyx_25050141_sw);
  wire [`ysyx_25050141_STORE_WIDTH - 1:0] store_op = {sw, sh, sb};
  //system op
  wire csrrw = op_system & (fun3 == `ysyx_25050141_SYS_rw);
  wire csrrs = op_system & (fun3 == `ysyx_25050141_SYS_rs);
  wire ecall = IF_instr == `ysyx_25050141_SYS_ecall;
  wire mret = IF_instr == `ysyx_25050141_SYS_mret;
  wire [`ysyx_25050141_SYS_WIDTH - 1:0] op_csr = {csrrs, csrrw};
  //写使能
  wire wen_csr = (|op_csr) | ecall;
  //w_index
  wire [`ysyx_25050141_XLEN - 1 : 0] wen_csr_index = ecall ? 32'h341 : (|op_csr) ? imme : 0;
  //r_index
  wire [`ysyx_25050141_XLEN - 1 : 0] ren_csr_index =  ecall ? 32'h305 :
														(|op_csr) ? imme :
														mret ? 32'h341 : 0;
  //选择内存还是valE
  wire sel_reg = ~op_load;
  //不需要 rd操作有
  //store branch
  //并且设置写入寄存器的编号
  wire need_dstE = (op_jal) | (op_jalr) | (op_load) | (op_alur)| (op_alui) | (op_lui) | (op_auipc) | (|op_csr);
  //--------------------------------------------------------------------------------------------------------------------
  //rs1 rs2和rd
  wire [4:0] rs1 = IF_instr[19:15];
  wire [4:0] rs2 = IF_instr[24:20];
  wire [4:0] rd = IF_instr[11:7];
  //CSR部分
  wire [`ysyx_25050141_XLEN - 1:0] mcause_data;
  wire [`ysyx_25050141_XLEN - 1:0] mtvec_data;
  wire [`ysyx_25050141_XLEN - 1:0] mepc_data;
  wire [`ysyx_25050141_XLEN - 1:0] mstatus_data;
  //写使能
  wire mtvec_wen = ME_wen_csr & (ME_wen_csr_index == 32'h305);
  wire mcause_wen = ME_wen_csr & (ME_wen_csr_index == 32'h342);
  wire mepc_wen = ME_wen_csr & (ME_wen_csr_index == 32'h341);
  wire mstatus_wen = ME_wen_csr & (ME_wen_csr_index == 32'h300);
  ysyx_25050141_RegisterFile #(32, 5, 32) RegisterFile (
      .clk(clk),
      .rst(rst),
      .raddr1(rs1),
      .raddr2(rs2),
      .wen(ME_need_dstE),
      .waddr(rd),
      .wdata(ME_res),
      .rdata1(rs1_data),
      .rdata2(rs2_data)
  );
  //CSR寄存器
  //mtvec
  ysyx_25050141_Reg #(
      .WIDTH(`ysyx_25050141_XLEN),
      .RESET_VAL(0)
  ) mtvec (
      .clk (clk),
      .rst (rst),
      .din (ME_valE_csr),
      .dout(mtvec_data),
      .wen (mtvec_wen)
  );
  //mepc
  ysyx_25050141_Reg #(
      .WIDTH(`ysyx_25050141_XLEN),
      .RESET_VAL(0)
  ) mepc (
      .clk (clk),
      .rst (rst),
      .din (ME_valE_csr),
      .dout(mepc_data),
      .wen (mepc_wen)
  );
  //mstatus
  ysyx_25050141_Reg #(
      .WIDTH(`ysyx_25050141_XLEN),
      .RESET_VAL(32'h1800)
  ) mstatus (
      .clk (clk),
      .rst (rst),
      .din (ME_valE_csr),
      .dout(mstatus_data),
      .wen (mstatus_wen)
  );
  //mcause
  ysyx_25050141_Reg #(
      .WIDTH(`ysyx_25050141_XLEN),
      .RESET_VAL(32'hb)
  ) mcause (
      .clk (clk),
      .rst (rst),
      .din (ME_valE_csr),
      .dout(mcause_data),
      .wen (mcause_wen)
  );
  import "DPI-C" function void cur_csr(
    input int mcause,
    input int mstatus,
    input int mtvec,
    input int mepc
  );
  always @(*) begin
    cur_csr(mcause_data, mstatus_data, mtvec_data, mepc_data);
  end
  wire [`ysyx_25050141_XLEN - 1:0]csr_data = 
										ren_csr_index == 32'h300 ? mstatus_data :
										ren_csr_index == 32'h305 ? mtvec_data :
										ren_csr_index == 32'h341 ? mepc_data :
										mcause_data;
  assign DE_to_EX_bus = {
    IF_pc,
    ren_csr_index,
    wen_csr_index,
    wen_csr,
    mret,
    ecall,
    op_csr,
    epcode,
    ALU_op,
    branch_op,
    load_op,
    store_op,
    need_dstE,
    sel_reg,
    imme,
    rs1_data,
    rs2_data,
    csr_data
  };
endmodule
