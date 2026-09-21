module synchronous_memory_adapter_tb;

    logic clk;
    logic reset;

    logic        req_valid;
    logic        req_ready;
    logic        req_write;
    logic [31:0] req_addr;
    logic [31:0] req_wdata;

    logic        rsp_valid;
    logic [31:0] rsp_rdata;

    logic        memory_read_enable;
    logic        memory_write_enable;
    logic [31:0] memory_address;
    logic [31:0] memory_write_data;
    logic [31:0] memory_read_data;

    synchronous_memory_adapter adapter_dut (
        .clk                 (clk),
        .reset               (reset),

        .req_valid           (req_valid),
        .req_ready           (req_ready),
        .req_write           (req_write),
        .req_addr            (req_addr),
        .req_wdata           (req_wdata),

        .rsp_valid           (rsp_valid),
        .rsp_rdata           (rsp_rdata),

        .memory_read_enable  (memory_read_enable),
        .memory_write_enable (memory_write_enable),
        .memory_address      (memory_address),
        .memory_write_data   (memory_write_data),
        .memory_read_data    (memory_read_data)
    );

    memory #(
        .WORDS     (16),
        .INIT_FILE ("")
    ) memory_dut (
        .clk          (clk),
        .read_enable  (memory_read_enable),
        .write_enable (memory_write_enable),
        .address      (memory_address),
        .write_data   (memory_write_data),
        .read_data    (memory_read_data)
    );

    initial begin
        clk = 1'b0;
        forever #5 clk = ~clk;
    end

    task automatic check_bit (
        input logic  actual,
        input logic  expected,
        input string test_name
    );
        begin
            if (actual !== expected) begin
                $fatal(
                    1,
                    "FAIL: %s | actual=%0b expected=%0b",
                    test_name,
                    actual,
                    expected
                );
            end

            $display("PASS: %s | value=%0b", test_name, actual);
        end
    endtask

    task automatic check_word (
        input logic [31:0] actual,
        input logic [31:0] expected,
        input string       test_name
    );
        begin
            if (actual !== expected) begin
                $fatal(
                    1,
                    "FAIL: %s | actual=%08h expected=%08h",
                    test_name,
                    actual,
                    expected
                );
            end

            $display("PASS: %s | value=%08h", test_name, actual);
        end
    endtask

    task automatic drive_idle;
        begin
            req_valid = 1'b0;
            req_write = 1'b0;
            req_addr  = 32'b0;
            req_wdata = 32'b0;
        end
    endtask

    initial begin
        reset = 1'b1;
        drive_idle();
        #1;

        // ------------------------------------------------------------
        // Test 1: Reset blocks requests and clears response-valid state.
        // ------------------------------------------------------------
        req_valid = 1'b1;
        req_write = 1'b1;
        req_addr  = 32'h0000_0004;
        req_wdata = 32'hAAAA_1111;
        #1;

        check_bit(req_ready, 1'b0, "reset deasserts request ready");
        check_bit(memory_read_enable, 1'b0, "reset blocks memory read");
        check_bit(memory_write_enable, 1'b0, "reset blocks memory write");
        check_bit(rsp_valid, 1'b0, "reset clears response valid");

        // Hold reset across an edge, then release it away from a rising edge.
        @(posedge clk);
        #1;
        @(negedge clk);
        reset = 1'b0;
        drive_idle();
        #1;

        // ------------------------------------------------------------
        // Test 2: Idle memory advertises readiness without a request.
        // ------------------------------------------------------------
        check_bit(req_ready, 1'b1, "idle adapter advertises ready");
        check_bit(memory_read_enable, 1'b0, "idle adapter does not read");
        check_bit(memory_write_enable, 1'b0, "idle adapter does not write");

        // ------------------------------------------------------------
        // Test 3: An accepted write modifies memory and creates no response.
        // ------------------------------------------------------------
        req_valid = 1'b1;
        req_write = 1'b1;
        req_addr  = 32'h0000_0004;
        req_wdata = 32'h1234_5678;
        #1;

        check_bit(req_ready, 1'b1, "write request is ready");
        check_bit(memory_read_enable, 1'b0, "write does not assert read enable");
        check_bit(memory_write_enable, 1'b1, "accepted write asserts write enable");
        check_word(memory_address, 32'h0000_0004, "write address is forwarded");
        check_word(memory_write_data, 32'h1234_5678, "write data is forwarded");

        @(posedge clk);
        #1;

        check_word(memory_dut.mem[1], 32'h1234_5678, "accepted write updates memory word");
        check_bit(rsp_valid, 1'b0, "write produces no read response");

        @(negedge clk);
        drive_idle();
        #1;

        // ------------------------------------------------------------
        // Test 4: An accepted read returns data during the next cycle.
        // ------------------------------------------------------------
        req_valid = 1'b1;
        req_write = 1'b0;
        req_addr  = 32'h0000_0004;
        #1;

        check_bit(memory_read_enable, 1'b1, "accepted read asserts read enable");
        check_bit(memory_write_enable, 1'b0, "read does not assert write enable");
        check_bit(rsp_valid, 1'b0, "response is not early");

        @(posedge clk);
        #1;

        check_bit(rsp_valid, 1'b1, "read response is valid after accepting edge");
        check_word(rsp_rdata, 32'h1234_5678, "read response contains memory data");

        // Stop issuing reads. rsp_valid clears on the following edge.
        @(negedge clk);
        drive_idle();
        @(posedge clk);
        #1;

        check_bit(rsp_valid, 1'b0, "response valid clears without another read");

        // ------------------------------------------------------------
        // Test 5: A read response can overlap a new write request.
        // ------------------------------------------------------------
        @(negedge clk);
        req_valid = 1'b1;
        req_write = 1'b0;
        req_addr  = 32'h0000_0004;

        // Accept the read.
        @(posedge clk);
        #1;

        check_bit(rsp_valid, 1'b1, "overlap test read response is valid");
        check_word(rsp_rdata, 32'h1234_5678, "overlap test returns prior word");

        // Present a write while the registered read response is visible.
        @(negedge clk);
        req_valid = 1'b1;
        req_write = 1'b1;
        req_addr  = 32'h0000_0008;
        req_wdata = 32'hCAFE_BABE;
        #1;

        check_bit(rsp_valid, 1'b1, "previous read response overlaps write request");
        check_bit(memory_write_enable, 1'b1, "new write is accepted during response cycle");

        @(posedge clk);
        #1;

        check_word(memory_dut.mem[2], 32'hCAFE_BABE, "overlapping write updates memory");
        check_bit(rsp_valid, 1'b0, "write creates no following response");

        @(negedge clk);
        drive_idle();

        // ------------------------------------------------------------
        // Test 6: Back-to-back reads produce back-to-back responses.
        // ------------------------------------------------------------
        req_valid = 1'b1;
        req_write = 1'b0;
        req_addr  = 32'h0000_0004;

        @(posedge clk);
        #1;

        check_bit(rsp_valid, 1'b1, "first back-to-back response is valid");
        check_word(rsp_rdata, 32'h1234_5678, "first back-to-back response data");

        // Change the request address while presenting another valid read.
        // The first read has already handshaken, so a new payload is legal.
        @(negedge clk);
        req_addr = 32'h0000_0008;

        @(posedge clk);
        #1;

        check_bit(rsp_valid, 1'b1, "second back-to-back response is valid");
        check_word(rsp_rdata, 32'hCAFE_BABE, "second back-to-back response data");

        @(negedge clk);
        drive_idle();

        // ------------------------------------------------------------
        // Test 7: Reset suppresses responses but preserves RAM contents.
        // ------------------------------------------------------------
        reset = 1'b1;
        #1;

        check_bit(req_ready, 1'b0, "reset blocks new transactions");
        check_bit(rsp_valid, 1'b0, "reset suppresses response valid");
        check_word(memory_dut.mem[1], 32'h1234_5678, "reset preserves first memory word");
        check_word(memory_dut.mem[2], 32'hCAFE_BABE, "reset preserves second memory word");

        $display("All synchronous memory adapter tests passed.");
        $finish;
    end

endmodule
