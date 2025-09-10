//通用寄存器
module ysyx_25050141_RegisterFile #(
    XLEN  = 32,
    WIDTH = 5,
    DEPTH = 32
) (
    input clk,
    input rst,
    input [WIDTH - 1:0] raddr1,
    input [WIDTH - 1:0] raddr2,
    input [WIDTH - 1:0] waddr,
    input [XLEN - 1:0] wdata,
    input wen,
    output [XLEN - 1:0] rdata1,
    output [XLEN - 1:0] rdata2
);
  import "DPI-C" function void cur_gpu(input logic [31:0] regs[]);  // 32个32位寄存器
  wire [XLEN - 1:0] reg_array[DEPTH - 1:0];
  genvar i;
  for (i = 0; i < DEPTH; i = i + 1) begin : REG_GEN
    // 每个寄存器独立控制写使能
    wire local_wen = (waddr == i) & wen;
    // 实例化基础寄存器模块
    ysyx_25050141_Reg #(
        .WIDTH(XLEN),
        .RESET_VAL(0)  // 寄存器初始化为0
    ) u_reg (
        .clk(clk),
        .rst(rst),
        .din(wdata),
        .dout(reg_array[i]),  // 寄存器输出连接至数组
        .wen((i == 0) ? 1'b0 : local_wen)  // 禁止写入0号寄存器
    );
  end
  // 异步读逻辑
  assign rdata1 = reg_array[raddr1];
  assign rdata2 = reg_array[raddr2];
  always @(*) begin  //和测试环境同步寄存器
    cur_gpu(reg_array);
  end
endmodule
