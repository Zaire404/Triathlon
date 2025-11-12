// 包含共享的类型和参数定义
// 确保这个路径对于你的Makefile是正确的
import ifu_pkg::*;

module tb_ifu (
    // 1. 公共信号 (由 C++ 控制)
    input  logic clk,
    input  logic rst,

    // 2. IFU 的所有输入端口 (由 C++ 驱动)
    input  logic                          from_bpu_f1_flush,
    input  logic                          ftq_req_cross_cacheline,
    input  logic                          icache_resp_ready,
    input  logic                          ftq_req_valid,
    input  logic [ifu_pkg::VAddrBits-1:0] ftq_req_start_addr,
    input  logic [ifu_pkg::FTQ_IDX_WIDTH-1:0] ftq_req_ftqIdx_i,
    input  logic                          ftq_predicted_taken_i,
    input  logic [$clog2(ifu_pkg::PredictWidth)-1:0] ftq_predicted_idx_i,
    input  logic [ifu_pkg::VAddrBits-1:0] ftq_predicted_target_i,
    input  logic                          ftq_flush_from_bpu,
    input  logic                          backend_redirect,

    input  logic                          icache_resp_valid,
    input  logic [ifu_pkg::DATA_WIDTH-1:0]  icache_data,
    input  logic                          is_mmio_from_icache_resp,

    input  logic                          ibuffer_ready,
    input  ifu_pkg::RobCommitInfo_t         rob_commits [0:ifu_pkg::CommitWidth-1],

    // 3. IFU 的所有输出端口 (由 C++ 监控)
    output logic                          icache_req_double_line,
    output logic                          ftq_req_ready,
    output logic                          icache_req_valid,
    output logic [ifu_pkg::VAddrBits-1:0] icache_req_addr, // 假设位宽与VAddrBits相同
    output logic                          icache_resp_ready_o,
    output logic                          to_ibuffer_valid,
    output logic [ifu_pkg::PredictWidth-1:0] to_ibuffer_enqEnable,
    output logic [ifu_pkg::VAddrBits-1:0]  to_ibuffer_pc [0:ifu_pkg::PredictWidth-1],
    output logic [ifu_pkg::INST_BITS-1:0]  to_ibuffer_instr [0:ifu_pkg::PredictWidth-1],
    output ifu_pkg::PreDecodeInfo_t        to_ibuffer_pd [0:ifu_pkg::PredictWidth-1],
    output ifu_pkg::IfuWbInfo_t            ifu_wb_info_o
);

    // 4. 实例化待测单元 (DUT)
    // 确保你的 IFU.sv 已经被 Makefile/filelist 包含
    IFU u_ifu (
        .clk(clk),
        .rst(rst),

        // FTQ 请求
        .ftq_req_valid(ftq_req_valid),
        .ftq_req_ready(ftq_req_ready),
        .ftq_req_start_addr(ftq_req_start_addr),
        .ftq_req_ftqIdx_i(ftq_req_ftqIdx_i),
        .ftq_predicted_taken_i(ftq_predicted_taken_i),
        .ftq_predicted_idx_i(ftq_predicted_idx_i),
        .ftq_req_cross_cacheline(ftq_req_cross_cacheline), // 【修正】添加连接
        .ftq_predicted_target_i(ftq_predicted_target_i),
        .ftq_flush_from_bpu(ftq_flush_from_bpu),
        .from_bpu_f1_flush(from_bpu_f1_flush),   // 【修正】添加连接
        .backend_redirect(backend_redirect),

        // I-Cache 请求 (监控)
        .icache_req_valid(icache_req_valid),
        .icache_req_addr(icache_req_addr),
        .icache_resp_ready(icache_resp_ready),
        .icache_req_double_line(icache_req_double_line), // 【修正】添加连接

        // I-Cache 响应 (驱动)
        .icache_resp_valid(icache_resp_valid),
        .icache_data(icache_data),
        .is_mmio_from_icache_resp(is_mmio_from_icache_resp),
        .icache_resp_ready_o(icache_resp_ready_o),     // 【修正】添加连接

        // I-Buffer (驱动 Ready, 监控 Output)
        .ibuffer_ready(ibuffer_ready),
        .to_ibuffer_valid(to_ibuffer_valid),
        .to_ibuffer_enqEnable(to_ibuffer_enqEnable),
        .to_ibuffer_pc(to_ibuffer_pc),
        .to_ibuffer_instr(to_ibuffer_instr),
        .to_ibuffer_pd(to_ibuffer_pd),

        // ROB 提交 (驱动)
        .rob_commits(rob_commits),

        // WB 反馈 (监控)
        .ifu_wb_info_o(ifu_wb_info_o)
    );
    
    // 在这个框架中，Testbench (tb_ifu.sv) 不做任何其他事情。
    // 所有的时钟、复位和激励都来自 C++。

endmodule
`default_nettype wire // 恢复默认值，防止影响其他文件