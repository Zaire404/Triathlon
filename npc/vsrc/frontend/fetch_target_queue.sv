// vsrc/frontend/fetch_target_queue.sv
module fetch_target_queue #(
    parameter config_pkg::cfg_t Cfg = config_pkg::EmptyCfg
) (
    input  logic clk,
    input  logic rst,
    input  logic flush_i,

    input  logic                 push_valid,
    output logic                 push_ready,
    input  logic [Cfg.PLEN-1:0]  push_pc,

    output logic                 issue_valid,
    input  logic                 issue_ready,
    output logic [Cfg.PLEN-1:0]  issue_pc,

    input  logic                 complete_fire,
    output logic [Cfg.PLEN-1:0]  head_pc,
    output logic                 head_valid,
    output logic                 pending_issued_o
);

  localparam int unsigned DEPTH = (Cfg.FTQ_DEPTH > 1) ? Cfg.FTQ_DEPTH : 2;
  localparam int unsigned PTR_W = (DEPTH > 1) ? $clog2(DEPTH) : 1;

  logic [DEPTH-1:0]             valid_q;
  logic [DEPTH-1:0]             issued_q;
  logic [DEPTH-1:0][Cfg.PLEN-1:0] pc_q;
  logic [PTR_W-1:0]             head_ptr_q;
  logic [PTR_W-1:0]             tail_ptr_q;
  logic [PTR_W:0]               count_q;

  logic [PTR_W-1:0] next_head_ptr;
  logic [PTR_W-1:0] next_tail_ptr;

  assign head_pc = pc_q[head_ptr_q];
  assign head_valid = valid_q[head_ptr_q];

  // Find earliest valid but not issued entry (simple scan from head)
  logic issue_found;
  logic [PTR_W-1:0] issue_idx;
  always_comb begin
    issue_found = 1'b0;
    issue_idx = head_ptr_q;
    for (int i = 0; i < DEPTH; i++) begin
      int idx;
      idx = head_ptr_q + i;
      if (idx >= DEPTH) begin
        idx = idx - DEPTH;
      end
      if (!issue_found && valid_q[idx] && !issued_q[idx]) begin
        issue_found = 1'b1;
        issue_idx = idx[PTR_W-1:0];
      end
    end
  end

  assign issue_valid = issue_found;
  assign issue_pc = pc_q[issue_idx];

  logic pop_fire;
  logic push_fire;

  assign pop_fire = complete_fire && valid_q[head_ptr_q];
  assign push_ready = (count_q < DEPTH) || pop_fire;
  assign push_fire = push_valid && push_ready;

  always_comb begin
    next_head_ptr = head_ptr_q + {{(PTR_W - 1) {1'b0}}, 1'b1};
    next_tail_ptr = tail_ptr_q + {{(PTR_W - 1) {1'b0}}, 1'b1};
  end

  always_ff @(posedge clk) begin
    if (rst) begin
      valid_q <= '0;
      issued_q <= '0;
      pc_q <= '0;
      head_ptr_q <= '0;
      tail_ptr_q <= '0;
      count_q <= '0;
    end else if (flush_i) begin
      valid_q <= '0;
      issued_q <= '0;
      head_ptr_q <= '0;
      tail_ptr_q <= '0;
      count_q <= '0;
    end else begin
      // Complete / pop (always head)
      if (pop_fire) begin
        valid_q[head_ptr_q] <= 1'b0;
        issued_q[head_ptr_q] <= 1'b0;
        head_ptr_q <= next_head_ptr;
      end

      // Issue mark
      if (issue_valid && issue_ready) begin
        issued_q[issue_idx] <= 1'b1;
      end

      // Push
      if (push_fire) begin
        valid_q[tail_ptr_q] <= 1'b1;
        issued_q[tail_ptr_q] <= 1'b0;
        pc_q[tail_ptr_q] <= push_pc;
        tail_ptr_q <= next_tail_ptr;
      end

      unique case ({push_fire, pop_fire})
        2'b10: count_q <= count_q + 1'b1;
        2'b01: count_q <= count_q - 1'b1;
        default: count_q <= count_q;
      endcase
    end
  end

  always_comb begin
    pending_issued_o = 1'b0;
    for (int i = 0; i < DEPTH; i++) begin
      if (valid_q[i] && issued_q[i]) begin
        pending_issued_o = 1'b1;
      end
    end
  end

endmodule : fetch_target_queue
