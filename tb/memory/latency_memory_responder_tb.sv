module latency_memory_responder_tb;
    logic clk = 0;
    always #5 clk <= ~clk;
    logic reset = 1, req_valid = 0, req_write = 0, req_ready, rsp_valid;
    logic [31:0] req_addr = 0, req_wdata = 0, rsp_rdata;
    logic memory_read_enable, memory_write_enable;
    logic [31:0] memory_address, memory_write_data, memory_read_data;
    int read_delay = 1, fetch_delay = 1;
    bit is_fetch = 0;
    latency_memory_responder dut (.*);
    memory #(.WORDS(4)) ram (
        .clk, .read_enable(memory_read_enable), .write_enable(memory_write_enable),
        .address(memory_address), .write_data(memory_write_data), .read_data(memory_read_data)
    );

    task automatic read_then_stalled_write(input int latency);
        @(negedge clk);
        read_delay = latency;
        req_valid = 1; req_write = 0; req_addr = 0;
        @(posedge clk);
        if (!req_ready || !memory_read_enable) $fatal(1, "read not accepted");
        @(negedge clk);
        req_write = 1; req_addr = 4; req_wdata = 32'(latency);
        for (int elapsed = 1; elapsed <= latency; elapsed++) begin
            @(posedge clk);
            if (req_ready || memory_write_enable)
                $fatal(1, "accepted write while read outstanding");
            if (rsp_valid != (elapsed == latency))
                $fatal(1, "response deadline L=%0d elapsed=%0d", latency, elapsed);
            if (rsp_valid && rsp_rdata !== 32'h12345678)
                $fatal(1, "response data changed under stalled write");
        end
        @(posedge clk);
        if (!req_ready || !memory_write_enable || rsp_valid)
            $fatal(1, "stalled write not accepted after response");
        #1;
        if (ram.mem[1] !== 32'(latency)) $fatal(1, "write not committed at acceptance");
        @(negedge clk); req_valid = 0;
        @(posedge clk);
        if (rsp_valid) $fatal(1, "write produced a response");
    endtask

    initial begin
        repeat (2) @(posedge clk);
        @(negedge clk);
        ram.mem[0] = 32'h12345678; reset = 0;
        read_then_stalled_write(1);
        read_then_stalled_write(2);
        read_then_stalled_write(5);
        read_then_stalled_write(10);
        read_then_stalled_write(20);
        // Distinct fetch class must use fetch_delay, not data delay.
        @(negedge clk);
        is_fetch = 1; fetch_delay = 1; req_valid = 1; req_write = 0; req_addr = 0;
        @(posedge clk);
        if (!req_ready) $fatal(1, "fetch not accepted");
        @(negedge clk); req_valid = 0;
        @(posedge clk);
        if (!rsp_valid || rsp_rdata !== 32'h12345678) $fatal(1, "fixed fetch response");
        // Reset cancels an outstanding long data read.
        @(negedge clk); is_fetch = 0;
        @(posedge clk);
        @(negedge clk); req_valid = 1;
        @(posedge clk);
        if (!req_ready) $fatal(1, "reset-test read not accepted");
        @(negedge clk); req_valid = 0; reset = 1;
        @(posedge clk);
        @(negedge clk); reset = 0;
        repeat (22) begin
            @(posedge clk);
            if (rsp_valid) $fatal(1, "response survived reset");
        end
        $display("PASS: latency_memory_responder_tb (deadlines, write backpressure, fixed fetch, reset)");
        $finish;
    end
endmodule
