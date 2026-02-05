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

    input logic            csr_valid_i,
    input decode_pkg::uop_t uop_i,
    input logic [XLEN-1:0] rs1_data_i,
    input logic [TAG_W-1:0] rob_tag_i,

    output logic            csr_valid_o,
    output logic [TAG_W-1:0] csr_rob_tag_o,
    output logic [XLEN-1:0] csr_result_o
);

  localparam logic [11:0] CSR_MSTATUS = 12'h300;
  localparam logic [11:0] CSR_MTVEC   = 12'h305;
  localparam logic [11:0] CSR_MEPC    = 12'h341;
  localparam logic [11:0] CSR_MCAUSE  = 12'h342;
  localparam logic [11:0] CSR_SATP    = 12'h180;

  logic [XLEN-1:0] csr_mstatus;
  logic [XLEN-1:0] csr_mtvec;
  logic [XLEN-1:0] csr_mepc;
  logic [XLEN-1:0] csr_mcause;
  logic [XLEN-1:0] csr_satp;

  logic [XLEN-1:0] csr_read_val;
  logic [XLEN-1:0] csr_write_val;
  logic [XLEN-1:0] csr_src;
  logic csr_write_en;
  logic csr_addr_valid;

  // CSR read mux
  always_comb begin
    csr_addr_valid = 1'b1;
    unique case (uop_i.csr_addr)
      CSR_MSTATUS: csr_read_val = csr_mstatus;
      CSR_MTVEC:   csr_read_val = csr_mtvec;
      CSR_MEPC:    csr_read_val = csr_mepc;
      CSR_MCAUSE:  csr_read_val = csr_mcause;
      CSR_SATP:    csr_read_val = csr_satp;
      default: begin
        csr_addr_valid = 1'b0;
        csr_read_val   = '0;
      end
    endcase
  end

  // CSR source value
  always_comb begin
    csr_src = rs1_data_i;
    unique case (uop_i.csr_op)
      CSR_RWI, CSR_RSI, CSR_RCI: begin
        csr_src = {{(XLEN-5){1'b0}}, uop_i.imm[4:0]};
      end
      default: csr_src = rs1_data_i;
    endcase
  end

  // CSR write semantics
  always_comb begin
    csr_write_en  = 1'b0;
    csr_write_val = csr_read_val;

    unique case (uop_i.csr_op)
      CSR_RW, CSR_RWI: begin
        csr_write_en  = 1'b1;
        csr_write_val = csr_src;
      end
      CSR_RS, CSR_RSI: begin
        if (csr_src != '0) begin
          csr_write_en = 1'b1;
        end
        csr_write_val = csr_read_val | csr_src;
      end
      CSR_RC, CSR_RCI: begin
        if (csr_src != '0) begin
          csr_write_en = 1'b1;
        end
        csr_write_val = csr_read_val & ~csr_src;
      end
      default: begin
        csr_write_en  = 1'b0;
        csr_write_val = csr_read_val;
      end
    endcase

    csr_write_en = csr_write_en && csr_addr_valid;
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      csr_mstatus <= XLEN'(32'h1800);
      csr_mtvec   <= '0;
      csr_mepc    <= '0;
      csr_mcause  <= '0;
      csr_satp    <= '0;
    end else if (csr_valid_i && uop_i.is_csr && csr_write_en) begin
      unique case (uop_i.csr_addr)
        CSR_MSTATUS: csr_mstatus <= csr_write_val;
        CSR_MTVEC:   csr_mtvec   <= csr_write_val;
        CSR_MEPC:    csr_mepc    <= csr_write_val;
        CSR_MCAUSE:  csr_mcause  <= csr_write_val;
        CSR_SATP:    csr_satp    <= csr_write_val;
        default: ;
      endcase
    end
  end

  assign csr_valid_o   = csr_valid_i && uop_i.is_csr;
  assign csr_rob_tag_o = rob_tag_i;
  assign csr_result_o  = csr_read_val;

endmodule
