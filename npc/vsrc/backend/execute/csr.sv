// vsrc/backend/execute/csr.sv
import config_pkg::*;
import decode_pkg::*;

module execute_csr #(
    parameter config_pkg::cfg_t Cfg = config_pkg::EmptyCfg,
    parameter TAG_W = 6,
    parameter XLEN = Cfg.XLEN
) (
    input logic clk_i,
    input logic rst_ni,

    input logic             csr_valid_i,
    input decode_pkg::uop_t uop_i,
    input logic [XLEN-1:0]  rs1_data_i,
    input logic [TAG_W-1:0] rob_tag_i,
    input logic             interrupt_inject_i,
    input logic             timer_irq_i,
    input logic [Cfg.PLEN-1:0] trap_pc_i,

    output logic             csr_valid_o,
    output logic [TAG_W-1:0] csr_rob_tag_o,
    output logic [XLEN-1:0]  csr_result_o,
    output logic             csr_exception_o,
    output logic [4:0]       csr_ecause_o,
    output logic             csr_is_mispred_o,
    output logic [Cfg.PLEN-1:0] csr_redirect_pc_o,
    output logic             irq_trap_o,
    output logic [4:0]       irq_trap_cause_o,
    output logic [Cfg.PLEN-1:0] irq_trap_pc_o,
    output logic [Cfg.PLEN-1:0] irq_trap_redirect_pc_o
);

  localparam logic [4:0] EXC_ILLEGAL_INSTR = 5'd2;
  localparam logic [4:0] EXC_BREAKPOINT = 5'd3;
  localparam logic [4:0] EXC_ECALL_UMODE = 5'd8;
  localparam logic [4:0] EXC_ECALL_SMODE = 5'd9;
  localparam logic [4:0] EXC_ECALL_MMODE = 5'd11;
  localparam logic [4:0] EXC_M_TIMER = 5'd7;

  localparam logic [1:0] PRIV_LVL_M = 2'b11;
  localparam logic [1:0] PRIV_LVL_S = 2'b01;
  localparam logic [1:0] PRIV_LVL_U = 2'b00;

  localparam logic [11:0] CSR_SSTATUS = 12'h100;
  localparam logic [11:0] CSR_SIE = 12'h104;
  localparam logic [11:0] CSR_STVEC = 12'h105;
  localparam logic [11:0] CSR_MSTATUS = 12'h300;
  localparam logic [11:0] CSR_MEDELEG = 12'h302;
  localparam logic [11:0] CSR_MIDELEG = 12'h303;
  localparam logic [11:0] CSR_MIE = 12'h304;
  localparam logic [11:0] CSR_MTVEC = 12'h305;
  localparam logic [11:0] CSR_SEPC = 12'h141;
  localparam logic [11:0] CSR_SCAUSE = 12'h142;
  localparam logic [11:0] CSR_STVAL = 12'h143;
  localparam logic [11:0] CSR_SIP = 12'h144;
  localparam logic [11:0] CSR_MEPC = 12'h341;
  localparam logic [11:0] CSR_MCAUSE = 12'h342;
  localparam logic [11:0] CSR_MIP = 12'h344;
  localparam logic [11:0] CSR_SATP = 12'h180;

  localparam int unsigned MSTATUS_SIE_BIT = 1;
  localparam int unsigned MSTATUS_MIE_BIT = 3;
  localparam int unsigned MSTATUS_SPIE_BIT = 5;
  localparam int unsigned MSTATUS_MPIE_BIT = 7;
  localparam int unsigned MSTATUS_SPP_BIT = 8;
  localparam int unsigned MSTATUS_MPP_LSB = 11;
  localparam int unsigned MSTATUS_MPP_MSB = 12;
  localparam int unsigned MIE_MTIE_BIT = 7;
  localparam int unsigned MIP_MTIP_BIT = 7;

  logic [XLEN-1:0] csr_sie;
  logic [XLEN-1:0] csr_stvec;
  logic [XLEN-1:0] csr_sepc;
  logic [XLEN-1:0] csr_scause;
  logic [XLEN-1:0] csr_stval;
  logic [XLEN-1:0] csr_sip;
  logic [XLEN-1:0] csr_mstatus;
  logic [XLEN-1:0] csr_medeleg;
  logic [XLEN-1:0] csr_mideleg;
  logic [XLEN-1:0] csr_mie;
  logic [XLEN-1:0] csr_mtvec;
  logic [XLEN-1:0] csr_mepc;
  logic [XLEN-1:0] csr_mcause;
  logic [XLEN-1:0] csr_satp;
  logic [1:0] current_priv;

  logic [XLEN-1:0] csr_mip;
  logic [XLEN-1:0] csr_sstatus_view;
  logic [XLEN-1:0] csr_sstatus_mask;
  logic [XLEN-1:0] csr_read_val;
  logic [XLEN-1:0] csr_write_val;
  logic [XLEN-1:0] csr_src;
  logic [XLEN-1:0] mstatus_trap_next;
  logic [XLEN-1:0] mstatus_s_trap_next;
  logic [XLEN-1:0] mstatus_mret_next;
  logic [XLEN-1:0] mstatus_sret_next;
  logic csr_write_en;
  logic csr_write_req;
  logic csr_addr_known;
  logic csr_priv_valid;
  logic csr_addr_valid;
  logic sys_op_valid;
  logic sys_exception;
  logic [4:0] sys_ecause;
  logic sys_is_mispred;
  logic [Cfg.PLEN-1:0] sys_redirect_pc;
  logic [1:0] mret_target_priv;
  logic [1:0] sret_target_priv;
  logic csr_illegal_exception;
  logic interrupt_pending;
  logic interrupt_take;
  logic system_take_exception;
  logic trap_take;
  logic trap_to_s_mode;
  logic [4:0] trap_ecause;
  logic [XLEN-1:0] trap_mcause;
  logic [XLEN-1:0] trap_scause;
  logic [Cfg.PLEN-1:0] trap_pc;
  logic [Cfg.PLEN-1:0] trap_redirect_pc;
  logic regular_valid;

  always_comb begin
    csr_mip = '0;
    csr_mip[MIP_MTIP_BIT] = timer_irq_i;
  end

  always_comb begin
    csr_sstatus_mask = '0;
    csr_sstatus_mask[MSTATUS_SIE_BIT] = 1'b1;
    csr_sstatus_mask[MSTATUS_SPIE_BIT] = 1'b1;
    csr_sstatus_mask[MSTATUS_SPP_BIT] = 1'b1;
  end

  assign csr_sstatus_view = csr_mstatus & csr_sstatus_mask;
  assign csr_priv_valid = (current_priv >= uop_i.csr_addr[9:8]);

  // CSR read mux
  always_comb begin
    csr_addr_known = 1'b1;
    unique case (uop_i.csr_addr)
      CSR_SSTATUS: csr_read_val = csr_sstatus_view;
      CSR_SIE: csr_read_val = csr_sie;
      CSR_STVEC: csr_read_val = csr_stvec;
      CSR_MSTATUS: csr_read_val = csr_mstatus;
      CSR_MEDELEG: csr_read_val = csr_medeleg;
      CSR_MIDELEG: csr_read_val = csr_mideleg;
      CSR_MIE: csr_read_val = csr_mie;
      CSR_MTVEC: csr_read_val = csr_mtvec;
      CSR_SEPC: csr_read_val = csr_sepc;
      CSR_SCAUSE: csr_read_val = csr_scause;
      CSR_STVAL: csr_read_val = csr_stval;
      CSR_SIP: csr_read_val = csr_sip;
      CSR_MEPC: csr_read_val = csr_mepc;
      CSR_MCAUSE: csr_read_val = csr_mcause;
      CSR_MIP: csr_read_val = csr_mip;
      CSR_SATP: csr_read_val = csr_satp;
      default: begin
        csr_addr_known = 1'b0;
        csr_read_val = '0;
      end
    endcase
  end

  assign csr_addr_valid = csr_addr_known && csr_priv_valid;

  // CSR source value
  always_comb begin
    unique case (uop_i.csr_op)
      CSR_RWI, CSR_RSI, CSR_RCI: csr_src = uop_i.imm;
      default: csr_src = rs1_data_i;
    endcase
  end

  // CSR write semantics
  always_comb begin
    csr_write_req = 1'b0;
    csr_write_en = 1'b0;
    csr_write_val = csr_read_val;

    unique case (uop_i.csr_op)
      CSR_RW, CSR_RWI: begin
        csr_write_req = 1'b1;
        csr_write_val = csr_src;
      end
      CSR_RS, CSR_RSI: begin
        csr_write_req = 1'b1;
        csr_write_val = csr_read_val | csr_src;
      end
      CSR_RC, CSR_RCI: begin
        csr_write_req = 1'b1;
        csr_write_val = csr_read_val & ~csr_src;
      end
      default: begin
        csr_write_req = 1'b0;
        csr_write_val = csr_read_val;
      end
    endcase

    // RISC-V rule: CSRRS/CSRRC only write when rs1 != x0,
    // CSRRSI/CSRRCI only write when zimm != 0
    unique case (uop_i.csr_op)
      CSR_RS, CSR_RC: begin
        csr_write_en = csr_write_req && (uop_i.rs1 != 0);
      end
      CSR_RSI, CSR_RCI: begin
        csr_write_en = csr_write_req && (uop_i.imm[4:0] != 0);
      end
      CSR_RW, CSR_RWI: begin
        csr_write_en = csr_write_req;
      end
      default: csr_write_en = 1'b0;
    endcase

    csr_write_en = csr_write_en && csr_addr_valid;
  end

  always_comb begin
    sys_op_valid = uop_i.is_ecall | uop_i.is_ebreak | uop_i.is_mret | uop_i.is_sret | uop_i.is_wfi;
    sys_exception = 1'b0;
    sys_ecause = '0;
    sys_is_mispred = 1'b0;
    sys_redirect_pc = '0;
    mret_target_priv = csr_mstatus[MSTATUS_MPP_MSB:MSTATUS_MPP_LSB];
    sret_target_priv = csr_mstatus[MSTATUS_SPP_BIT] ? PRIV_LVL_S : PRIV_LVL_U;

    if (uop_i.is_ecall) begin
      sys_exception = 1'b1;
      unique case (current_priv)
        PRIV_LVL_M: sys_ecause = EXC_ECALL_MMODE;
        PRIV_LVL_S: sys_ecause = EXC_ECALL_SMODE;
        default: sys_ecause = EXC_ECALL_UMODE;
      endcase
    end else if (uop_i.is_ebreak) begin
      // Keep EBREAK as a retire-able stop marker for current bare-metal tests.
      sys_exception = 1'b0;
      sys_ecause = EXC_BREAKPOINT;
      sys_redirect_pc = '0;
    end else if (uop_i.is_mret) begin
      if (current_priv == PRIV_LVL_M) begin
        sys_is_mispred = 1'b1;
        sys_redirect_pc = csr_mepc[Cfg.PLEN-1:0];
      end else begin
        sys_exception = 1'b1;
        sys_ecause = EXC_ILLEGAL_INSTR;
      end
    end else if (uop_i.is_sret) begin
      if (current_priv == PRIV_LVL_S) begin
        sys_is_mispred = 1'b1;
        sys_redirect_pc = csr_sepc[Cfg.PLEN-1:0];
      end else begin
        sys_exception = 1'b1;
        sys_ecause = EXC_ILLEGAL_INSTR;
      end
    end else if (uop_i.is_wfi) begin
      // Treat WFI as a nop-like retire point in current model.
      sys_redirect_pc = '0;
    end
  end

  assign interrupt_pending = timer_irq_i && csr_mstatus[MSTATUS_MIE_BIT] && csr_mie[MIE_MTIE_BIT];
  assign interrupt_take = csr_valid_i && interrupt_inject_i && interrupt_pending;
  assign csr_illegal_exception = csr_valid_i && uop_i.is_csr && !csr_addr_valid;
  assign system_take_exception = csr_valid_i && sys_op_valid && sys_exception;
  assign trap_take = csr_illegal_exception || system_take_exception || interrupt_take;
  assign trap_to_s_mode = (current_priv != PRIV_LVL_M) &&
                          (csr_illegal_exception || system_take_exception) &&
                          csr_medeleg[trap_ecause];

  always_comb begin
    trap_ecause = '0;
    trap_mcause = '0;
    trap_scause = '0;
    trap_pc = trap_pc_i;
    trap_redirect_pc = csr_mtvec[Cfg.PLEN-1:0];

    if (csr_illegal_exception) begin
      trap_ecause = EXC_ILLEGAL_INSTR;
      trap_mcause = XLEN'(EXC_ILLEGAL_INSTR);
      trap_scause = XLEN'(EXC_ILLEGAL_INSTR);
      trap_pc = uop_i.pc;
    end else if (interrupt_take) begin
      trap_ecause = EXC_M_TIMER;
      trap_mcause = XLEN'((32'h1 << (XLEN - 1)) | EXC_M_TIMER);
      trap_scause = XLEN'((32'h1 << (XLEN - 1)) | EXC_M_TIMER);
      trap_pc = trap_pc_i;
    end else if (system_take_exception) begin
      trap_ecause = sys_ecause;
      trap_mcause = XLEN'(sys_ecause);
      trap_scause = XLEN'(sys_ecause);
      trap_pc = uop_i.pc;
    end

    if (trap_to_s_mode) begin
      trap_redirect_pc = csr_stvec[Cfg.PLEN-1:0];
    end
  end

  always_comb begin
    mstatus_trap_next = csr_mstatus;
    mstatus_trap_next[MSTATUS_MPIE_BIT] = csr_mstatus[MSTATUS_MIE_BIT];
    mstatus_trap_next[MSTATUS_MIE_BIT] = 1'b0;
    mstatus_trap_next[MSTATUS_MPP_MSB:MSTATUS_MPP_LSB] = current_priv;

    mstatus_s_trap_next = csr_mstatus;
    mstatus_s_trap_next[MSTATUS_SPIE_BIT] = csr_mstatus[MSTATUS_SIE_BIT];
    mstatus_s_trap_next[MSTATUS_SIE_BIT] = 1'b0;
    mstatus_s_trap_next[MSTATUS_SPP_BIT] = (current_priv == PRIV_LVL_S);

    mstatus_mret_next = csr_mstatus;
    mstatus_mret_next[MSTATUS_MIE_BIT] = csr_mstatus[MSTATUS_MPIE_BIT];
    mstatus_mret_next[MSTATUS_MPIE_BIT] = 1'b1;
    mstatus_mret_next[MSTATUS_MPP_MSB:MSTATUS_MPP_LSB] = PRIV_LVL_U;

    mstatus_sret_next = csr_mstatus;
    mstatus_sret_next[MSTATUS_SIE_BIT] = csr_mstatus[MSTATUS_SPIE_BIT];
    mstatus_sret_next[MSTATUS_SPIE_BIT] = 1'b1;
    mstatus_sret_next[MSTATUS_SPP_BIT] = 1'b0;
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      csr_sie <= '0;
      csr_stvec <= '0;
      csr_sepc <= '0;
      csr_scause <= '0;
      csr_stval <= '0;
      csr_sip <= '0;
      csr_mstatus <= XLEN'(32'h1800);
      csr_medeleg <= '0;
      csr_mideleg <= '0;
      csr_mie <= '0;
      csr_mtvec <= '0;
      csr_mepc <= '0;
      csr_mcause <= '0;
      csr_satp <= '0;
      current_priv <= PRIV_LVL_M;
    end else begin
      if (csr_valid_i && uop_i.is_csr && csr_write_en) begin
        unique case (uop_i.csr_addr)
          CSR_SSTATUS: csr_mstatus <= (csr_mstatus & ~csr_sstatus_mask) | (csr_write_val & csr_sstatus_mask);
          CSR_SIE: csr_sie <= csr_write_val;
          CSR_STVEC: csr_stvec <= csr_write_val;
          CSR_MSTATUS: csr_mstatus <= csr_write_val;
          CSR_MEDELEG: csr_medeleg <= csr_write_val;
          CSR_MIDELEG: csr_mideleg <= csr_write_val;
          CSR_MIE: csr_mie <= csr_write_val;
          CSR_MTVEC: csr_mtvec <= csr_write_val;
          CSR_SEPC: csr_sepc <= csr_write_val;
          CSR_SCAUSE: csr_scause <= csr_write_val;
          CSR_STVAL: csr_stval <= csr_write_val;
          CSR_SIP: csr_sip <= csr_write_val;
          CSR_MEPC: csr_mepc <= csr_write_val;
          CSR_MCAUSE: csr_mcause <= csr_write_val;
          CSR_MIP: ;
          CSR_SATP: csr_satp <= csr_write_val;
          default: ;
        endcase
      end

      if (trap_take) begin
        if (trap_to_s_mode) begin
          csr_sepc <= XLEN'(trap_pc);
          csr_scause <= trap_scause;
          csr_mstatus <= mstatus_s_trap_next;
          current_priv <= PRIV_LVL_S;
        end else begin
          csr_mepc <= XLEN'(trap_pc);
          csr_mcause <= trap_mcause;
          csr_mstatus <= mstatus_trap_next;
          current_priv <= PRIV_LVL_M;
        end
      end else if (csr_valid_i && sys_op_valid && uop_i.is_mret && !sys_exception) begin
        csr_mstatus <= mstatus_mret_next;
        current_priv <= mret_target_priv;
      end else if (csr_valid_i && sys_op_valid && uop_i.is_sret && !sys_exception) begin
        csr_mstatus <= mstatus_sret_next;
        current_priv <= sret_target_priv;
      end
    end
  end

  assign regular_valid = csr_valid_i && (uop_i.is_csr || sys_op_valid);
  assign csr_valid_o = regular_valid;
  assign csr_rob_tag_o = rob_tag_i;
  assign csr_result_o = (csr_valid_i && uop_i.is_csr) ? csr_read_val : '0;
  assign csr_exception_o = trap_take && !interrupt_take;
  assign csr_ecause_o = (trap_take && !interrupt_take) ? trap_ecause : '0;
  assign csr_is_mispred_o = csr_valid_i && sys_op_valid && sys_is_mispred;
  assign csr_redirect_pc_o = (trap_take && !interrupt_take) ? trap_redirect_pc :
                             ((csr_valid_i && sys_op_valid && sys_is_mispred) ?
                             sys_redirect_pc :
                             ((csr_valid_i && sys_op_valid) ? sys_redirect_pc : '0));
  assign irq_trap_o = interrupt_take;
  assign irq_trap_cause_o = interrupt_take ? EXC_M_TIMER : '0;
  assign irq_trap_pc_o = interrupt_take ? trap_pc_i : '0;
  assign irq_trap_redirect_pc_o = interrupt_take ? trap_redirect_pc : '0;

endmodule
