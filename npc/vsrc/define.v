//操作码
`define ysyx_25050141_branch 7'b1100011
`define ysyx_25050141_jal 7'b1101111
`define ysyx_25050141_jalr 7'b1100111
`define ysyx_25050141_store 7'b0100011
`define ysyx_25050141_load 7'b0000011
`define ysyx_25050141_alur 7'b0110011
`define ysyx_25050141_alui 7'b0010011
`define ysyx_25050141_lui 7'b0110111
`define ysyx_25050141_auipc 7'b0010111
`define ysyx_25050141_system 7'b1110011

`define ysyx_25050141_OP_WIDTH 10
`define ysyx_25050141_op_branch 0
`define ysyx_25050141_op_jal 1
`define ysyx_25050141_op_jalr 2
`define ysyx_25050141_op_store 3
`define ysyx_25050141_op_load 4
`define ysyx_25050141_op_alur 5
`define ysyx_25050141_op_alui 6
`define ysyx_25050141_op_lui 7
`define ysyx_25050141_op_auipc 8
`define ysyx_25050141_op_system 9
//ALU操作
`define ysyx_25050141_ALU_add 3'b000
`define ysyx_25050141_ALU_sub 3'b000
`define ysyx_25050141_ALU_sll 3'b001
`define ysyx_25050141_ALU_slt 3'b010
`define ysyx_25050141_ALU_sltu 3'b011
`define ysyx_25050141_ALU_xor 3'b100
`define ysyx_25050141_ALU_srl 3'b101
`define ysyx_25050141_ALU_sra 3'b101
`define ysyx_25050141_ALU_or 3'b110
`define ysyx_25050141_ALU_and 3'b111

`define ysyx_25050141_ALU_WIDTH 10
`define ysyx_25050141_alu_add 0
`define ysyx_25050141_alu_sub 1
`define ysyx_25050141_alu_sll 2
`define ysyx_25050141_alu_slt 3
`define ysyx_25050141_alu_sltu 4
`define ysyx_25050141_alu_xor 5
`define ysyx_25050141_alu_srl 6
`define ysyx_25050141_alu_sra 7
`define ysyx_25050141_alu_or 8
`define ysyx_25050141_alu_and 9


//branch操作
`define ysyx_25050141_eq 3'b000
`define ysyx_25050141_ne 3'b001
`define ysyx_25050141_lt 3'b100
`define ysyx_25050141_ge 3'b101
`define ysyx_25050141_ltu 3'b110
`define ysyx_25050141_geu 3'b111

`define ysyx_25050141_BRANCH_WIDTH 6
`define ysyx_25050141_branch_eq 0 
`define ysyx_25050141_branch_ne 1
`define ysyx_25050141_branch_lt 2
`define ysyx_25050141_branch_ge 3
`define ysyx_25050141_branch_ltu 4
`define ysyx_25050141_branch_geu 5

//store
`define ysyx_25050141_sb 3'b000
`define ysyx_25050141_sh 3'b001
`define ysyx_25050141_sw 3'b010

`define ysyx_25050141_STORE_WIDTH 3
`define ysyx_25050141_store_sb 0
`define ysyx_25050141_store_sh 1
`define ysyx_25050141_store_sw 2
//load
`define ysyx_25050141_lb 3'b000
`define ysyx_25050141_lh 3'b001
`define ysyx_25050141_lw 3'b010
`define ysyx_25050141_lbu 3'b100
`define ysyx_25050141_lhu 3'b101

`define ysyx_25050141_LOAD_WIDTH 5
`define ysyx_25050141_load_lb 0
`define ysyx_25050141_load_lh 1
`define ysyx_25050141_load_lw 2
`define ysyx_25050141_load_lbu 3
`define ysyx_25050141_load_lhu 4

`define ysyx_25050141_SYS_WIDTH 2
`define ysyx_25050141_sys_rw 0
`define ysyx_25050141_sys_rs 1

`define ysyx_25050141_SYS_rw 3'b001
`define ysyx_25050141_SYS_rs 3'b010


`define ysyx_25050141_SYS_ecall 32'h00000073
`define ysyx_25050141_SYS_mret 32'h30200073

//指令长度 PC长度 字长
`define ysyx_25050141_INSTR_WIDTH 32
`define ysyx_25050141_PC_WIDTH 32
`define ysyx_25050141_XLEN 32
`define ysyx_25050141_pc 32'h80000000

`define ysyx_25050141_IF_TO_DE_WIDTH `ysyx_25050141_PC_WIDTH + `ysyx_25050141_INSTR_WIDTH
//PC + instr = 32 + 32
`define ysyx_25050141_DE_TO_EX_WIDTH `ysyx_25050141_PC_WIDTH +  `ysyx_25050141_OP_WIDTH + `ysyx_25050141_ALU_WIDTH + `ysyx_25050141_BRANCH_WIDTH + `ysyx_25050141_LOAD_WIDTH + `ysyx_25050141_STORE_WIDTH + 1 + 1 + `ysyx_25050141_XLEN + `ysyx_25050141_SYS_WIDTH + 1 + 1 + 1 + `ysyx_25050141_XLEN + `ysyx_25050141_XLEN + `ysyx_25050141_XLEN  + `ysyx_25050141_XLEN + `ysyx_25050141_XLEN
//pc + ID + rs1_data + rs2_data + csr_data + epcode + ALU_op + branch_op + load_op + store_op + need_dstE + sel_reg + imme + system_op + ecall + mret + wen_csr + wen_csr_index + ren_csr_index + rs1 + rs2 + rd
//32 + 67 + 32 + 32
`define ysyx_25050141_EX_TO_IF_WIDTH `ysyx_25050141_PC_WIDTH
//npc

`define  ysyx_25050141_EX_TO_ME_WIDTH `ysyx_25050141_XLEN + 1 + `ysyx_25050141_LOAD_WIDTH + `ysyx_25050141_STORE_WIDTH + `ysyx_25050141_XLEN + `ysyx_25050141_XLEN + 1 + `ysyx_25050141_XLEN + 1
//valE + sel_reg + op_load + op_store + rs2_data + valE_csr + wen_csr + wen_csr_index + need_dstE
// 32 + 1 + 5 + 3 + 32 + 32 + 1 + 32 + 1

`define  ysyx_25050141_ME_TO_DE_WIDTH `ysyx_25050141_XLEN + `ysyx_25050141_XLEN + `ysyx_25050141_XLEN + 1 + 1
//valE_csr + wen_csr + wen_csr_index + valW + need_dstE
