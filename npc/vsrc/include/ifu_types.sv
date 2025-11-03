// 这个文件定义了IFU模块中用到的共享参数和类型
package ifu_pkg;

    // ====================================================================
    // 共享常量 (Shared Constants)
    // ====================================================================
    parameter XLEN = 32;
    parameter CacheLine_Addr_Width = 32;//Cache line地址宽度
    parameter PredictWidth = 4; //一次取指的数量
    parameter instBytes = 4; //指令字节数
    parameter instOffsetBits = 2; //指令偏移位数
    parameter PcCutPoint = (XLEN/4) -1; //PC截断点
    parameter blockOffsetBits = 5; //Cache line块内偏移位数
    parameter BLOCK_BYTES = 16; //Cache line块大小(字节)
    parameter DATA_WIDTH = BLOCK_BYTES*8; //I-Cache数据宽度
    parameter HasCExtension = 0; //1:RVC支持 0:不支持
    parameter INST_BITS = instBytes * 8;  // 32
    parameter FTQ_IDX_WIDTH = 6; //FTQ索引宽度
    // ====================================================================
    // 共享类型 (Shared Types)
    // ====================================================================

    function automatic [$clog2(PredictWidth)-1:0] PriorityEncoder(input logic [PredictWidth-1:0] in_vec);
    for (int i = 0; i < PredictWidth; i++) begin
        if (in_vec[i]) return i;
    end
    return 0;
    endfunction
    
    //[新增]：为分支类型定义常量（枚举）
    localparam BR_TYPE_NONE = 4'd0;
    localparam BR_TYPE_JAL = 4'd1;
    localparam BR_TYPE_JALR = 4'd2;
    localparam BR_TYPE_BRANCH = 4'd3;   //所有的条件分支都归为一类

    typedef struct packed {
        logic       valid;
        logic       isRVC;
        logic [3:0] brType;         //使用上面的常量
        logic       isCall;
        logic       isRet;
    } PreDecodeInfo_t;

    //IFU返回给FTQ的信息包
    typedef struct packed {
        logic       valid;             // 這個信息包是否有效
        logic       mispredict;        // 是否發生了誤預測
        logic [XLEN-1:0] target;       // 正確的目標地址
        logic [FTQ_IDX_WIDTH-1:0] ftqIdx; // 對應的FTQ索引
    } IfuWbInfo_t;

endpackage // 结束包定义
