// vsrc/backend/store_buffer.sv
import config_pkg::*;
import decode_pkg::*;

module store_buffer #(
    parameter int unsigned SB_DEPTH = 16, // Store Buffer 深度
    parameter int unsigned ROB_IDX_WIDTH = 6
) (
    input logic clk_i,
    input logic rst_ni,

    // =======================================================
    // 1. Dispatch (From Rename) - 分配 SB 條目
    // =======================================================
    input  logic alloc_req_i,
    output logic alloc_gnt_o,      // SB 未滿，允許 Dispatch
    output logic [$clog2(SB_DEPTH)-1:0] alloc_id_o, // 分配到的 SB ID

    // =======================================================
    // 2. Execute (From AGU/ALU) - 填入地址和數據
    // =======================================================
    // Store 指令計算完地址和數據後，寫入 SB (亂序寫入)
    input logic        ex_valid_i,
    input logic [$clog2(SB_DEPTH)-1:0] ex_sb_id_i,
    input logic [Cfg.PLEN-1:0] ex_addr_i,
    input logic [Cfg.XLEN-1:0] ex_data_i,
    input decode_pkg::lsu_op_e ex_op_i,

    // =======================================================
    // 3. Commit (From ROB) - 標記為 "Senior Store"
    // =======================================================
    // ROB 只要發個信號，就不管了，不需要等 D-Cache
    input logic        commit_valid_i,
    input logic [$clog2(SB_DEPTH)-1:0] commit_sb_id_i, 

    // =======================================================
    // 4. D-Cache Interface (To L1 D$) - 後台寫入
    // =======================================================
    output logic        dcache_req_valid_o,
    input  logic        dcache_req_ready_i, // D-Cache 準備好接收寫請求
    output logic [Cfg.PLEN-1:0] dcache_req_addr_o,
    output logic [Cfg.XLEN-1:0] dcache_req_data_o,
    output decode_pkg::lsu_op_e dcache_req_op_o,

    // =======================================================
    // 5. Load Forwarding (From Load Unit) - 關鍵邏輯
    // =======================================================
    input  logic [Cfg.PLEN-1:0] load_addr_i,
    output logic                load_hit_o,   // 在 SB 中命中且數據有效
    output logic [Cfg.XLEN-1:0] load_data_o,  // 轉發的數據

    // =======================================================
    // 6. Control
    // =======================================================
    input logic flush_i
);

    // --- SB Entry 定義 ---
    typedef struct packed {
        logic valid;          // 1 = 條目被佔用
        logic committed;      // 1 = 已退休 (Senior), 0 = 推測中 (Speculative)
        logic addr_valid;     // 1 = 地址已計算
        logic data_valid;     // 1 = 數據已計算
        
        logic [Cfg.PLEN-1:0] addr;
        logic [Cfg.XLEN-1:0] data;
        decode_pkg::lsu_op_e op;
    } sb_entry_t;

    sb_entry_t [SB_DEPTH-1:0] mem;
    
    // 指針定義：
    // head_ptr: 指向最舊的條目 (隊頭，負責寫 D-Cache)
    // tail_ptr: 指向隊尾下一個空閒位置 (負責 Dispatch 分配)
    logic [$clog2(SB_DEPTH)-1:0] head_ptr; 
    logic [$clog2(SB_DEPTH)-1:0] tail_ptr; 
    
    // 計數器
    logic [$clog2(SB_DEPTH):0] count;
    
    // --- 輔助信號：計算已提交的條目數量 ---
    logic [$clog2(SB_DEPTH):0] committed_count;
    always_comb begin
        committed_count = 0;
        for(int i=0; i<SB_DEPTH; i++) begin
            if (mem[i].valid && mem[i].committed) begin
                committed_count++;
            end
        end
    end

    // --- 分配接口邏輯 ---
    assign alloc_gnt_o = (count < SB_DEPTH);
    assign alloc_id_o  = tail_ptr;

    // =======================================================
    // Main Sequential Logic
    // =======================================================
    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            head_ptr <= '0;
            tail_ptr <= '0;
            count    <= '0;
            for(int i=0; i<SB_DEPTH; i++) begin
                mem[i].valid      <= 1'b0;
                mem[i].committed  <= 1'b0;
                mem[i].addr_valid <= 1'b0;
                mem[i].data_valid <= 1'b0;
                mem[i].addr       <= '0;
                mem[i].data       <= '0;
                mem[i].op         <= decode_pkg::LSU_LW;
            end
        end else if (flush_i) begin
            // 【Flush 處理關鍵邏輯】
            // 1. 保留所有 committed=1 的條目 (它們是架構狀態的一部分，必須寫入內存)
            // 2. 清除所有 committed=0 的條目 (它們是錯誤路徑上的指令)
            
            // 重建 tail_ptr: 它應該緊跟在最後一個 committed 條目之後
            // 在環形緩衝區中，這等於 head_ptr + committed_count
            tail_ptr <= head_ptr + ($clog2(SB_DEPTH))'(committed_count);
            
            // 重置計數
            count    <= committed_count;

            // 清除無效條目
            for(int i=0; i<SB_DEPTH; i++) begin
                if (mem[i].valid && !mem[i].committed) begin
                    mem[i].valid      <= 1'b0;
                    mem[i].addr_valid <= 1'b0;
                    mem[i].data_valid <= 1'b0;
                end
            end
        end else begin
            
            // ------------------------------------
            // 1. Execute Write (亂序寫入)
            // ------------------------------------
            if (ex_valid_i) begin
                mem[ex_sb_id_i].addr       <= ex_addr_i;
                mem[ex_sb_id_i].data       <= ex_data_i;
                mem[ex_sb_id_i].op         <= ex_op_i;
                mem[ex_sb_id_i].addr_valid <= 1'b1;
                mem[ex_sb_id_i].data_valid <= 1'b1;
            end

            // ------------------------------------
            // 2. Allocation (入隊)
            // ------------------------------------
            // 只有在未發生 Flush 時才允許分配，避免舊指令污染
            if (alloc_req_i && alloc_gnt_o) begin
                mem[tail_ptr].valid      <= 1'b1;
                mem[tail_ptr].committed  <= 1'b0; // 默認為推測狀態
                mem[tail_ptr].addr_valid <= 1'b0;
                mem[tail_ptr].data_valid <= 1'b0;
                // 移動指針
                tail_ptr <= tail_ptr + 1;
                count    <= count + 1;
            end

            // ------------------------------------
            // 3. Commit (ROB 通知退休)
            // ------------------------------------
            // 標記為架構狀態，ROB 此時已將指令移除
            if (commit_valid_i) begin
                mem[commit_sb_id_i].committed <= 1'b1;
            end

            // ------------------------------------
            // 4. D-Cache Writeback (出隊)
            // ------------------------------------
            // 條件：隊頭有效 + 已退休 + 地址數據都就緒 + Cache 準備好
            if (mem[head_ptr].valid && mem[head_ptr].committed && 
                mem[head_ptr].addr_valid && mem[head_ptr].data_valid && 
                dcache_req_ready_i) begin
                
                mem[head_ptr].valid     <= 1'b0; // 真正釋放 SB 空間
                mem[head_ptr].committed <= 1'b0;
                mem[head_ptr].addr_valid<= 1'b0;
                mem[head_ptr].data_valid<= 1'b0;
                
                head_ptr <= head_ptr + 1;
                count    <= count - 1;
            end
        end
    end

    // =======================================================
    // Output Logic: D-Cache Request
    // =======================================================
    assign dcache_req_valid_o = mem[head_ptr].valid && 
                                mem[head_ptr].committed && 
                                mem[head_ptr].addr_valid && 
                                mem[head_ptr].data_valid;
                                
    assign dcache_req_addr_o  = mem[head_ptr].addr;
    assign dcache_req_data_o  = mem[head_ptr].data;
    assign dcache_req_op_o    = mem[head_ptr].op;

    // =======================================================
    // Store-to-Load Forwarding Logic
    // =======================================================
    // 策略：從最新分配的條目 (tail-1) 開始向舊條目 (head) 搜索。
    // 找到的第一個地址匹配且有效的 Store 即為正確的數據來源。
    
    always_comb begin
        load_hit_o  = 1'b0;
        load_data_o = '0;
        
        // 遍歷整個 SB (邏輯上從 tail-1 到 head)
        for (int i = 0; i < SB_DEPTH; i++) begin
            // 計算當前檢查的索引 (回繞處理)
            // 邏輯順序：tail-1, tail-2, ..., head
            logic [$clog2(SB_DEPTH)-1:0] idx;
            idx = tail_ptr - 1 - i[$clog2(SB_DEPTH)-1:0]; 

            // 檢查條件：
            // 1. 條目有效 (可能是 Speculative 也可能是 Committed)
            // 2. 地址匹配
            // 3. 數據已就緒 (如果不就緒但地址匹配，真實硬件通常會 stall load，這裡簡化為不命中)
            if (mem[idx].valid && 
                mem[idx].addr_valid && 
                mem[idx].data_valid && 
                (mem[idx].addr == load_addr_i)) begin
                
                load_hit_o  = 1'b1;
                load_data_o = mem[idx].data;
                
                // 找到最年輕的匹配項後立即停止搜索
                break; 
            end
        end
    end

endmodule