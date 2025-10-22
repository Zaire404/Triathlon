import config_pkg::*;
import global_config_pkg::*;

module icache #(
    parameter config_pkg::cfg_t Cfg = config_pkg::EmptyCfg
) (
    input logic clk_i,
    input logic rst_ni,

    // IFU Interface
    input  global_config_pkg::ifu2icache_req_t ifu_req_i,
    output global_config_pkg::icache2ifu_rsp_t ifu_rsp_o,

    //FTQ Interface
    input  global_config_pkg::ftq2icache_req_t ftq_req_i,
    output global_config_pkg::icache2ftq_rsp_t ftq_rsp_o

);


endmodule : icache
