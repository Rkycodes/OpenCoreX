module pim_controller_tb;
    import pim_pkg::*;
    localparam int BW = 2;
    logic clk = 0;
    always #5 clk <= ~clk;
    logic reset, cmd_start, busy, done_set, error_set;
    pim_descriptor_t cmd_descriptor, validator_descriptor;
    logic [31:0] cmd_word, validator_command_word;
    pim_error_t error_code, validator_error_code;
    logic validator_start, validator_busy, validator_result_valid, validator_result_ok;
    logic buffer_begin_vector, buffer_query_valid, buffer_read_enable, buffer_write_enable;
    logic [31:0] buffer_new_vector_base, buffer_new_vector_length;
    logic [0:0] buffer_query_index, buffer_read_index, buffer_write_index;
    logic [31:0] buffer_read_data, buffer_write_data;
    logic mac_start, mac_busy, mac_done;
    logic [31:0] mac_operand_a, mac_operand_b, mac_accumulator_in, mac_result;
    logic mem_req_valid, mem_req_ready, mem_req_write, mem_rsp_valid;
    logic [31:0] mem_req_addr, mem_req_wdata, mem_rsp_rdata;

    pim_controller #(.BUFFER_WORDS(BW)) dut (.*);
    logic [31:0] vector_words [0:1];
    logic [1:0] valid_bits;
    logic [31:0] resident_base, resident_length;
    logic [31:0] ram [0:127];
    logic [31:0] pending_data;
    int response_delay, cycle_count, reads, vector_reads, writes, begins, starts;
    int pending;
    logic [31:0] mac_a_q, mac_b_q, mac_acc_q;
    int mac_delay;
    logic reject_next;
    int validator_delay;
    logic [31:0] held_addr, held_data;
    logic held_write, held;
    logic [31:0] snapshot_word;
    pim_descriptor_t snapshot_descriptor;

    assign buffer_query_valid = valid_bits[buffer_query_index];
    assign mem_req_ready = (cycle_count[1:0] == 2'd3);
    assign validator_busy = validator_delay != 0;
    assign mac_busy = mac_delay != 0;

    always @(posedge clk or posedge reset) begin
        if (reset) begin
            valid_bits <= '0;
            resident_base <= 0;
            resident_length <= 0;
            buffer_read_data <= 0;
            mem_rsp_valid <= 0;
            pending <= 0;
            pending_data <= 0;
            response_delay <= 0;
            cycle_count <= 0;
            reads <= 0;
            vector_reads <= 0;
            writes <= 0;
            begins <= 0;
            starts <= 0;
            validator_delay <= 0;
            validator_result_valid <= 0;
            validator_result_ok <= 0;
            validator_error_code <= PIM_ERROR_INVALID_VECTOR_LENGTH;
            mac_delay <= 0;
            mac_done <= 0;
            mac_result <= 0;
            mac_a_q <= 0;
            mac_b_q <= 0;
            mac_acc_q <= 0;
            held <= 0;
            held_addr <= 0;
            held_data <= 0;
            held_write <= 0;
            mem_rsp_rdata <= 0;
        end else begin
            cycle_count <= cycle_count + 1;
            mem_rsp_valid <= 0;
            validator_result_valid <= 0;
            mac_done <= 0;
            if (held && (!mem_req_valid || mem_req_addr !== held_addr
                         || mem_req_write !== held_write || mem_req_wdata !== held_data))
                $fatal(1, "stalled request changed");
            held <= mem_req_valid && !mem_req_ready;
            if (mem_req_valid && !mem_req_ready) begin
                held_addr <= mem_req_addr;
                held_data <= mem_req_wdata;
                held_write <= mem_req_write;
            end
            if (validator_start) begin
                if (validator_busy) $fatal(1, "validator restarted while busy");
                if (validator_descriptor !== snapshot_descriptor ||
                    validator_command_word !== snapshot_word)
                    $fatal(1, "command snapshot changed");
                starts <= starts + 1;
                validator_delay <= 3;
            end else if (validator_delay > 0) begin
                validator_delay <= validator_delay - 1;
                if (validator_delay == 1) begin
                    validator_result_valid <= 1;
                    validator_result_ok <= !reject_next;
                end
            end
            if (buffer_begin_vector) begin
                valid_bits <= 0;
                resident_base <= buffer_new_vector_base;
                resident_length <= buffer_new_vector_length;
                begins <= begins + 1;
            end
            if (buffer_read_enable) begin
                if (!valid_bits[buffer_read_index]) $fatal(1, "invalid resident read");
                buffer_read_data <= vector_words[buffer_read_index];
            end
            if (buffer_write_enable) begin
                if (!mem_rsp_valid) $fatal(1, "buffer write without response");
                valid_bits[buffer_write_index] <= 1;
                vector_words[buffer_write_index] <= buffer_write_data;
            end
            if (mem_req_valid && mem_req_ready) begin
                if (mem_req_write) begin
                    if (pending != 0) $fatal(1, "write while read outstanding");
                    ram[mem_req_addr >> 2] <= mem_req_wdata;
                    writes <= writes + 1;
                end else begin
                    if (pending != 0) $fatal(1, "multiple reads outstanding");
                    pending <= 1;
                    pending_data <= ram[mem_req_addr >> 2];
                    response_delay <= 2 + (reads & 3);
                    reads <= reads + 1;
                    if (mem_req_addr < 32'd8) vector_reads <= vector_reads + 1;
                end
            end
            if (pending != 0) begin
                if (response_delay == 0) begin
                    mem_rsp_valid <= 1;
                    mem_rsp_rdata <= pending_data;
                    pending <= 0;
                end else response_delay <= response_delay - 1;
            end
            if (mac_start) begin
                if (mac_busy) $fatal(1, "MAC restarted while busy");
                mac_a_q <= mac_operand_a;
                mac_b_q <= mac_operand_b;
                mac_acc_q <= mac_accumulator_in;
                mac_delay <= 3;
            end else if (mac_delay > 0) begin
                mac_delay <= mac_delay - 1;
                if (mac_delay == 1) begin
                    mac_result <= mac_acc_q + mac_a_q * mac_b_q;
                    mac_done <= 1;
                end
            end
        end
    end

    task automatic launch(input logic [31:0] word);
        @(negedge clk);
        cmd_word = word;
        cmd_start = 1;
        snapshot_word = word;
        snapshot_descriptor = cmd_descriptor;
        @(posedge clk);
        #1;
        if (!busy || validator_start !== 1'b1)
            $fatal(1, "busy/start timing");
        @(negedge clk);
        cmd_start = 0;
        cmd_word = 0;
        cmd_descriptor = '0;
    endtask

    task automatic await_done(input int expected_writes);
        int watchdog;
        watchdog = 0;
        while (!done_set) begin
            @(negedge clk);
            watchdog++;
            if (watchdog > 500) $fatal(1, "completion timeout");
            if (writes < expected_writes && !busy)
                $fatal(1, "busy released before final write");
        end
        if (writes != expected_writes || busy) $fatal(1, "final write timing");
        @(negedge clk);
        if (done_set) $fatal(1, "done pulse too long");
    endtask

    initial begin
        reset = 1;
        cmd_start = 0;
        cmd_descriptor = '0;
        cmd_word = 0;
        reject_next = 0;
        ram[0] = 32'd3;
        ram[1] = 32'd5;
        ram[16] = 32'd7;
        ram[17] = 32'd11;
        ram[18] = 32'd13;
        ram[19] = 32'd17;
        repeat (2) @(negedge clk);
        reset = 0;
        cmd_descriptor = '{vector_base:0, vector_length:2, matrix_base:64,
                           matrix_column_stride:8, output_base:128, output_count:2};
        reject_next = 1;
        launch(32'd1);
        wait (error_set);
        if (error_code != PIM_ERROR_INVALID_VECTOR_LENGTH || busy ||
            reads != 0 || writes != 0 || begins != 0)
            $fatal(1, "validation rejection side effect");
        @(negedge clk);
        reject_next = 0;
        cmd_descriptor = snapshot_descriptor;
        launch(32'd1);
        await_done(2);
        if (ram[32] != 32'd76 || ram[33] != 32'd124 ||
            vector_reads != 2 || begins != 1 || valid_bits != 2'b11 || resident_base != 0 || resident_length != 2)
            $fatal(1, "cold fill result");
        cmd_descriptor = snapshot_descriptor;
        launch(32'd3);
        await_done(4);
        if (ram[32] != 32'd76 || ram[33] != 32'd124 ||
            vector_reads != 2 || begins != 1 || reads != 10)
            $fatal(1, "warm reuse result");
        // Abort a stalled/new command. A late response must not restart it.
        cmd_descriptor = snapshot_descriptor;
        launch(32'd1);
        repeat (12) @(negedge clk);
        reset = 1;
        #1;
        if (busy || mem_req_valid || buffer_write_enable || done_set)
            $fatal(1, "reset did not abort");
        @(negedge clk);
        reset = 0;
        mem_rsp_valid = 1;
        mem_rsp_rdata = 32'hdeadbeef;
        @(negedge clk);
        mem_rsp_valid = 0;
        repeat (3) @(negedge clk);
        if (busy || mem_req_valid || done_set) $fatal(1, "late response revived command");
        // Exercise reset at validation, a stalled read, an outstanding read,
        // MAC execution, and an output-write stall.
        for (int phase = 0; phase < 5; phase++) begin
            cmd_descriptor = '{vector_base:0, vector_length:2, matrix_base:64,
                               matrix_column_stride:8, output_base:128, output_count:2};
            launch(32'd1);
            case (phase)
                0: wait (validator_busy);
                1: wait (mem_req_valid && !mem_req_write && !mem_req_ready);
                2: wait (pending != 0);
                3: wait (mac_busy);
                4: wait (mem_req_valid && mem_req_write && !mem_req_ready);
            endcase
            reset = 1;
            #1;
            if (busy || mem_req_valid || buffer_write_enable || done_set)
                $fatal(1, "reset failed in active phase %0d", phase);
            @(negedge clk);
            reset = 0;
            repeat (2) @(negedge clk);
            if (busy || mem_req_valid || done_set)
                $fatal(1, "aborted command resumed in phase %0d", phase);
        end        $display("PASS: pim_controller_tb");
        $finish;
    end
endmodule
