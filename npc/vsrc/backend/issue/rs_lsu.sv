module reservation_station_lsu #(
    parameter config_pkg::cfg_t Cfg      = config_pkg::EmptyCfg,
    parameter                   RS_DEPTH = Cfg.RS_DEPTH,
    parameter                   DATA_W   = Cfg.XLEN,
    parameter                   RS_IDX_W = $clog2(Cfg.RS_DEPTH),
    parameter                   TAG_W    = 6,
    parameter                   CDB_W    = 4,
    parameter                   SB_W     = 4
) (
    input wire clk,
    input wire rst_n,
    input wire flush_i,

    input wire [ TAG_W-1:0] rob_head_i,

    input wire [RS_DEPTH-1:0] entry_wen,

    input decode_pkg::uop_t              in_op     [0:RS_DEPTH-1],
    input wire              [ TAG_W-1:0] in_dst_tag[0:RS_DEPTH-1],
    input wire              [DATA_W-1:0] in_v1     [0:RS_DEPTH-1],
    input wire              [ TAG_W-1:0] in_q1     [0:RS_DEPTH-1],
    input wire                           in_r1     [0:RS_DEPTH-1],
    input wire              [DATA_W-1:0] in_v2     [0:RS_DEPTH-1],
    input wire              [ TAG_W-1:0] in_q2     [0:RS_DEPTH-1],
    input wire                           in_r2     [0:RS_DEPTH-1],
    input wire              [  SB_W-1:0] in_sb_id  [0:RS_DEPTH-1],

    input wire [ CDB_W-1:0] cdb_valid,
    input wire [ TAG_W-1:0] cdb_tag  [0:CDB_W-1],
    input wire [DATA_W-1:0] cdb_value[0:CDB_W-1],

    // 握手信号
    output logic [RS_DEPTH-1:0] ready_mask,
    input  wire [RS_DEPTH-1:0] issue_grant,

    output wire [RS_DEPTH-1:0] busy_vector,

    // LSU 读取通道
    input  wire  [RS_IDX_W-1:0] sel_idx_0,
    output decode_pkg::uop_t   out_op_0,
    output logic [   TAG_W-1:0] out_dst_tag_0,
    output logic [  DATA_W-1:0] out_v1_0,
    output logic [  DATA_W-1:0] out_v2_0,
    output logic [   SB_W-1:0]  out_sb_id_0
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

  reg               [   SB_W-1:0]  sb_arr [0:RS_DEPTH-1];

  logic             [RS_DEPTH-1:0] busy_d;
  decode_pkg::uop_t                op_arr_d [0:RS_DEPTH-1];
  logic             [   TAG_W-1:0] dst_arr_d[0:RS_DEPTH-1];
  logic             [  DATA_W-1:0] v1_arr_d [0:RS_DEPTH-1];
  logic             [   TAG_W-1:0] q1_arr_d [0:RS_DEPTH-1];
  logic                            r1_arr_d [0:RS_DEPTH-1];
  logic             [  DATA_W-1:0] v2_arr_d [0:RS_DEPTH-1];
  logic             [   TAG_W-1:0] q2_arr_d [0:RS_DEPTH-1];
  logic                            r2_arr_d [0:RS_DEPTH-1];
  logic             [   SB_W-1:0]  sb_arr_d [0:RS_DEPTH-1];

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
    sb_arr_d = sb_arr;

    for (int i = 0; i < RS_DEPTH; i++) begin
      if (issue_grant[i]) begin
        busy_d[i] = 1'b0;
      end else if (entry_wen[i]) begin
        busy_d[i]    = 1'b1;
        op_arr_d[i]  = in_op[i];
        dst_arr_d[i] = in_dst_tag[i];
        sb_arr_d[i]  = in_sb_id[i];

        v1_arr_d[i]  = in_v1[i];
        q1_arr_d[i]  = in_q1[i];
        r1_arr_d[i]  = in_r1[i];
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
      sb_arr <= sb_arr_d;
    end
  end

  function automatic logic [TAG_W-1:0] rob_age(
      input logic [TAG_W-1:0] idx, input logic [TAG_W-1:0] head);
    logic [TAG_W-1:0] diff;
    begin
      diff = idx - head;
      return diff;
    end
  endfunction

  // Load/store ordering: block loads behind older stores.
  always_comb begin
    for (int m = 0; m < RS_DEPTH; m++) begin
      logic block_load;
      block_load = 1'b0;
      if (busy[m] && op_arr[m].is_load) begin
        for (int n = 0; n < RS_DEPTH; n++) begin
          if (busy[n] && op_arr[n].is_store) begin
            if (rob_age(dst_arr[n], rob_head_i) < rob_age(dst_arr[m], rob_head_i)) begin
              block_load = 1'b1;
            end
          end
        end
      end
      ready_mask[m] = busy[m] &&
                      (op_arr[m].has_rs1 ? r1_arr[m] : 1'b1) &&
                      (op_arr[m].has_rs2 ? r2_arr[m] : 1'b1) &&
                      !block_load;
    end
  end

  // Port 0
  assign out_op_0      = op_arr[sel_idx_0];
  assign out_dst_tag_0 = dst_arr[sel_idx_0];
  assign out_v1_0      = v1_arr[sel_idx_0];
  assign out_v2_0      = v2_arr[sel_idx_0];
  assign out_sb_id_0   = sb_arr[sel_idx_0];

  assign busy_vector   = busy;

endmodule
