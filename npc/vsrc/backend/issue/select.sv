module select_logic #(
    parameter config_pkg::cfg_t Cfg = config_pkg::EmptyCfg,
    parameter RS_DEPTH = Cfg.RS_DEPTH,
    parameter ALU_COUNT = Cfg.ALU_COUNT,
    parameter RS_IDX_W = $clog2(RS_DEPTH)
) (
    input wire [RS_DEPTH-1:0] ready_mask,

    output logic [RS_DEPTH-1:0] issue_grant_mask,

    output logic                        alu0_valid,
    output logic [$clog2(RS_DEPTH)-1:0] alu0_rs_idx,

    output logic                        alu1_valid,
    output logic [$clog2(RS_DEPTH)-1:0] alu1_rs_idx
);

  logic [RS_DEPTH-1:0] mask_stage_0;
  logic [RS_DEPTH-1:0] mask_stage_1;

  logic [RS_DEPTH-1:0] grant_0;
  logic [RS_DEPTH-1:0] grant_1;

  function [RS_DEPTH-1:0] find_first_one;
    input [RS_DEPTH-1:0] in_vec;
    integer k;
    reg found;
    begin
      find_first_one = 0;
      found = 0;
      for (k = 0; k < RS_DEPTH; k = k + 1) begin
        if (in_vec[k] && !found) begin
          find_first_one[k] = 1'b1;
          found = 1'b1;
        end
      end
    end
  endfunction


  always_comb begin
    mask_stage_0     = ready_mask;
    grant_0          = find_first_one(mask_stage_0);

    mask_stage_1     = mask_stage_0 & (~grant_0);
    grant_1          = find_first_one(mask_stage_1);

    issue_grant_mask = grant_0 | grant_1;
  end

  integer i;

  always_comb begin
    alu0_valid  = |grant_0;
    alu0_rs_idx = 0;
    for (i = 0; i < RS_DEPTH; i++) begin
      if (grant_0[i]) alu0_rs_idx = i[$clog2(RS_DEPTH)-1:0];
    end

    alu1_valid  = |grant_1;
    alu1_rs_idx = 0;
    for (i = 0; i < RS_DEPTH; i++) begin
      if (grant_1[i]) alu1_rs_idx = i[$clog2(RS_DEPTH)-1:0];
    end
  end

endmodule
