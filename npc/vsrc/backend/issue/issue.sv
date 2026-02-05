// vsrc/backend/issue/issue.sv
import decode_pkg::*;
module issue #(
    parameter config_pkg::cfg_t Cfg = config_pkg::EmptyCfg,
    parameter RS_DEPTH = Cfg.RS_DEPTH,
    parameter DATA_W   = Cfg.XLEN,
    parameter TAG_W    = 6,
    parameter CDB_W    = 4
) (
    input wire clk,
    input wire rst_n,
    input wire flush_i,

    input wire                   [       3:0] dispatch_valid,
    input wire decode_pkg::uop_t              dispatch_op   [0:3],
    input wire                   [ TAG_W-1:0] dispatch_dst  [0:3],
    // Src1
    input wire                   [DATA_W-1:0] dispatch_v1   [0:3],
    input wire                   [ TAG_W-1:0] dispatch_q1   [0:3],
    input wire                                dispatch_r1   [0:3],
    // Src2
    input wire                   [DATA_W-1:0] dispatch_v2   [0:3],
    input wire                   [ TAG_W-1:0] dispatch_q2   [0:3],
    input wire                                dispatch_r2   [0:3],

    output wire issue_ready,  // 给流水线前端：RS满了，停！
    output logic [$clog2(RS_DEPTH+1)-1:0] free_count_o,

    // 来自 CDB 的广播 (给 RS 监听用)
    input wire [ CDB_W-1:0] cdb_valid,
    input wire [ TAG_W-1:0] cdb_tag  [0:CDB_W-1],
    input wire [DATA_W-1:0] cdb_val  [0:CDB_W-1],

    // ALU 0 接口
    output wire                           alu0_en,
    output decode_pkg::uop_t              alu0_uop,
    output wire              [DATA_W-1:0] alu0_v1,
    output wire              [DATA_W-1:0] alu0_v2,
    output wire              [ TAG_W-1:0] alu0_dst,

    // ALU 1 接口
    output wire                           alu1_en,
    output decode_pkg::uop_t              alu1_uop,
    output wire              [DATA_W-1:0] alu1_v1,
    output wire              [DATA_W-1:0] alu1_v2,
    output wire              [ TAG_W-1:0] alu1_dst,

    // ALU 2 接口
    output wire                           alu2_en,
    output decode_pkg::uop_t              alu2_uop,
    output wire              [DATA_W-1:0] alu2_v1,
    output wire              [DATA_W-1:0] alu2_v2,
    output wire              [ TAG_W-1:0] alu2_dst,

    // ALU 3 接口
    output wire                           alu3_en,
    output decode_pkg::uop_t              alu3_uop,
    output wire              [DATA_W-1:0] alu3_v1,
    output wire              [DATA_W-1:0] alu3_v2,
    output wire              [ TAG_W-1:0] alu3_dst
);
  wire full_stall;
  assign issue_ready = ~full_stall;
  // A. Allocator <-> RS 之间的控制线
  wire [RS_DEPTH-1:0] rs_busy_wires;  // RS -> Alloc
  wire [RS_DEPTH-1:0] alloc_wen;  // Alloc -> RS (写使能)
  wire [$clog2(RS_DEPTH)-1:0] routing_idx[0:3];  // Alloc -> Crossbar (路由地址)

  // B. RS <-> Select Logic 之间的握手线
  wire [RS_DEPTH-1:0] rs_ready_wires;  // RS -> Select
  wire [RS_DEPTH-1:0] grant_mask_wires;  // Select -> RS (清除Busy)

  // C. Select Logic -> ALU Mux 的选择信号
  wire [$clog2(RS_DEPTH)-1:0] alu0_sel;
  wire [$clog2(RS_DEPTH)-1:0] alu1_sel;
  wire [$clog2(RS_DEPTH)-1:0] alu2_sel;
  wire [$clog2(RS_DEPTH)-1:0] alu3_sel;
  localparam int ISSUE_WIDTH = 4;
  wire [ISSUE_WIDTH-1:0] issue_valid;
  wire [$clog2(RS_DEPTH)-1:0] issue_rs_idx[0:ISSUE_WIDTH-1];

  assign alu0_en  = issue_valid[0];
  assign alu1_en  = issue_valid[1];
  assign alu2_en  = issue_valid[2];
  assign alu3_en  = issue_valid[3];
  assign alu0_sel = issue_rs_idx[0];
  assign alu1_sel = issue_rs_idx[1];
  assign alu2_sel = issue_rs_idx[2];
  assign alu3_sel = issue_rs_idx[3];

  // D. Crossbar <-> RS 输入数据线 (16组宽总线)
  // 这些是在 always_comb 里被驱动的
  decode_pkg::uop_t rs_in_op[0:RS_DEPTH-1];
  logic [TAG_W-1:0] rs_in_dst[0:RS_DEPTH-1];
  logic [DATA_W-1:0] rs_in_v1[0:RS_DEPTH-1];
  logic [TAG_W-1:0] rs_in_q1[0:RS_DEPTH-1];
  logic rs_in_r1[0:RS_DEPTH-1];
  logic [DATA_W-1:0] rs_in_v2[0:RS_DEPTH-1];
  logic [TAG_W-1:0] rs_in_q2[0:RS_DEPTH-1];
  logic rs_in_r2[0:RS_DEPTH-1];

  // ==========================================
  // 模块 1: 分配器 (Allocator)
  // ==========================================
  rs_allocator #(
      .Cfg(Cfg)
  ) u_alloc (
      .rs_busy    (rs_busy_wires),
      .instr_valid(dispatch_valid),
      .entry_wen  (alloc_wen),
      .idx_map    (routing_idx),
      .full_stall (full_stall)
  );

  always_comb begin
    for (int k = 0; k < RS_DEPTH; k++) begin
      rs_in_op[k]  = 0;
      rs_in_dst[k] = 0;
      rs_in_v1[k]  = 0;
      rs_in_q1[k]  = 0;
      rs_in_r1[k]  = 0;
      rs_in_v2[k]  = 0;
      rs_in_q2[k]  = 0;
      rs_in_r2[k]  = 0;
    end

    if (dispatch_valid[0]) begin
      rs_in_op[routing_idx[0]]  = dispatch_op[0];
      rs_in_dst[routing_idx[0]] = dispatch_dst[0];
      rs_in_v1[routing_idx[0]]  = dispatch_v1[0];
      rs_in_q1[routing_idx[0]]  = dispatch_q1[0];
      rs_in_r1[routing_idx[0]]  = dispatch_r1[0];
      rs_in_v2[routing_idx[0]]  = dispatch_v2[0];
      rs_in_q2[routing_idx[0]]  = dispatch_q2[0];
      rs_in_r2[routing_idx[0]]  = dispatch_r2[0];
    end

    // 指令 1
    if (dispatch_valid[1]) begin
      rs_in_op[routing_idx[1]]  = dispatch_op[1];
      rs_in_dst[routing_idx[1]] = dispatch_dst[1];
      rs_in_v1[routing_idx[1]]  = dispatch_v1[1];
      rs_in_q1[routing_idx[1]]  = dispatch_q1[1];
      rs_in_r1[routing_idx[1]]  = dispatch_r1[1];
      rs_in_v2[routing_idx[1]]  = dispatch_v2[1];
      rs_in_q2[routing_idx[1]]  = dispatch_q2[1];
      rs_in_r2[routing_idx[1]]  = dispatch_r2[1];
    end

    if (dispatch_valid[2]) begin
      rs_in_op[routing_idx[2]]  = dispatch_op[2];
      rs_in_dst[routing_idx[2]] = dispatch_dst[2];
      rs_in_v1[routing_idx[2]]  = dispatch_v1[2];
      rs_in_q1[routing_idx[2]]  = dispatch_q1[2];
      rs_in_r1[routing_idx[2]]  = dispatch_r1[2];
      rs_in_v2[routing_idx[2]]  = dispatch_v2[2];
      rs_in_q2[routing_idx[2]]  = dispatch_q2[2];
      rs_in_r2[routing_idx[2]]  = dispatch_r2[2];
    end

    if (dispatch_valid[3]) begin
      rs_in_q1[routing_idx[3]]  = dispatch_q1[3];
      rs_in_r1[routing_idx[3]]  = dispatch_r1[3];
      rs_in_v2[routing_idx[3]]  = dispatch_v2[3];
      rs_in_q2[routing_idx[3]]  = dispatch_q2[3];
      rs_in_r2[routing_idx[3]]  = dispatch_r2[3];
      rs_in_op[routing_idx[3]]  = dispatch_op[3];
      rs_in_dst[routing_idx[3]] = dispatch_dst[3];
      rs_in_v1[routing_idx[3]]  = dispatch_v1[3];
    end
  end

  reservation_station #(
      .Cfg(Cfg),
      .CDB_W(CDB_W)
  ) u_rs (
      .clk(clk),
      .rst_n(rst_n),
      .flush_i(flush_i),
      .head_en_i(1'b0),
      .head_tag_i('0),

      // 写端口 (连接 Crossbar 的结果)
      .entry_wen (alloc_wen),
      .in_op     (rs_in_op),
      .in_dst_tag(rs_in_dst),
      .in_v1     (rs_in_v1),
      .in_q1     (rs_in_q1),
      .in_r1     (rs_in_r1),
      .in_v2     (rs_in_v2),
      .in_q2     (rs_in_q2),
      .in_r2     (rs_in_r2),

      // CDB 监听端口
      .cdb_valid(cdb_valid),
      .cdb_tag  (cdb_tag),
      .cdb_value(cdb_val),

      .busy_vector(rs_busy_wires),

      // 状态输出
      .ready_mask (rs_ready_wires),
      .issue_grant(grant_mask_wires),

      .sel_idx_0    (alu0_sel),
      .out_op_0     (alu0_uop),  // <--- 修改这里
      .out_v1_0     (alu0_v1),
      .out_v2_0     (alu0_v2),
      .out_dst_tag_0(alu0_dst),

      .sel_idx_1    (alu1_sel),
      .out_op_1     (alu1_uop),  // <--- 修改这里
      .out_v1_1     (alu1_v1),
      .out_v2_1     (alu1_v2),
      .out_dst_tag_1(alu1_dst),

      .sel_idx_2    (alu2_sel),
      .out_op_2     (alu2_uop),
      .out_v1_2     (alu2_v1),
      .out_v2_2     (alu2_v2),
      .out_dst_tag_2(alu2_dst),

      .sel_idx_3    (alu3_sel),
      .out_op_3     (alu3_uop),
      .out_v1_3     (alu3_v1),
      .out_v2_3     (alu3_v2),
      .out_dst_tag_3(alu3_dst)
  );

  // ==========================================
  // 模块 3: 选择逻辑 (Issue Select)
  // ==========================================
  issue_select #(
      .Cfg(Cfg),
      .ISSUE_WIDTH(ISSUE_WIDTH)
  ) u_select (
      .ready_mask      (rs_ready_wires),
      .issue_grant_mask(grant_mask_wires),
      .issue_valid     (issue_valid),
      .issue_rs_idx    (issue_rs_idx)
  );

  // Free count for backpressure
  always_comb begin
    free_count_o = '0;
    for (int i = 0; i < RS_DEPTH; i++) begin
      if (!rs_busy_wires[i]) free_count_o++;
    end
  end

endmodule
