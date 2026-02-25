module sv32_mmu (
    input  logic        clk_i,
    input  logic        rst_ni,

    input  logic        req_valid_i,
    input  logic [31:0] req_vaddr_i,
    input  logic [1:0]  req_access_i,  // 0:instr 1:load 2:store
    input  logic [31:0] satp_i,

    output logic        req_ready_o,
    output logic        resp_valid_o,
    output logic [31:0] resp_paddr_o,
    output logic        resp_page_fault_o,

    output logic        pte_req_valid_o,
    input  logic        pte_req_ready_i,
    output logic [31:0] pte_req_paddr_o,
    input  logic        pte_rsp_valid_i,
    input  logic [31:0] pte_rsp_data_i
);

  localparam logic [1:0] ACCESS_INSTR = 2'd0;
  localparam logic [1:0] ACCESS_LOAD  = 2'd1;
  localparam logic [1:0] ACCESS_STORE = 2'd2;

  typedef enum logic [1:0] {
    ST_IDLE = 2'd0,
    ST_WALK_L1 = 2'd1,
    ST_WALK_L0 = 2'd2
  } walk_state_e;

  walk_state_e state_q;

  logic [31:0] req_vaddr_q;
  logic [1:0]  req_access_q;
  logic [21:0] root_ppn_q;
  logic [21:0] next_ppn_q;

  logic        resp_valid_q;
  logic [31:0] resp_paddr_q;
  logic        resp_page_fault_q;

  logic [31:0] l1_pte_addr_w;
  logic [31:0] l0_pte_addr_w;

  function automatic logic pte_invalid(input logic [31:0] pte);
    pte_invalid = (!pte[0]) || (pte[2] && !pte[1]);
  endfunction

  function automatic logic pte_is_leaf(input logic [31:0] pte);
    pte_is_leaf = pte[1] || pte[3];
  endfunction

  function automatic logic pte_perm_ok(input logic [31:0] pte, input logic [1:0] access);
    logic r_bit;
    logic w_bit;
    logic x_bit;
    logic a_bit;
    logic d_bit;
    begin
      r_bit = pte[1];
      w_bit = pte[2];
      x_bit = pte[3];
      a_bit = pte[6];
      d_bit = pte[7];
      unique case (access)
        ACCESS_INSTR: pte_perm_ok = x_bit && a_bit;
        ACCESS_LOAD:  pte_perm_ok = r_bit && a_bit;
        ACCESS_STORE: pte_perm_ok = r_bit && w_bit && a_bit && d_bit;
        default:      pte_perm_ok = 1'b0;
      endcase
    end
  endfunction

  assign l1_pte_addr_w = {root_ppn_q, 12'b0} + {20'b0, req_vaddr_q[31:22], 2'b00};
  assign l0_pte_addr_w = {next_ppn_q, 12'b0} + {20'b0, req_vaddr_q[21:12], 2'b00};

  assign req_ready_o = (state_q == ST_IDLE);
  assign pte_req_valid_o = (state_q == ST_WALK_L1) || (state_q == ST_WALK_L0);
  assign pte_req_paddr_o = (state_q == ST_WALK_L0) ? l0_pte_addr_w : l1_pte_addr_w;

  assign resp_valid_o = resp_valid_q;
  assign resp_paddr_o = resp_paddr_q;
  assign resp_page_fault_o = resp_page_fault_q;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    logic [31:0] pte;

    if (!rst_ni) begin
      state_q <= ST_IDLE;
      req_vaddr_q <= '0;
      req_access_q <= '0;
      root_ppn_q <= '0;
      next_ppn_q <= '0;
      resp_valid_q <= 1'b0;
      resp_paddr_q <= '0;
      resp_page_fault_q <= 1'b0;
    end else begin
      pte = pte_rsp_data_i;

      if ((state_q == ST_IDLE) && req_valid_i) begin
        req_vaddr_q <= req_vaddr_i;
        req_access_q <= req_access_i;
        root_ppn_q <= satp_i[21:0];

        if (satp_i[31]) begin
          state_q <= ST_WALK_L1;
        end else begin
          state_q <= ST_IDLE;
          resp_valid_q <= 1'b1;
          resp_page_fault_q <= 1'b0;
          resp_paddr_q <= req_vaddr_i;
        end
      end else begin
        unique case (state_q)
          ST_WALK_L1: begin
            if (pte_rsp_valid_i && pte_req_ready_i) begin
              if (pte_invalid(pte)) begin
                state_q <= ST_IDLE;
                resp_valid_q <= 1'b1;
                resp_page_fault_q <= 1'b1;
                resp_paddr_q <= '0;
              end else if (pte_is_leaf(pte)) begin
                if ((pte[19:10] != 10'b0) || !pte_perm_ok(pte, req_access_q)) begin
                  state_q <= ST_IDLE;
                  resp_valid_q <= 1'b1;
                  resp_page_fault_q <= 1'b1;
                  resp_paddr_q <= '0;
                end else begin
                  state_q <= ST_IDLE;
                  resp_valid_q <= 1'b1;
                  resp_page_fault_q <= 1'b0;
                  resp_paddr_q <= {pte[31:20], req_vaddr_q[21:0]};
                end
              end else begin
                next_ppn_q <= pte[31:10];
                state_q <= ST_WALK_L0;
              end
            end
          end
          ST_WALK_L0: begin
            if (pte_rsp_valid_i && pte_req_ready_i) begin
              if (pte_invalid(pte) || !pte_is_leaf(pte) || !pte_perm_ok(pte, req_access_q)) begin
                state_q <= ST_IDLE;
                resp_valid_q <= 1'b1;
                resp_page_fault_q <= 1'b1;
                resp_paddr_q <= '0;
              end else begin
                state_q <= ST_IDLE;
                resp_valid_q <= 1'b1;
                resp_page_fault_q <= 1'b0;
                resp_paddr_q <= {pte[31:10], req_vaddr_q[11:0]};
              end
            end
          end
          default: begin
            state_q <= ST_IDLE;
          end
        endcase
      end

    end
  end

endmodule
