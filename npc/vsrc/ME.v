module ysyx_25050141_ME (
    input clk,
    input [`ysyx_25050141_EX_TO_ME_WIDTH - 1:0] EX_to_ME_bus,
    output [`ysyx_25050141_ME_TO_DE_WIDTH - 1:0] ME_to_DE_bus
);
  wire [`ysyx_25050141_STORE_WIDTH - 1:0] store_op;
  wire [`ysyx_25050141_LOAD_WIDTH - 1:0] load_op;
  wire [`ysyx_25050141_XLEN - 1:0] valE;
  wire [`ysyx_25050141_XLEN - 1:0] valW;
  wire [`ysyx_25050141_XLEN - 1:0] valE_csr;
  wire [`ysyx_25050141_XLEN - 1:0] wen_csr_index;
  wire [`ysyx_25050141_XLEN - 1:0] rs2_data;
  wire sel_reg;
  wire wen_csr;
  wire need_dstE;
  assign {wen_csr_index, wen_csr, valE_csr, need_dstE, valE, sel_reg, load_op, store_op, rs2_data} = EX_to_ME_bus;
  //load OP
  wire load_lb = load_op[`ysyx_25050141_load_lb];
  wire load_lh = load_op[`ysyx_25050141_load_lh];
  wire load_lw = load_op[`ysyx_25050141_load_lw];
  wire load_lbu = load_op[`ysyx_25050141_load_lbu];
  wire load_lhu = load_op[`ysyx_25050141_load_lhu];
  //store
  wire store_sb = store_op[`ysyx_25050141_store_sb];
  wire store_sh = store_op[`ysyx_25050141_store_sh];
  wire store_sw = store_op[`ysyx_25050141_store_sw];
  //load / store
  wire op_load = (load_lb | load_lh | load_lw | load_lbu | load_lhu);
  wire op_store = (store_sb | store_sh | store_sw);

  import "DPI-C" function void dpi_mem_write(
    input int  waddr,
    input int  wdata,
    input byte wmask
  );
  import "DPI-C" function int dpi_mem_read(input int addr);
  wire [7:0] wmask = store_sb ? 8'b00000001 : store_sh ? 8'b00000011 : 8'b00001111;
  reg [`ysyx_25050141_XLEN - 1:0] data;
  wire [`ysyx_25050141_XLEN - 1:0] valM;
  always @(*) begin
    if (op_load | op_store) begin  // 有读写请求时
      data = dpi_mem_read(valE);
      if (op_store) begin  // 有写请求时
        dpi_mem_write(valE, rs2_data, wmask);
      end
    end else begin
      data = 0;
    end
  end
  assign valM =   load_lb ? {{24{data[7]}},data[7:0]} :
					load_lh ? {{16{data[15]}},data[15:0]} :
					load_lw ? data :
					load_lbu ? {{24{1'b0}},data[7:0]} :
					{{16{1'b0}},data[15:0]};
  assign valW = sel_reg ? valE : valM;
  assign ME_to_DE_bus = {wen_csr_index, wen_csr, valE_csr, need_dstE, valW};
endmodule
