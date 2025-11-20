
flush
flush_npc

bpu_npc

ifu   ready
ifu   vaild

icahce ready 
icahce vaild
icahce data

state
next_state =    (state == idle) && ifu vaild && ifu ready ? wait
                (state == wait) && (icahce vaild == 0) && flush ? flush_state
                (state == wait) && (icahce vaild == 1) ? idle
                (state == flush_state) && (icahce vaild == 1) ? idle
ibuff
pc
always @(posedge clk) begin
    if(state == flush && next_state == idle) begin
        npc <= flush_npc
    end
    else if(state == wait && next_state == idle) begin
        if(flush == 0) {
            ibuff <= icahce data
            npc <= bpu_npc
        }
        else {
            npc <= flush_npc
        }
    end
    state = next_state
end