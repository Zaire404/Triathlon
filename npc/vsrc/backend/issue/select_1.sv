module select_logic_1 #(
    parameter config_pkg::cfg_t Cfg = config_pkg::EmptyCfg,
    parameter RS_DEPTH = Cfg.RS_DEPTH,
    parameter RS_IDX_W = $clog2(RS_DEPTH)
) (
    input  wire [RS_DEPTH-1:0] ready_mask,

    output logic [RS_DEPTH-1:0] issue_grant_mask,

    output logic                        fu_valid,
    output logic [$clog2(RS_DEPTH)-1:0] fu_rs_idx
);

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

  logic [RS_DEPTH-1:0] grant_0;

  always_comb begin
    grant_0 = find_first_one(ready_mask);
    issue_grant_mask = grant_0;
  end

  integer i;
  always_comb begin
    fu_valid  = |grant_0;
    fu_rs_idx = '0;
    for (i = 0; i < RS_DEPTH; i++) begin
      if (grant_0[i]) fu_rs_idx = i[$clog2(RS_DEPTH)-1:0];
    end
  end

endmodule
