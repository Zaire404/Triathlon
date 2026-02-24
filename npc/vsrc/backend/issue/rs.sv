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

    input wire head_en_i,
    input wire [ TAG_W-1:0] head_tag_i,

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
    input wire              comb_wakeup_en,
    input wire [ CDB_W-1:0] cdb_wakeup_mask,

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

  function automatic logic cdb_hit(input logic [TAG_W-1:0] tag);
    logic hit;
    begin
      hit = 1'b0;
      for (int k = 0; k < CDB_W; k++) begin
        if (cdb_wakeup_mask[k] && cdb_valid[k] && (tag == cdb_tag[k])) begin
          hit = 1'b1;
        end
      end
      return hit;
    end
  endfunction

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

  logic             [RS_DEPTH-1:0] busy_d;
  decode_pkg::uop_t                op_arr_d [0:RS_DEPTH-1];
  logic             [   TAG_W-1:0] dst_arr_d[0:RS_DEPTH-1];

  logic             [  DATA_W-1:0] v1_arr_d [0:RS_DEPTH-1];
  logic             [   TAG_W-1:0] q1_arr_d [0:RS_DEPTH-1];
  logic                            r1_arr_d [0:RS_DEPTH-1];

  logic             [  DATA_W-1:0] v2_arr_d [0:RS_DEPTH-1];
  logic             [   TAG_W-1:0] q2_arr_d [0:RS_DEPTH-1];
  logic                            r2_arr_d [0:RS_DEPTH-1];

  // 写入与 CDB 监听逻辑 (保持不变)
  always_comb begin
    busy_d   = busy;
    op_arr_d = op_arr;
    dst_arr_d = dst_arr;
    v1_arr_d = v1_arr;
    q1_arr_d = q1_arr;
    r1_arr_d = r1_arr;
    v2_arr_d = v2_arr;
    q2_arr_d = q2_arr;
    r2_arr_d = r2_arr;

    for (int i = 0; i < RS_DEPTH; i++) begin
      if (issue_grant[i]) begin
        busy_d[i] = 1'b0;
      end else if (entry_wen[i]) begin
        busy_d[i]    = 1'b1;
        op_arr_d[i]  = in_op[i];
        dst_arr_d[i] = in_dst_tag[i];

        v1_arr_d[i]  = in_v1[i];
        q1_arr_d[i]  = in_q1[i];
        r1_arr_d[i]  = in_r1[i];
        // Forwarding Check Src1
        if (!in_r1[i]) begin
          for (int k = 0; k < CDB_W; k++) begin
            if (cdb_valid[k] && (cdb_tag[k] == in_q1[i])) begin
              v1_arr_d[i] = cdb_value[k];
              r1_arr_d[i] = 1'b1;
            end
          end
        end

        v2_arr_d[i] = in_v2[i];
        q2_arr_d[i] = in_q2[i];
        r2_arr_d[i] = in_r2[i];
        // Forwarding Check Src2
        if (!in_r2[i]) begin
          for (int k = 0; k < CDB_W; k++) begin
            if (cdb_valid[k] && (cdb_tag[k] == in_q2[i])) begin
              v2_arr_d[i] = cdb_value[k];
              r2_arr_d[i] = 1'b1;
            end
          end
        end
      end else if (busy[i]) begin
        for (int k = 0; k < CDB_W; k++) begin
          if (cdb_valid[k]) begin
            if (!r1_arr[i] && (q1_arr[i] == cdb_tag[k])) begin
              v1_arr_d[i] = cdb_value[k];
              r1_arr_d[i] = 1'b1;
            end
            if (!r2_arr[i] && (q2_arr[i] == cdb_tag[k])) begin
              v2_arr_d[i] = cdb_value[k];
              r2_arr_d[i] = 1'b1;
            end
          end
        end
      end
    end
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      busy <= {RS_DEPTH{1'b0}};
    end else if (flush_i) begin
      busy <= {RS_DEPTH{1'b0}};
    end else begin
      busy   <= busy_d;
      op_arr <= op_arr_d;
      dst_arr <= dst_arr_d;
      v1_arr <= v1_arr_d;
      q1_arr <= q1_arr_d;
      r1_arr <= r1_arr_d;
      v2_arr <= v2_arr_d;
      q2_arr <= q2_arr_d;
      r2_arr <= r2_arr_d;
    end
  end

  genvar g;
  generate
    for (g = 0; g < RS_DEPTH; g = g + 1) begin : gen_ready
      wire r1_ready = op_arr[g].has_rs1 ? (r1_arr[g] || (comb_wakeup_en && cdb_hit(q1_arr[g]))) : 1'b1;
      wire r2_ready = op_arr[g].has_rs2 ? (r2_arr[g] || (comb_wakeup_en && cdb_hit(q2_arr[g]))) : 1'b1;
      assign ready_mask[g] = busy[g] && r1_ready && r2_ready &&
          (!head_en_i || (dst_arr[g] == head_tag_i));
    end
  endgenerate


  // Port 0 (给 ALU 0)
  assign out_op_0      = op_arr[sel_idx_0];
  assign out_dst_tag_0 = dst_arr[sel_idx_0];
  always_comb begin
    out_v1_0 = v1_arr[sel_idx_0];
    if (comb_wakeup_en && !r1_arr[sel_idx_0]) begin
      for (int k = 0; k < CDB_W; k++) begin
        if (cdb_wakeup_mask[k] && cdb_valid[k] && (q1_arr[sel_idx_0] == cdb_tag[k])) out_v1_0 = cdb_value[k];
      end
    end
  end
  always_comb begin
    out_v2_0 = v2_arr[sel_idx_0];
    if (comb_wakeup_en && !r2_arr[sel_idx_0]) begin
      for (int k = 0; k < CDB_W; k++) begin
        if (cdb_wakeup_mask[k] && cdb_valid[k] && (q2_arr[sel_idx_0] == cdb_tag[k])) out_v2_0 = cdb_value[k];
      end
    end
  end

  // Port 1 (给 ALU 1)
  assign out_op_1      = op_arr[sel_idx_1];
  assign out_dst_tag_1 = dst_arr[sel_idx_1];
  always_comb begin
    out_v1_1 = v1_arr[sel_idx_1];
    if (comb_wakeup_en && !r1_arr[sel_idx_1]) begin
      for (int k = 0; k < CDB_W; k++) begin
        if (cdb_wakeup_mask[k] && cdb_valid[k] && (q1_arr[sel_idx_1] == cdb_tag[k])) out_v1_1 = cdb_value[k];
      end
    end
  end
  always_comb begin
    out_v2_1 = v2_arr[sel_idx_1];
    if (comb_wakeup_en && !r2_arr[sel_idx_1]) begin
      for (int k = 0; k < CDB_W; k++) begin
        if (cdb_wakeup_mask[k] && cdb_valid[k] && (q2_arr[sel_idx_1] == cdb_tag[k])) out_v2_1 = cdb_value[k];
      end
    end
  end

  // Port 2 (给 ALU 2)
  assign out_op_2      = op_arr[sel_idx_2];
  assign out_dst_tag_2 = dst_arr[sel_idx_2];
  always_comb begin
    out_v1_2 = v1_arr[sel_idx_2];
    if (comb_wakeup_en && !r1_arr[sel_idx_2]) begin
      for (int k = 0; k < CDB_W; k++) begin
        if (cdb_wakeup_mask[k] && cdb_valid[k] && (q1_arr[sel_idx_2] == cdb_tag[k])) out_v1_2 = cdb_value[k];
      end
    end
  end
  always_comb begin
    out_v2_2 = v2_arr[sel_idx_2];
    if (comb_wakeup_en && !r2_arr[sel_idx_2]) begin
      for (int k = 0; k < CDB_W; k++) begin
        if (cdb_wakeup_mask[k] && cdb_valid[k] && (q2_arr[sel_idx_2] == cdb_tag[k])) out_v2_2 = cdb_value[k];
      end
    end
  end

  // Port 3 (给 ALU 3)
  assign out_op_3      = op_arr[sel_idx_3];
  assign out_dst_tag_3 = dst_arr[sel_idx_3];
  always_comb begin
    out_v1_3 = v1_arr[sel_idx_3];
    if (comb_wakeup_en && !r1_arr[sel_idx_3]) begin
      for (int k = 0; k < CDB_W; k++) begin
        if (cdb_wakeup_mask[k] && cdb_valid[k] && (q1_arr[sel_idx_3] == cdb_tag[k])) out_v1_3 = cdb_value[k];
      end
    end
  end
  always_comb begin
    out_v2_3 = v2_arr[sel_idx_3];
    if (comb_wakeup_en && !r2_arr[sel_idx_3]) begin
      for (int k = 0; k < CDB_W; k++) begin
        if (cdb_wakeup_mask[k] && cdb_valid[k] && (q2_arr[sel_idx_3] == cdb_tag[k])) out_v2_3 = cdb_value[k];
      end
    end
  end

  assign busy_vector   = busy;

endmodule
