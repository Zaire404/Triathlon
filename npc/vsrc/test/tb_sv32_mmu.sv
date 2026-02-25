module tb_sv32_mmu (
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

  // NOTE: Task 7 RED stage.
  // This module intentionally instantiates the not-yet-implemented MMU block.
  // The first RED run should fail here until Sv32 MMU is implemented.
  sv32_mmu u_mmu (
      .clk_i            (clk_i),
      .rst_ni           (rst_ni),
      .req_valid_i      (req_valid_i),
      .req_vaddr_i      (req_vaddr_i),
      .req_access_i     (req_access_i),
      .satp_i           (satp_i),
      .req_ready_o      (req_ready_o),
      .resp_valid_o     (resp_valid_o),
      .resp_paddr_o     (resp_paddr_o),
      .resp_page_fault_o(resp_page_fault_o),
      .pte_req_valid_o  (pte_req_valid_o),
      .pte_req_ready_i  (pte_req_ready_i),
      .pte_req_paddr_o  (pte_req_paddr_o),
      .pte_rsp_valid_i  (pte_rsp_valid_i),
      .pte_rsp_data_i   (pte_rsp_data_i)
  );

endmodule
