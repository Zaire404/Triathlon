import ifu_pkg::*;

module IFU (
    input logic clk,
    input logic rst,

    //来自FTQ的取指请求接口(Source: FTQ, Destination: IFU/F0)
    input logic ftq_req_valid,
    output logic ftq_req_ready,  //IFU准备好接收请求,IFU/F0 -> FTQ 的反压信号
    input logic [XLEN-1:0] ftq_req_start_addr,
    input logic ftq_req_cross_cacheline,  // 跨 Cacheline 标志 (你的关键点)
    input logic ftq_predicted_taken_i,  //BPU是否预测有跳转
    input logic [$clog2(PredictWidth)-1:0]ftq_predicted_idx_i,//BPU预测的跳转指令索引
    input logic [XLEN-1:0] ftq_predicted_target_i, //BPU预测目标地址
    input  logic [FTQ_IDX_WIDTH-1:0] ftq_req_ftqIdx_i,//FTQ所给的处理包的索引号
    output IfuWbInfo_t ifu_wb_info_o,//IFU到FTQ的写回

    //到I-cache的请求接口(Source: IFU/F0, Destination: I-Cache)
    output logic icache_req_valid,
    output logic [CacheLine_Addr_Width-1:0] icache_req_addr,
    output logic icache_req_double_line,  // I-Cache 是否进行双线取指
    input logic icache_resp_ready,  //I-cache准备好接收请求

    // 来自后端/内部的冲刷信号 (用于 f0_flush 的组合)
    input logic backend_redirect,
    input logic from_bpu_f1_flush,
    input logic ftq_flush_from_bpu, // 来自 BPU 的冲刷信号

    // I-Cache 接口 (Input)(Source: IFU/F2, Destination: I-Cache)
    input logic                  icache_resp_valid,  //icache返回数据的有效信号
    input logic [DATA_WIDTH-1:0] icache_data,         //icache返回的数据
    input logic is_mmio_from_icache_resp,
    output logic icache_resp_ready_o, // IFU/F2 -> I-Cache 的反压信号  

    //到I-Buffer的输出接口(Source: IFU/F3, Destination: I-Buffer)
    input logic ibuffer_ready,
    output logic to_ibuffer_valid,
    output logic [XLEN-1:0] to_ibuffer_pc        [0:PredictWidth-1],
    output logic [INST_BITS -1:0] to_ibuffer_instr [0:PredictWidth-1],
    output PreDecodeInfo_t to_ibuffer_pd        [0:PredictWidth-1],
    output logic [PredictWidth-1:0] to_ibuffer_enqEnable,
    // ... 其他 to_ibuffer_* 端口 ...       

    //来自RoB的提交端口
    input RobCommitInfo_t rob_commits [0:CommitWidth-1]
);

    //内部信号声明：流水线各级冲刷信号（用于f0 flush的组合）
    wire f0_flush, f1_flush, f2_flush, f3_flush;
    wire             f0_fire;
    //内部信号声明：各级准备好信号
    logic            f2_ready;
    logic            wb_redirect;
    logic            mmio_redirect;
    logic            f3_wb_not_flush;

    // ====================================================================
    // F1 阶段 - 流水线寄存器声明
    // ====================================================================

    // F1 状态和 FTQ 请求数据寄存器
    logic            f1_valid;
    logic [XLEN-1:0] f1_ftq_req_start_addr;
    logic            f1_predicted_taken;
    logic [$clog2(PredictWidth)-1:0] f1_predicted_idx;
    logic [XLEN-1:0] f1_predicted_target;
    logic [FTQ_IDX_WIDTH-1:0] f1_ftq_req_ftqIdx;   
    // ... 其他锁存的 FTQ 字段

    // F1 输出信号
    logic            f1_ready;
    logic            f1_fire;

    // --- A. 握手逻辑 ---
    // 1. IFU/F0 准备好接收 FTQ 请求，取决于 I-Cache 是否准备好 (反压)
    //    ftq_req_ready 对应 Scala 中的 fromFtq.req.ready := f1_ready && io.icacheInter.icacheReady
    //    这里简化假设 ftq_req_ready 只需要 f1_ready 和 icache_resp_ready
    assign ftq_req_ready = f1_ready & icache_resp_ready;

    // 2. F0 阶段的握手成功信号 (fire 信号)
    assign f0_fire = ftq_req_valid & ftq_req_ready;

    // --- B. 冲刷逻辑组合 ---
    // 注意：这里需要假设 f3_flush 和 f2_flush 等信号的输入方式 (为了 f0 逻辑的完整性)
    // 在完整的 IFU 中，这些信号要么是 wire 连接，要么是 input 端口。

    // 假设这些冲刷信号的逻辑如下 (基于 Scala 代码的组合逻辑)：
    // f3_flush, f2_flush, f1_flush 都会组合到 f0_flush
    assign f3_flush = backend_redirect | (wb_redirect & !f3_wb_not_flush);
    assign f2_flush = f3_flush | mmio_redirect;
    assign f1_flush = f2_flush | from_bpu_f1_flush;
    assign f0_flush = f1_flush | ftq_flush_from_bpu;

    // --- C. I-Cache 请求生成和跨 Cacheline 操作 ---
    // I-Cache 请求有效性：只有在握手成功且没有冲刷信号时才有效
    assign icache_req_valid = f0_fire & !f0_flush;

    // I-Cache 请求地址：直接使用 FTQ 提供的起始 PC (通常是 Cache Line 对齐后的地址)
    assign icache_req_addr = ftq_req_start_addr;

    // I-Cache 双线取指：直接使用 FTQ 提供的跨 Cacheline 标志 (你的关键点)
    assign icache_req_double_line = ftq_req_cross_cacheline;


    // ====================================================================
    // F1 阶段 - 时序逻辑 (State Machine)
    // ====================================================================

    always_ff @(posedge clk or posedge rst) begin : F1_REG_UPDATE
        if (rst) begin
            f1_valid <= 1'b0;
            f1_ftq_req_start_addr <= '0;
            f1_predicted_taken <= 1'b0;
            f1_predicted_idx <= '0;
            f1_predicted_target <= '0;
        end else if (f1_flush) begin
            // --- 1. 冲刷逻辑 (清空) ---
            // f1_flush 信号是组合逻辑链 f2_flush | from_bpu_f1_flush 
            f1_valid <= 1'b0;
            f1_ftq_req_start_addr <= '0;
            f1_predicted_taken <= 1'b0;
            f1_predicted_idx <= '0;
            f1_predicted_target <= '0;
            // 实际硬件中，其他寄存器如 f1_ftq_req_start_addr 也会被清零或无效，这里省略
        end else begin
            // --- 2. 有效位状态机 ---
            if (f0_fire && !f0_flush) begin
                // 接收新数据 (F0 -> F1)
                f1_valid              <= 1'b1;
                f1_ftq_req_start_addr <= ftq_req_start_addr;
                f1_predicted_taken <= ftq_predicted_taken_i;
                f1_predicted_idx <= ftq_predicted_idx_i;
                f1_predicted_target <= ftq_predicted_target_i;
                f1_ftq_req_ftqIdx <= ftq_req_ftqIdx_i;
            end else if (f1_fire) begin
                // 发射数据到 F2 (F1 -> F2)
                f1_valid <= 1'b0;
            end
            // 如果 f1_valid == 1'b1 且 !(f0_fire && !f0_flush) 且 !f1_fire，则保持状态 (Stall)
        end
    end


    // ====================================================================
    // F1 阶段 - 组合逻辑 (Handshake & Calculation)
    // ====================================================================
    // F1 握手信号
    // f1_fire: F1 成功发射到 F2
    assign f1_fire  = f1_valid & f2_ready;
    // f1_ready: F1 准备好接收 F0 数据 (如果 F1 要发射了，或者 F1 已经无效了)
    assign f1_ready = f1_fire | !f1_valid;

    // ----------------------------------------------------
    // PC 地址生成 (核心计算)
    // ----------------------------------------------------

    localparam PC_LOW_BITS = PcCutPoint;
    localparam PC_HIGH_BITS = XLEN - PcCutPoint;

    // F1 阶段的 PC 高位计算保持不变
    logic [XLEN-1:PcCutPoint] f1_pc_high;
    logic [XLEN-1:PcCutPoint] f1_pc_high_plus1;

    assign f1_pc_high       = f1_ftq_req_start_addr[XLEN-1:PcCutPoint];
    assign f1_pc_high_plus1 = f1_pc_high + 1'b1;
    // 1. PC 低位增量计算
    //    指令步长变为 4 字节 (i * 4)，相当于 i << 2
    logic [PC_LOW_BITS:0] f1_pc_lower_result[0:PredictWidth-1];

    generate
        for (genvar i = 0; i < PredictWidth; i++) begin : gen_pc_lower_rvi
            // 【修改点】：步长为 4 字节 (i << 2)
            assign f1_pc_lower_result[i] = {1'b0, f1_ftq_req_start_addr[PcCutPoint-1:0]} + (i << 2);
        end
    endgenerate

    // 2. 完整 PC 序列生成 (CatPC 逻辑保持不变)
    logic [XLEN-1:0] f1_pc[0:PredictWidth-1];

    generate
        for (genvar i = 0; i < PredictWidth; i++) begin : gen_pc_full_rvi
            // CatPC 逻辑 (Mux(low(PcCutPoint), Cat(high1, ...), Cat(high, ...)))
            assign f1_pc[i] = f1_pc_lower_result[i][PC_LOW_BITS] ? 
                {f1_pc_high_plus1, f1_pc_lower_result[i][PC_LOW_BITS-1:0]} : // 低位溢出，使用 high+1
                {f1_pc_high, f1_pc_lower_result[i][PC_LOW_BITS-1:0]};  // 否则，使用 high
        end
    endgenerate


    // ====================================================================
    // F2 阶段 - 流水线寄存器声明
    // ====================================================================

    // F2 寄存器 (由 F1 阶段锁存)
    logic                              f2_valid;
    logic           [XLEN-1:0]         f2_pc                                [0:PredictWidth-1];
    // ... 其他锁存的 FTQ 请求字段

    //内部信号
    logic                              f2_fire;
    logic                              f3_ready;  // 来自f3的反压信号
    logic           [instBytes*8 -1:0] f2_instr_vec                         [0:PredictWidth-1];
    wire                               f2_is_mmio_req = f2_valid & is_mmio_from_icache_resp;
    logic                              f2_predicted_taken;
    logic [$clog2(PredictWidth)-1:0]   f2_predicted_idx;
    logic [XLEN-1:0]                   f2_predicted_target;
    logic [FTQ_IDX_WIDTH-1:0]          f2_ftq_req_ftqIdx;

    //PreDecode子模组的输出信号（将被f3锁存）
    //假设 PreDecodeInfo是一个struct或对应的wire bundle
    PreDecodeInfo_t                    f2_pd                                [0:PredictWidth-1];
    logic           [        XLEN-1:0] f2_jump_offset                       [0:PredictWidth-1];

    // F2 阶段时序逻辑
    always_ff @(posedge clk or posedge rst) begin : F2_REGISTERS
        if (rst) begin
            // --- 硬體復位 ---
            f2_valid <= 1'b0;
            f2_pc    <= '{default: '0};
            f2_predicted_taken <= 1'b0;
            f2_predicted_idx <= '0;
            f2_predicted_target <= '0;
        end else if (f2_flush) begin
            // --- 流水線沖刷 (來自 F3/F2/後端的組合邏輯信號) ---
            f2_valid <= 1'b0;
            f2_pc    <= '{default: '0};
            f2_predicted_taken <= 1'b0;
            f2_predicted_idx <= '0;
            f2_predicted_target <= '0;
        end else begin
            // --- 正常流水線操作 ---
            if (f1_fire) begin
                // 接收新數據 (F1 -> F2)
                f2_valid <= 1'b1;
                f2_pc    <= f1_pc; // 鎖存 F1 階段計算的 PC 序列
                f2_predicted_taken <= f1_predicted_taken;
                f2_predicted_idx <= f1_predicted_idx;
                f2_predicted_target <= f1_predicted_target;
                f2_ftq_req_ftqIdx <= f1_ftq_req_ftqIdx;
            end else if (f2_fire) begin
                // 成功發射 (F2 -> F3)，F2 級變為無效
                f2_valid <= 1'b0;
            end
            // 如果 !(f1_fire) && !(f2_fire)，則 f2_valid 保持不變 (Stall)
        end
    end



    // --------------------------------------------------------------------
    // F2 階段 - 組合邏輯 (握手、指令切取、預譯碼連接)
    // --------------------------------------------------------------------

    // --- A. 握手邏輯 ---
    // F2 成功發射的條件：F1 的數據已到達、I-Cache 的數據已到達、且 F3 準備好接收
    assign f2_fire = f2_valid & icache_resp_valid & f3_ready;

    // F2 -> F1 的就緒/反壓信號
    assign f2_ready = f2_fire | !f2_valid;

    // F2 -> I-Cache 的就緒/反壓信號
    // 在簡化模型中，F2 必須同時準備好接收 PC 和指令數據
    // 这个信号有什么用，在f2阶段里并没有被用到过
    assign icache_resp_ready_o = f2_ready;

    // --- B. 指令切取 (Instruction Cutting) ---
    // 由於 I-Cache 已返回對齊好的指令塊，這裡變為簡單的位切片

    

    generate
        for (genvar i = 0; i < PredictWidth; i++) begin : gen_instr_cut
            // 計算第 i 條指令在 128 位元 `icache_data` 中的起始和結束位
            localparam START_BIT = i * INST_BITS;
            localparam END_BIT = (i + 1) * INST_BITS - 1;

            // 從 `icache_data` 總線中直接切取出 32 位元指令
            assign f2_instr_vec[i] = icache_data[END_BIT : START_BIT];
        end
    endgenerate

    // --- C. 預譯碼器 (PreDecoder) 連接 ---
    // 實例化 PreDecode 子模組，並將 F2 的輸出連接到其輸入

    // PreDecode 的輸入有效信號：僅在 F2 成功發射時有效
    wire predecode_in_valid = f2_fire;

    PreDecode u_preDecoder (
        .clk(clk),
        .rst(rst),

        // 輸入
        .in_valid(predecode_in_valid),
        .in_pc   (f2_pc),
        .in_data (f2_instr_vec),

        // 輸出 (這些信號將被 F3 級鎖存)
        .out_pd         (f2_pd),
        .out_jump_offset(f2_jump_offset)
        // ... 其他 PreDecode 輸出
    );

    // ====================================================================
    // IFU F3 阶段 (指令打包、最终检查与发送)
    // ====================================================================

    // --------------------------------------------------------------------
    // F3 阶段 - 内部信号和寄存器声明
    // --------------------------------------------------------------------

    // F3 流水线寄存器
    logic                   f3_valid;
    logic [XLEN-1:0]        f3_pc         [0:PredictWidth-1];
    logic [INST_BITS-1:0]   f3_instr_vec  [0:PredictWidth-1];//从f2中切割出来的指令
    PreDecodeInfo_t         f3_pd         [0:PredictWidth-1];
    logic [XLEN-1:0]        f3_jump_offset[0:PredictWidth-1];
    logic                   f3_predicted_taken;
    logic [$clog2(PredictWidth)-1:0] f3_predicted_idx;
    logic [XLEN-1:0]        f3_predicted_target;
    logic [FTQ_IDX_WIDTH-1:0] f3_ftq_req_ftqIdx;

    //F3内部控制信号
    logic f3_fire;   //f3成功发射信号
    logic f3_is_stalled_by_mmio;  // mmio停机状态寄存器
    logic f3_is_mmio_req; // 来自f2的mmio请求信号

    //PredChecker的输出信号（将被WB阶段使用）
    logic wb_mispredicted;
    logic [XLEN-1:0] wb_target;

    //新增：检查ROB提交的ID是否与F3正在等待的MMIO指令ID匹配
    logic mmio_commit_match;
    logic commit_match_found; //用于for循环的临时变量



    // --------------------------------------------------------------------
    // F3 阶段 - 时序逻辑 (F2 -> F3 流水线寄存器 和 简化MMIO状态机)
    // --------------------------------------------------------------------

    //F3阶段流水线寄存器
    always_ff @(posedge clk or posedge rst) begin : F3_REGISTERS
        if (rst) begin
            f3_valid <= 1'b0;
            f3_pc  <= '{default: '0};
            f3_instr_vec <= '{default: '0};
            f3_pd  <= '{default: '0};
            f3_jump_offset <= '{default: '0};
            f3_is_mmio_req <= 1'b0;
            f3_predicted_taken <= 1'b0;
            f3_predicted_idx <= '0;
            f3_predicted_target <= '0;
        end else if(f3_flush) begin
            f3_valid <= 1'b0;
            f3_pc  <= '{default: '0};
            f3_instr_vec <= '{default: '0};
            f3_pd  <= '{default: '0};
            f3_jump_offset <= '{default: '0};
            f3_is_mmio_req <= 1'b0;
            f3_predicted_taken <= 1'b0;
            f3_predicted_idx <= '0;
            f3_predicted_target <= '0;
        end else if(f2_fire) begin
            f3_valid <= 1'b1;
            f3_pc    <= f2_pc;
            f3_instr_vec <= f2_instr_vec;
            f3_pd   <= f2_pd;
            f3_jump_offset <= f2_jump_offset;
            f3_is_mmio_req <= f2_is_mmio_req;
            f3_predicted_taken <= f2_predicted_taken;
            f3_predicted_idx <= f2_predicted_idx;
            f3_predicted_target <= f2_predicted_target;
            f3_ftq_req_ftqIdx <= f2_ftq_req_ftqIdx;
        end else if (f3_fire) begin
            f3_valid <= 1'b0;
        end
    end

    //F3阶段简化的MMIO停机状态机
    // 假设 is_mmio_from_icache_resp 是一个 input 端口，来自 I-Cache 响应

    always_ff @(posedge clk or posedge rst) begin : MMIO_STATE_MACHINE
        if(rst)begin
            f3_is_stalled_by_mmio <= 1'b0;
        end else if(f3_flush)begin
            //异常退出：被更高优先级的冲刷清零
            f3_is_stalled_by_mmio <= 1'b0;
        end else if(f3_is_stalled_by_mmio)begin
            //如果当前处于停机状态，检查推出条件
            if(mmio_commit_match)begin
                f3_is_stalled_by_mmio <= 1'b0;   //匹配成功，正常退出停机
            end
        end else if(f3_is_mmio_req)begin
            //如果检测到MMIO请求，进入停机
            f3_is_stalled_by_mmio <= 1'b1;
        end
    end

    // --------------------------------------------------------------------
    // F3 阶段 - 组合逻辑 (握手、子模块连接、输出到I-Buffer)
    // --------------------------------------------------------------------
    

    always_comb begin
        commit_match_found = 1'b0;
        //只有当F3确实因为MMIO而停机时，才需要检查
        if(f3_is_stalled_by_mmio)begin
            //遍历所有来自ROB的提交端口
            for(int i = 0;i<CommitWidth;i++)begin
                //检查：1.这个提交槽位有效吗？2.它的ID是否就是F3正在等待的那个ID？
                if(rob_commits[i].valid&&(rob_commits[i].ftqIdx==f3_ftq_req_ftqIdx))begin
                    commit_match_found = 1'b1;
                end
            end
        end
    end

    assign mmio_commit_match = commit_match_found;
    // --- A. 握手逻辑 ---
    assign f3_fire = f3_valid & ibuffer_ready & !f3_is_stalled_by_mmio;
    assign f3_ready = f3_fire | !f3_valid;

    // --- B. RVC 指令扩展 (简化，假设无RVC) ---
    // 在这个简化模型中，指令已经是32位，直接传递
    wire [INST_BITS-1:0] f3_expd_instr [0:PredictWidth-1];
    assign f3_expd_instr = f3_instr_vec;

    // --- C. 分支预测检查器 (PredChecker) 连接 ---
    // 实例化 PredChecker 子模块 (假设已在文件末尾定义)
        PredChecker u_predChecker (
    .clk(clk),
    .rst(rst),
    
    // 输入：使用 F3 寄存器中的稳定数据
    .in_valid(f3_valid), 
    .in_pc(f3_pc),
    .in_pd(f3_pd),
    .in_jump_offset(f3_jump_offset),
    
    .in_predicted_taken(f3_predicted_taken),
    .in_predicted_idx(f3_predicted_idx),
    .in_predicted_target(f3_predicted_target),
    
    // 输出：这些信号将用于驱动写回(WB)阶段的重定向逻辑
    .out_mispredicted(wb_mispredicted), 
    .out_correct_target(wb_target)
    );


    // --- D. 有效位掩码 (Valid Mask) 生成 ---

    // 1. 中间信号：创建一个向量，标记出哪些指令是控制流指令 (CFI)
    logic [PredictWidth-1:0] is_cfi_vec; // CFI = Control Flow Instruction

    // 2. 最终输出：有效位掩码
    logic [PredictWidth-1:0] f3_valid_mask;

    always_comb begin : GEN_VALID_MASK
        //---步骤一：识别所有控制流指令---
        //遍历F3寄存器中的预译码信息（F3_PD)
        for(int i = 0;i< PredictWidth;i++)begin
            //如果指令的brType不是NONE，那它就是一条会改变PC的指令
            if(f3_pd[i].brType!=BR_TYPE_NONE)begin
                is_cfi_vec[i] = 1'b1;
            end else begin
                is_cfi_vec[i] = 1'b0;
            end
        end

        //---步骤二：生成有效位掩码（扫描链逻辑）---
        //核心思想：一条指令是有效的，当且仅当它前面的所有指令都不是分支指令

        //基本情况：第0条指令总是有效的（只要F3级本身有效）
        f3_valid_mask[0] = f3_valid;;

        //递推情况：从第一条指令开始扫描
        for(int j =1;j< PredictWidth;j++)begin
            //当前指令有效的条件：F3级有效且前一条指令不是CFI
            f3_valid_mask[j] = !is_cfi_vec[j-1] & f3_valid_mask[j-1];
        end
    end
    // --- E. 连接到 IFU 的输出端口 (发送到 I-Buffer) ---
    // 假设 to_ibuffer_* 是 IFU 模块的 output 端口
    // 只有在F3成功发射时，才输出有效的掩码
    assign to_ibuffer_enqEnable = f3_fire ? f3_valid_mask : '0;

    assign to_ibuffer_valid = f3_fire;
    assign to_ibuffer_pc    = f3_pc;
    assign to_ibuffer_instr = f3_expd_instr; // 发送扩展后的(或原始的)指令
    assign to_ibuffer_pd    = f3_pd;
    // ... 连接所有 to_ibuffer_* 端口 ...
    //反压信号
    assign mmio_redirect = f3_is_mmio_req&&f3_is_stalled_by_mmio;

    // ====================================================================
    // WB / F4 阶段 - 控制寄存器声明
    // ====================================================================
    logic                   wb_valid; // WB阶段是否有效
    logic [7:0]             wb_ftq_req_ftqIdx; // 锁存F3的FTQ索引，用于f3_wb_not_flush比较

    // 锁存PredChecker的输出
    logic                   wb_mispredict_reg;
    logic [XLEN-1:0]   wb_target_reg;

    // ====================================================================
    // WB / F4 阶段 - 时序逻辑
    // ====================================================================
    always_ff @(posedge clk or posedge rst) begin : WB_REGISTERS
        if (rst) begin
            wb_valid <= 1'b0;
            wb_ftq_req_ftqIdx <= '0;
            wb_mispredict_reg <= 1'b0;
            wb_target_reg     <= '0;
        end else if (f3_flush) begin // 如果F3被更高优先级冲刷，WB也必须清空
            wb_valid <= 1'b0;
            wb_ftq_req_ftqIdx <= '0;
            wb_mispredict_reg <= 1'b0;
            wb_target_reg     <= '0;
        end else if (f3_fire) begin
            // 当F3成功发射时，锁存F3的当前状态和PredChecker的检查结果
            wb_valid <= f3_valid; // 将F3的有效性传递给WB
            wb_ftq_req_ftqIdx <= f3_ftq_req_ftqIdx; // 假设f3_ftq_req_ftqIdx是F3的寄存器
        
            // 【核心】锁存PredChecker的组合逻辑输出
            wb_mispredict_reg <= wb_mispredicted; // wb_mispredict是PredChecker的out_mispredict
            wb_target_reg     <= wb_target;     // wb_target是PredChecker的out_correct_target
        end else begin
            // 如果F3没有发射（例如stall），WB阶段也清空
            wb_valid <= 1'b0;
        end
    end


    assign f3_wb_not_flush = 
    (wb_ftq_req_ftqIdx == f3_ftq_req_ftqIdx) && // 1. WB级和F3级在处理同一个指令包
    f3_valid &&                                // 2. F3级当前有有效数据 (表示停顿)
    wb_valid;                                  // 3. WB级也有效 (表示上个周期F3发射了)

    assign wb_redirect = wb_mispredict_reg;
    // --- 連接IFU的寫回輸出端口 ---
    assign ifu_wb_info_o.valid      = wb_valid; // WB級有效，則反饋信息有效
    assign ifu_wb_info_o.mispredict = wb_mispredict_reg;    
    assign ifu_wb_info_o.target     = wb_target_reg;
    assign ifu_wb_info_o.ftqIdx     = wb_ftq_req_ftqIdx;

