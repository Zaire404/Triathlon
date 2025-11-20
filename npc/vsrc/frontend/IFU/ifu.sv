


/*  Instruction Fetch Unit
    职责
    1.与BPU握手，管理PC寄存器，同时如果后端有冲刷以及重定向需求则更新PC寄存器，已重定向的更新为最高优先级
    2.使用PC向Icache请求指令
    3.处理Icache响应并将数据发送至Ibuffer
*/
module ifu
    import global_config_pkg::*;
(
    input logic clk,
    input logic rst,

    //--- 1.BPU握手接口 ---
    output handshake_t     ifu2bpu_handshake_o, // IFU -> BPU: 握手信号
    input  handshake_t     bpu2ifu_handshake_i, // BPU -> IFU: 握手信号
    output logic [cfg.PLEN-1:0] ifu2bpu_pc_o, // IFU -> BPU: 当前的PC值
    input  logic [cfg.PLEN-1:0] bpu2ifu_predicted_pc_i, // BPU -> IFU: 预测的PC值

    //--- 2.ICache请求接口 ---
    output handshake_t      ifu2icache_req_handshake_o, // IFU -> ICache: 握手信号
    input  handshake_t      icache2ifu_rsp_handshake_i, // ICache -> IFU: 握手信号
    output logic [cfg.VLEN-1:0] ifu2icache_req_addr_o, // IFU -> ICache: 请求的指令地址
    input  logic [cfg.INSTR_PER_FETCH-1:0][cfg.ILEN-1:0] icache2ifu_rsp_data_i, // ICache -> IFU: 响应的指令数据
    output logic            flush_icache_o, // IFU -> ICache: 冲刷信号
    
    //--- 3.Ibuffer响应接口 ---
    output logic                      ifu_ibuffer_rsp_valid_o, // IFU -> IBuffer: "我有有效的指令数据"
    output logic [cfg.PLEN-1:0]          ifu_ibuffer_rsp_pc_o, // IFU -> IBuffer: fetch group的pc
    input  logic                      ibuffer_ifu_rsp_ready_i, // IBuffer -> IFU: "我准备好接收你的指令数据了"
    output logic [cfg.INSTR_PER_FETCH-1:0][cfg.ILEN-1:0] ifu_ibuffer_rsp_data_o, // IFU -> IBuffer: "这是你请求的指令数据"

    //--- 4.后端冲刷/重定向接口 ---
    input  logic                      flush_i, // 后端 -> IFU: 冲刷信号
    input  logic [cfg.PLEN-1:0]          redirect_pc_i // 后端 -> IFU: 重定向PC地址
);

    // =================================================================
    // 状态定义
    // =================================================================
    typedef enum logic [1:0] {
        S_START,        // 1. 准备PC，发起请求，允许BPU更新
        S_WAIT_ICACHE,  // 2. 请求已发出，等待ICache回数据，反压BPU
        S_WAIT_IBUFFER  // 3. 数据已到，等待IBuffer取走
    } state_t;

    state_t current_state, next_state;

    //pc寄存器
    logic [cfg.PLEN-1:0] pc_reg;
    logic                pcg_stage_valid;

    always @(posedge clk) begin
        if(rst) begin
            pc_reg <= 'h80000000;
            pcg_stage_valid <= 1'b1;
        end else if(flush_i)begin
            pc_reg <= redirect_pc_i;
            pcg_stage_valid <= 1'b1;
        end else if(ifu2bpu_handshake_o.ready&&ifu2bpu_handshake_o.valid) begin
            pc_reg <= bpu2ifu_predicted_pc_i;
            pcg_stage_valid <= 1'b1;  
        end
    end

    // 状态转移
    always_ff @(posedge clk ) begin
        if (rst) begin
            current_state <= S_START;
        end else if(flush_i) begin
            current_state <= S_START;
        end else begin
            current_state <= next_state;
        end
    end


    //组合逻辑
    assign flush_icache_o = flush_i;
    assign ifu2bpu_pc_o = pc_reg;
    assign ifu_ibuffer_rsp_pc_o = pc_reg;
    assign ifu2icache_req_addr_o = pc_reg;
    assign ifu_ibuffer_rsp_data_o = icache2ifu_rsp_data_i;

    always_comb begin
        next_state = current_state;

        ifu2bpu_handshake_o.valid = 1'b0;
        ifu2bpu_handshake_o.ready = 1'b0;
        ifu2icache_req_handshake_o.valid = 1'b0;
        ifu2icache_req_handshake_o.ready = 1'b0;
        ifu2icache_req_addr_o = pc_reg;
        ifu_ibuffer_rsp_valid_o = 1'b0;

        case (current_state)
        // --------------------------------------------------------
        // S_START
        // --------------------------------------------------------
            S_START:begin
                ifu2bpu_handshake_o.valid = pcg_stage_valid;
                ifu2icache_req_handshake_o.valid = pcg_stage_valid;

                //start 状态下，不允许更新pc,此时会将已经更新好的pc传给bpu以及icache
                if(bpu2ifu_handshake_i.valid&&icache2ifu_rsp_handshake_i.valid) begin
                    ifu2bpu_handshake_o.ready = 0;
                    if(!ibuffer_ifu_rsp_ready_i) begin
                        next_state = S_WAIT_IBUFFER;
                    end else begin
                        next_state = S_WAIT_ICACHE;
                    end
                end
            end
        // --------------------------------------------------------
        // S_WAIT_ICACHE
        // --------------------------------------------------------
            S_WAIT_ICACHE:begin
                ifu2icache_req_handshake_o.ready = 1'b1;
                ifu_ibuffer_rsp_valid_o = 1;
                if(icache2bpu_rsp_handshake_i.valid)begin
                    ifu2bpu_handshake_o.ready = 1'b1;
                    next_state = S_START;
                end
            end

        // --------------------------------------------------------
        // S_WAIT_IBUFFER (请求已发，IBuffer 忙，ICache 在跑)
        // --------------------------------------------------------
            S_WAIT_IBUFFER:begin
                if(ibuffer_ifu_rsp_ready_i) begin
                    if(icache2ifu_rsp_handshake_i.valid)begin
                        ifu_ibuffer_rsp_valid_o = 1;
                        ifu2icache_req_handshake_o.ready = 1'b1;
                        next_state = S_START;
                    end
                    else begin
                        next_state = S_WAIT_ICACHE;
                    end
                end    
            end
        endcase
    end
endmodule : ifu
