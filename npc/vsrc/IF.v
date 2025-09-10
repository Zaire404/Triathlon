module ysyx_25050141_IF (
    input clk,
    input rst,
    input [`ysyx_25050141_EX_TO_IF_WIDTH - 1:0] EX_to_IF_bus,
    output [`ysyx_25050141_IF_TO_DE_WIDTH - 1:0] IF_to_DE_bus
);
  import "DPI-C" function void ebreak();
  import "DPI-C" function int fetch_instr(input int pc);
  import "DPI-C" function void cur_pc(input int pc);
  wire [`ysyx_25050141_PC_WIDTH - 1:0] pc;
  wire [`ysyx_25050141_PC_WIDTH - 1:0] npc;
  wire [`ysyx_25050141_INSTR_WIDTH - 1:0] instr;
  ysyx_25050141_Reg #(`ysyx_25050141_XLEN, `ysyx_25050141_pc) PC (  //实例化寄存器PC
      .clk (clk),
      .rst (rst),
      .din (npc),
      .dout(pc),
      .wen (1'b1)
  );
  assign instr = fetch_instr(pc);
  assign IF_to_DE_bus = {pc, instr};
  assign {npc} = EX_to_IF_bus;
  always @(posedge clk) begin  //ebreak指令实现
    if (instr == 32'h100073) ebreak();
  end
  always @(pc) begin  //和测试环境同步pc
    cur_pc(pc);
  end
endmodule