endmodule



// ====================================================================
// PreDecode 子模块定义
// ====================================================================
module PreDecode (
    input logic clk,
    input logic rst,

    //输入
    input logic                    in_valid,
    input logic [        XLEN-1:0] in_pc   [0:PredictWidth-1],
    input logic [instBytes*8 -1:0] in_data [0:PredictWidth-1],

    //输出
    output PreDecodeInfo_t            out_pd         [0:PredictWidth-1],
    output logic           [XLEN-1:0] out_jump_offset[0:PredictWidth-1]
);

    // 【核心修改】: 使用 always_comb 替代 assign
    generate
        for (genvar i = 0; i < PredictWidth; i++) begin : gen_predecode_logic

            // 使用 always_comb 块来进行组合逻辑赋值
            always_comb begin
                //声明临时变量
                logic [6:0] opcode;
                logic [2:0] funct3;
                logic [4:0] rd;
                logic [4:0] rs1;
                logic [20:0] imm_j;     //J-Type立即数
                logic [11:0] imm_i;     //I-Type立即数
                logic [12:0] imm_b;     //SB-Type立即数

                //1.首先，将输出初始化为默认值（非分支指令）
                out_pd[i].valid = in_valid;
                out_pd[i].isRVC = 1'b0;
                out_pd[i].brType = BR_TYPE_NONE;
                out_pd[i].isCall = 1'b0;
                out_pd[i].isRet  = 1'b0;
                out_jump_offset[i] = '0;
                //2.解码指令的关键字段

                opcode = in_data[i][6:0];
                funct3 = in_data[i][14:12];
                rd     = in_data[i][11:7];
                rs1    = in_data[i][19:15];

                //3.根据Opcode判断指令类型
                case(opcode)
                    // --- UJ-Type (JAL) (Jump and Link)---
                    7'b1101111: begin // JAL
                        out_pd[i].brType = BR_TYPE_JAL;
                        // 判断是否为函数调用,如果目标寄存器是x1(ra)或x5(t0)，通常认为是函数调用
                        if (rd == 5'd1 || rd == 5'd5) begin
                            out_pd[i].isCall = 1'b1;
                        end
                        //提取J-Type立即数：imm[20|10:1|11|19:12]
                        imm_j = {in_data[i][31], in_data[i][19:12], in_data[i][20], in_data[i][30:21], 1'b0};
                        //符号扩展
                        out_jump_offset[i] = {{(XLEN-21){imm_j[20]}}, imm_j};
                    end

                    // --- I-Type (JALR) (Jump and Link Register)---
                    7'b1100111: begin // JALR
                        out_pd[i].brType = BR_TYPE_JALR;
                        // 识别函数返回：jarl x0 x1, 0
                        if (rs1 == 5'd1 && rd == 5'd0 && in_data[i][31:20] == 12'd0) begin
                            out_pd[i].isRet = 1'b1;
                        end
                        //识别函数调用
                        if (rd == 5'd1 || rd == 5'd5) begin
                            out_pd[i].isCall = 1'b1;
                        end
                        //提取I-Type立即数:imm[11:0]
                        imm_i = in_data[i][31:20];
                        //符号扩展
                        out_jump_offset[i] = {{(XLEN-12){imm_i[11]}}, imm_i};
                    end

                    //---SB-Type (Conditional Branches)---
                    7'b1100011: begin // Branch instructions
                        out_pd[i].brType = BR_TYPE_BRANCH;
                        // 提取分支偏移量 (SB-Type 立即数)
                        imm_b = {in_data[i][31], in_data[i][7], in_data[i][30:25], in_data[i][11:8], 1'b0};
                        // 符号扩展
                        out_jump_offset[i] = {{(XLEN-13){imm_b[12]}}, imm_b};
                    end

                    default: begin
                        // 其他指令类型不处理，保持默认值
                    end
                endcase
            end
        end
    endgenerate

endmodule

// ====================================================================
// PredChecker 子模块定义 (分支预测检查器)
// ====================================================================
module PredChecker (
    input logic clk,
    input logic rst,

    //---输入（来自F3阶段的稳定数据）---
    input logic                 in_valid,    //F3阶段数据有效信号
    input logic [XLEN-1:0]      in_pc       [0:PredictWidth-1], //F3的PC序列
    input PreDecodeInfo_t       in_pd       [0:PredictWidth-1], //F3的预译码信息
    input logic [XLEN-1:0]      in_jump_offset[0:PredictWidth-1],//F3的跳转偏移量

    //---BPU的原始预测信息（也从F3阶段传来）---
    input logic                             in_predicted_taken, //BPU预测是否有跳转发生
    input logic [$clog2(PredictWidth)-1:0]  in_predicted_idx, //BPU预测的跳转指令索引
    input logic [XLEN-1:0]                  in_predicted_target, //BPU预测的跳转目标地址

    //---输出（传递到WB阶段）---
    output logic                out_mispredicted, //是否预测错误
    output logic [XLEN-1:0]     out_correct_target //计算出的正确目标地址
);

    //内部信号，用于并行检查每一条指令
    logic [PredictWidth-1:0] mispredict_vec;
    logic [XLEN-1:0] correct_target_vec[0:PredictWidth-1];

    //使用generate for并行的处理每一条指令
    generate
        for(genvar i = 0; i < PredictWidth; i++) begin : gen_pred_checker
            always_comb begin
                //1.初始化默认值
                logic is_predicted_branch;
                logic is_actual_branch;
                logic [XLEN-1:0] actual_target;
                mispredict_vec[i] = 1'b0;
                correct_target_vec[i] = '0;

                if(in_valid)begin
                    //2.准备检查所需的信息
                    is_predicted_branch = in_predicted_taken && (in_predicted_idx == i);//BPU是否预测该指令跳转
                    is_actual_branch = (in_pd[i].brType != BR_TYPE_NONE);//该指令是否实际为分支指令

                    //3.计算当前指令的实际目标地址（PC+offset）
                    actual_target = in_pc[i] + in_jump_offset[i];

                    //4.进行预测检查

                    //---Case 1:错误的正向预测（BPU说跳了，实际没跳）---
                    if(is_predicted_branch && !is_actual_branch)begin
                        mispredict_vec[i] = 1'b1;
                        correct_target_vec[i] = in_pc[i] + 4; //下一条指令地址
                    end

                    //---Case 2:错误的负向预测（BPU说没跳，实际跳了）---
                    else if(!is_predicted_branch && is_actual_branch)begin
                        mispredict_vec[i] = 1'b1;
                        correct_target_vec[i] = actual_target; //实际目标地址
                    end

                    //---Case 3:目标地址不匹配（BPU和PreDecode都认为跳了，但是目标地址不对）
                    //注意：JALR的目标地址在前端无法计算，所以不检查
                    else if(is_predicted_branch&&is_actual_branch && in_pd[i].brType != BR_TYPE_JALR)begin
                        if(in_predicted_target!=actual_target)begin
                            mispredict_vec[i] = 1'b1;
                            correct_target_vec[i] = actual_target;
                        end
                    end
                end
            end
        end
    endgenerate

    //5.仲裁：找到第一个发生误预测的指令
    //使用优先编码器（Priority Encoder）
    logic [$clog2(PredictWidth-1):0] first_mispredict_idx;

    assign out_mispredicted = |mispredict_vec;

    //找到第一个为1的位的索引
    //这是一个简化的实现，实际中可能会用更高效的编码器
    assign first_mispredict_idx = PriorityEncoder(mispredict_vec);

    //输出第一个误预测指令对应的正确目标地址
    assign out_correct_target = correct_target_vec[first_mispredict_idx];

endmodule