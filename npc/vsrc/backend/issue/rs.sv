module reservation_station #(
    parameter config_pkg::cfg_t Cfg      = config_pkg::EmptyCfg,
    parameter                   RS_DEPTH = Cfg.RS_DEPTH,
    parameter                   DATA_W   = Cfg.ILEN,
    parameter                   RS_IDX_W = $clog2(Cfg.RS_DEPTH),
    parameter                   TAG_W    = 6,
    parameter                   CDB_W    = 4
) (
    input wire clk,
    input wire rst_n,
    input wire flush_i,

    input wire [RS_DEPTH-1:0] entry_wen,

    input decode_pkg::uop_t              in_op     [0:RS_DEPTH-1],
    input wire              [ TAG_W-1:0] in_dst_tag[0:RS_DEPTH-1],
    input wire              [DATA_W-1:0] in_v1     [0:RS_DEPTH-1],
    input wire              [ TAG_W-1:0] in_q1     [0:RS_DEPTH-1],
    input wire                           in_r1     [0:RS_DEPTH-1],
    input wire              [DATA_W-1:0] in_v2     [0:RS_DEPTH-1],
    input wire              [ TAG_W-1:0] in_q2     [0:RS_DEPTH-1],
    input wire                           in_r2     [0:RS_DEPTH-1],

    input wire [ CDB_W-1:0] cdb_valid,
    input wire [ TAG_W-1:0] cdb_tag  [0:CDB_W-1],
    input wire [DATA_W-1:0] cdb_value[0:CDB_W-1],

    // 握手信号
    output wire [RS_DEPTH-1:0] ready_mask,
    input  wire [RS_DEPTH-1:0] issue_grant,

    output wire [RS_DEPTH-1:0] busy_vector,

    // ALU 0 读取通道
    input  wire  [RS_IDX_W-1:0] sel_idx_0,      // 新增：输入索引
    output decode_pkg::uop_t   out_op_0,
    output logic [   TAG_W-1:0] out_dst_tag_0,
    output logic [  DATA_W-1:0] out_v1_0,
    output logic [  DATA_W-1:0] out_v2_0,

    // ALU 1 读取通道
    input  wire  [RS_IDX_W-1:0] sel_idx_1,      // 新增：输入索引
    output decode_pkg::uop_t   out_op_1,
    output logic [   TAG_W-1:0] out_dst_tag_1,
    output logic [  DATA_W-1:0] out_v1_1,
    output logic [  DATA_W-1:0] out_v2_1,

    // ALU 2 读取通道
    input  wire  [RS_IDX_W-1:0] sel_idx_2,
    output decode_pkg::uop_t   out_op_2,
    output logic [   TAG_W-1:0] out_dst_tag_2,
    output logic [  DATA_W-1:0] out_v1_2,
    output logic [  DATA_W-1:0] out_v2_2,

    // ALU 3 读取通道
    input  wire  [RS_IDX_W-1:0] sel_idx_3,
    output decode_pkg::uop_t   out_op_3,
    output logic [   TAG_W-1:0] out_dst_tag_3,
    output logic [  DATA_W-1:0] out_v1_3,
    output logic [  DATA_W-1:0] out_v2_3
);

  // RS 存储阵列
  reg               [RS_DEPTH-1:0] busy;
  decode_pkg::uop_t                op_arr [0:RS_DEPTH-1];
  reg               [   TAG_W-1:0] dst_arr[0:RS_DEPTH-1];

  reg               [  DATA_W-1:0] v1_arr [0:RS_DEPTH-1];
  reg               [   TAG_W-1:0] q1_arr [0:RS_DEPTH-1];
  reg                              r1_arr [0:RS_DEPTH-1];

  reg               [  DATA_W-1:0] v2_arr [0:RS_DEPTH-1];
  reg               [   TAG_W-1:0] q2_arr [0:RS_DEPTH-1];
  reg                              r2_arr [0:RS_DEPTH-1];

  integer i, k;

  // 写入与 CDB 监听逻辑 (保持不变)
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      busy <= {RS_DEPTH{1'b0}};
    end else if (flush_i) begin
      busy <= {RS_DEPTH{1'b0}};
    end else begin
      for (i = 0; i < RS_DEPTH; i = i + 1) begin
        if (issue_grant[i]) begin
          busy[i] <= 1'b0;
        end  // 写逻辑 (保持原样...)
        else if (entry_wen[i]) begin
          busy[i]    <= 1'b1;
          op_arr[i]  <= in_op[i];
          dst_arr[i] <= in_dst_tag[i];

          v1_arr[i]  <= in_v1[i];
          q1_arr[i]  <= in_q1[i];
          r1_arr[i]  <= in_r1[i];
          // Forwarding Check Src1
          if (!in_r1[i]) begin
            for (k = 0; k < CDB_W; k = k + 1) begin
              if (cdb_valid[k] && (cdb_tag[k] == in_q1[i])) begin
                v1_arr[i] <= cdb_value[k];
                r1_arr[i] <= 1'b1;
              end
            end
          end

          v2_arr[i] <= in_v2[i];
          q2_arr[i] <= in_q2[i];
          r2_arr[i] <= in_r2[i];
          // Forwarding Check Src2
          if (!in_r2[i]) begin
            for (k = 0; k < CDB_W; k = k + 1) begin
              if (cdb_valid[k] && (cdb_tag[k] == in_q2[i])) begin
                v2_arr[i] <= cdb_value[k];
                r2_arr[i] <= 1'b1;
              end
            end
          end
        end  // 监听逻辑
        else if (busy[i]) begin
          for (k = 0; k < CDB_W; k = k + 1) begin
            if (cdb_valid[k]) begin
              if (!r1_arr[i] && (q1_arr[i] == cdb_tag[k])) begin
                v1_arr[i] <= cdb_value[k];
                r1_arr[i] <= 1'b1;
              end
              if (!r2_arr[i] && (q2_arr[i] == cdb_tag[k])) begin
                v2_arr[i] <= cdb_value[k];
                r2_arr[i] <= 1'b1;
              end
            end
          end
        end
      end
    end
  end

  genvar g;
  generate
    for (g = 0; g < RS_DEPTH; g = g + 1) begin : gen_ready
      assign ready_mask[g] = busy[g] && r1_arr[g] && r2_arr[g];
    end
  endgenerate


  // Port 0 (给 ALU 0)
  assign out_op_0      = op_arr[sel_idx_0];
  assign out_dst_tag_0 = dst_arr[sel_idx_0];
  assign out_v1_0      = v1_arr[sel_idx_0];
  assign out_v2_0      = v2_arr[sel_idx_0];

  // Port 1 (给 ALU 1)
  assign out_op_1      = op_arr[sel_idx_1];
  assign out_dst_tag_1 = dst_arr[sel_idx_1];
  assign out_v1_1      = v1_arr[sel_idx_1];
  assign out_v2_1      = v2_arr[sel_idx_1];

  // Port 2 (给 ALU 2)
  assign out_op_2      = op_arr[sel_idx_2];
  assign out_dst_tag_2 = dst_arr[sel_idx_2];
  assign out_v1_2      = v1_arr[sel_idx_2];
  assign out_v2_2      = v2_arr[sel_idx_2];

  // Port 3 (给 ALU 3)
  assign out_op_3      = op_arr[sel_idx_3];
  assign out_dst_tag_3 = dst_arr[sel_idx_3];
  assign out_v1_3      = v1_arr[sel_idx_3];
  assign out_v2_3      = v2_arr[sel_idx_3];

  assign busy_vector   = busy;

endmodule
