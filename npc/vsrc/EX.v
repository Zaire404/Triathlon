module ysyx_25050141_EX (
    input [`ysyx_25050141_DE_TO_EX_WIDTH - 1:0] DE_to_EX_bus,

    output [`ysyx_25050141_EX_TO_IF_WIDTH - 1:0] EX_to_IF_bus,
    output [`ysyx_25050141_EX_TO_ME_WIDTH - 1:0] EX_to_ME_bus
);
  wire [`ysyx_25050141_SYS_WIDTH - 1:0] op_csr;
  wire [`ysyx_25050141_PC_WIDTH - 1:0] pc;
  wire [`ysyx_25050141_OP_WIDTH - 1:0] epcode;
  wire [`ysyx_25050141_ALU_WIDTH - 1:0] ALU_op;
  wire [`ysyx_25050141_BRANCH_WIDTH - 1 : 0] branch_op;
  wire [`ysyx_25050141_XLEN - 1:0] imme;
  wire [`ysyx_25050141_STORE_WIDTH - 1:0] store_op;
  wire [`ysyx_25050141_LOAD_WIDTH - 1:0] load_op;
  wire [`ysyx_25050141_XLEN - 1:0] rs1_data;
  wire [`ysyx_25050141_XLEN - 1:0] rs2_data;

  wire [`ysyx_25050141_XLEN - 1:0] ren_csr_index;
  wire [`ysyx_25050141_XLEN - 1:0] wen_csr_index;
  wire [`ysyx_25050141_XLEN - 1:0] csr_data;
  wire wen_csr;
  wire sel_reg;
  wire need_dstE;
  wire ecall;
  wire mret;
  assign  {pc, ren_csr_index, wen_csr_index, wen_csr, mret, ecall, op_csr, epcode ,ALU_op, branch_op, load_op, store_op, need_dstE, sel_reg, imme,rs1_data,rs2_data, csr_data} = DE_to_EX_bus;
  //opcode OP
  wire op_branch = epcode[`ysyx_25050141_op_branch];
  wire op_jal = epcode[`ysyx_25050141_op_jal];
  wire op_jalr = epcode[`ysyx_25050141_op_jalr];
  wire op_store = epcode[`ysyx_25050141_op_store];
  wire op_load = epcode[`ysyx_25050141_op_load];
  wire op_alur = epcode[`ysyx_25050141_op_alur];
  wire op_alui = epcode[`ysyx_25050141_op_alui];
  wire op_lui = epcode[`ysyx_25050141_op_lui];
  wire op_auipc = epcode[`ysyx_25050141_op_auipc];
  //ALU OP
  wire alu_add = ALU_op[`ysyx_25050141_alu_add];
  wire alu_sub = ALU_op[`ysyx_25050141_alu_sub];
  wire alu_sll = ALU_op[`ysyx_25050141_alu_sll];
  wire alu_slt = ALU_op[`ysyx_25050141_alu_slt];
  wire alu_sltu = ALU_op[`ysyx_25050141_alu_sltu];
  wire alu_xor = ALU_op[`ysyx_25050141_alu_xor];
  wire alu_srl = ALU_op[`ysyx_25050141_alu_srl];
  wire alu_sra = ALU_op[`ysyx_25050141_alu_sra];
  wire alu_or = ALU_op[`ysyx_25050141_alu_or];
  wire alu_and = ALU_op[`ysyx_25050141_alu_and];
  //BRANCH OP
  wire branch_eq = branch_op[`ysyx_25050141_branch_eq];
  wire branch_ne = branch_op[`ysyx_25050141_branch_ne];
  wire branch_lt = branch_op[`ysyx_25050141_branch_lt];
  wire branch_ge = branch_op[`ysyx_25050141_branch_ge];
  wire branch_ltu = branch_op[`ysyx_25050141_branch_ltu];
  wire branch_geu = branch_op[`ysyx_25050141_branch_geu];
  //CSR OP
  wire sys_rs = op_csr[`ysyx_25050141_sys_rs];
  wire sys_rw = op_csr[`ysyx_25050141_sys_rw];
  //ALU计算
  //操作数的选择
  //OP1 : jal/jalr/auipc:pc
  //		lui:0
  //		rs1_data

  //OP2 : jal/jalr:4
  //		store/load/lui/auipc/alui: imme
  //      rs2_data
  wire [`ysyx_25050141_XLEN - 1:0] OP1 =  	(op_jal | op_jalr | op_auipc) ? pc :
         (op_lui) ? 0 : rs1_data;

  wire [`ysyx_25050141_XLEN - 1:0] OP2 =    (op_jal | op_jalr) ? 4 :
         (op_store | op_load | op_lui | op_alui | op_auipc) ? imme : rs2_data;
  //ALU sel
  wire use_sub = alu_sub | alu_slt | alu_sltu | op_branch;
  wire sel_add = alu_add | op_lui | op_auipc | op_store | op_load | op_jal | op_jalr;
  wire sel_sub = alu_sub;
  wire sel_sll = alu_sll;
  wire sel_slt = alu_slt;
  wire sel_sltu = alu_sltu;
  wire sel_xor = alu_xor;
  wire sel_srl = alu_srl;
  wire sel_sra = alu_sra;
  wire sel_or = alu_or;
  wire sel_and = alu_and;
  wire sel_csr = |op_csr;
  //valE
  wire [`ysyx_25050141_XLEN - 1:0] res_add_sub;
  wire [`ysyx_25050141_XLEN - 1:0] res_sll;
  wire [`ysyx_25050141_XLEN - 1:0] res_slt;
  wire [`ysyx_25050141_XLEN - 1:0] res_sltu;
  wire [`ysyx_25050141_XLEN - 1:0] res_xor;
  wire [`ysyx_25050141_XLEN - 1:0] res_srl;
  wire [`ysyx_25050141_XLEN - 1:0] res_sra;
  wire [`ysyx_25050141_XLEN - 1:0] res_or;
  wire [`ysyx_25050141_XLEN - 1:0] res_and;
  wire [`ysyx_25050141_XLEN - 1:0] res_OP1;
  wire [`ysyx_25050141_XLEN - 1:0] res_rw;
  wire [`ysyx_25050141_XLEN - 1:0] res_rs;
  //sub and ADD
  wire cin = use_sub;
  wire cout;
  wire [`ysyx_25050141_XLEN - 1:0] adder_OP1 = OP1;
  wire [`ysyx_25050141_XLEN - 1:0] adder_OP2 = {`ysyx_25050141_XLEN{use_sub}} ^ OP2;
  assign {cout, res_add_sub} = adder_OP1 + adder_OP2 + {{31{1'b0}}, cin};

  //slt and sltu
  wire lt = (OP1[`ysyx_25050141_XLEN - 1] & ~OP2[`ysyx_25050141_XLEN - 1]) | ((~(OP2[`ysyx_25050141_XLEN - 1] ^ OP1[`ysyx_25050141_XLEN - 1])) & res_add_sub[`ysyx_25050141_XLEN - 1]);
  wire ltu = ~cout;
  assign res_slt  = {31'b0, lt};
  assign res_sltu = {31'b0, ltu};
  //移位
  wire [4:0] shift_OP2 = OP2[4:0];
  //sll
  assign res_sll = OP1 << shift_OP2;
  //srl
  assign res_srl = OP1 >> shift_OP2;
  //sra
  assign res_sra = $signed(OP1) >>> shift_OP2;
  //xor
  assign res_xor = OP1 ^ OP2;
  //and
  assign res_and = OP1 & OP2;
  //or
  assign res_or  = OP1 | OP2;
  //csrrs
  assign res_rs  = csr_data | OP1;
  //csrrw
  assign res_rw  = OP1;
  //CSR OP

  wire [`ysyx_25050141_XLEN - 1:0] valE =
         ({`ysyx_25050141_XLEN{sel_slt}} & res_slt ) |
         ({`ysyx_25050141_XLEN{sel_sltu}} & res_sltu ) |
         ({`ysyx_25050141_XLEN{sel_add | sel_sub}} & res_add_sub ) |
         ({`ysyx_25050141_XLEN{sel_sll}} & res_sll ) |
         ({`ysyx_25050141_XLEN{sel_xor}} & res_xor ) |
         ({`ysyx_25050141_XLEN{sel_srl}} & res_srl ) |
         ({`ysyx_25050141_XLEN{sel_sra}} & res_sra ) |
         ({`ysyx_25050141_XLEN{sel_or}} & res_or ) |
         ({`ysyx_25050141_XLEN{sel_and}} & res_and ) |
         ({`ysyx_25050141_XLEN{sel_csr}} & csr_data );
  wire [`ysyx_25050141_XLEN - 1:0] valE_csr =
         ({`ysyx_25050141_XLEN{sys_rs}} & res_rs ) |
         ({`ysyx_25050141_XLEN{sys_rw}} & res_rw ) |
         ({`ysyx_25050141_XLEN{ecall}} & pc );
  //处理Branch
  // wire lt = (OP1[`ysyx_25050141_XLEN - 1] & ~OP2[`ysyx_25050141_XLEN - 1]) | ((~(OP2[`ysyx_25050141_XLEN - 1] ^ OP1[`ysyx_25050141_XLEN - 1])) & res_add_sub[`ysyx_25050141_XLEN - 1]);
  // wire ltu = ~cout;
  wire ne = (|res_add_sub);
  wire ge = ~lt;
  wire geu = ~ltu;
  wire eq = ~ne;
  wire branch_taken =
         (((branch_eq & eq) |
           (branch_ne & ne) |
           (branch_lt & lt) |
           (branch_ge & ge) |
           (branch_ltu & ltu) |
           (branch_geu & geu)));
  wire [`ysyx_25050141_PC_WIDTH - 1 : 0] pc_op1 = (op_jalr) ? rs1_data : pc;
  wire [`ysyx_25050141_PC_WIDTH - 1 : 0] pc_op2 = (op_jalr | op_jal | (op_branch & branch_taken)) ? imme : 4;
  wire [`ysyx_25050141_PC_WIDTH - 1 : 0] npc = ecall | mret ? csr_data : pc_op1 + pc_op2;

  assign EX_to_IF_bus = {npc};
  assign EX_to_ME_bus = {
    wen_csr_index, wen_csr, valE_csr, need_dstE, valE, sel_reg, load_op, store_op, rs2_data
  };
endmodule
