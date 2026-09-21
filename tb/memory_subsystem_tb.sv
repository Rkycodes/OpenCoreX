module memory_subsystem_tb;

    logic clk;
    logic reset;

    // CPU-side request and response channels.
    logic        cpu_req_valid;
    logic        cpu_req_ready;
    logic        cpu_req_write;
    logic [31:0] cpu_req_addr;
    logic [31:0] cpu_req_wdata;
    logic        cpu_rsp_valid;
    logic [31:0] cpu_rsp_rdata;

    // PIM-side request and response channels.
    logic        pim_req_valid;
    logic        pim_req_ready;
    logic        pim_req_write;
    logic [31:0] pim_req_addr;
    logic [31:0] pim_req_wdata;
    logic        pim_rsp_valid;
    logic [31:0] pim_rsp_rdata;

    // Interconnect-to-adapter request and response channels.
    logic        mem_req_valid;
    logic        mem_req_ready;
    logic        mem_req_write;
    logic [31:0] mem_req_addr;
    logic [31:0] mem_req_wdata;
    logic        mem_rsp_valid;
    logic [31:0] mem_rsp_rdata;

    // Adapter-to-existing-memory signals.
    logic        memory_read_enable;
    logic        memory_write_enable;
    logic [31:0] memory_address;
    logic [31:0] memory_write_data;
    logic [31:0] memory_read_data;

    memory_interconnect interconnect_dut (
        .clk            (clk),
        .reset          (reset),

        .cpu_req_valid  (cpu_req_valid),
        .cpu_req_ready  (cpu_req_ready),
        .cpu_req_write  (cpu_req_write),
        .cpu_req_addr   (cpu_req_addr),
        .cpu_req_wdata  (cpu_req_wdata),
        .cpu_rsp_valid  (cpu_rsp_valid),
        .cpu_rsp_rdata  (cpu_rsp_rdata),

        .pim_req_valid  (pim_req_valid),
        .pim_req_ready  (pim_req_ready),
        .pim_req_write  (pim_req_write),
        .pim_req_addr   (pim_req_addr),
        .pim_req_wdata  (pim_req_wdata),
        .pim_rsp_valid  (pim_rsp_valid),
        .pim_rsp_rdata  (pim_rsp_rdata),

        .mem_req_valid  (mem_req_valid),
        .mem_req_ready  (mem_req_ready),
        .mem_req_write  (mem_req_write),
        .mem_req_addr   (mem_req_addr),
        .mem_req_wdata  (mem_req_wdata),

        .mem_rsp_valid  (mem_rsp_valid),
        .mem_rsp_rdata  (mem_rsp_rdata)
    );

    synchronous_memory_adapter adapter_dut (
        .clk                 (clk),
        .reset               (reset),

        .req_valid           (mem_req_valid),
        .req_ready           (mem_req_ready),
        .req_write           (mem_req_write),
        .req_addr            (mem_req_addr),
        .req_wdata           (mem_req_wdata),

        .rsp_valid           (mem_rsp_valid),
        .rsp_rdata           (mem_rsp_rdata),

        .memory_read_enable  (memory_read_enable),
        .memory_write_enable (memory_write_enable),
        .memory_address      (memory_address),
        .memory_write_data   (memory_write_data),
        .memory_read_data    (memory_read_data)
    );

    memory #(
        .WORDS     (256),
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

    task automatic drive_cpu_idle;
        begin
            cpu_req_valid = 1'b0;
            cpu_req_write = 1'b0;
            cpu_req_addr  = 32'b0;
            cpu_req_wdata = 32'b0;
        end
    endtask

    task automatic drive_pim_idle;
        begin
            pim_req_valid = 1'b0;
            pim_req_write = 1'b0;
            pim_req_addr  = 32'b0;
            pim_req_wdata = 32'b0;
        end
    endtask

    initial begin
        reset = 1'b1;
        drive_cpu_idle();
        drive_pim_idle();
        #1;

        // ------------------------------------------------------------
        // Test 1: Reset suppresses all request and response activity.
        // ------------------------------------------------------------
        cpu_req_valid = 1'b1;
        cpu_req_write = 1'b1;
        cpu_req_addr  = 32'h0000_0040;
        cpu_req_wdata = 32'h1111_1111;

        pim_req_valid = 1'b1;
        pim_req_write = 1'b0;
        pim_req_addr  = 32'h0000_0080;
        #1;

        check_bit(cpu_req_ready, 1'b0, "reset blocks CPU acceptance");
        check_bit(pim_req_ready, 1'b0, "reset blocks PIM acceptance");
        check_bit(mem_req_valid, 1'b0, "reset blocks downstream request");
        check_bit(memory_read_enable, 1'b0, "reset blocks physical read");
        check_bit(memory_write_enable, 1'b0, "reset blocks physical write");
        check_bit(cpu_rsp_valid, 1'b0, "reset suppresses CPU response");
        check_bit(pim_rsp_valid, 1'b0, "reset suppresses PIM response");

        @(posedge clk);
        #1;
        @(negedge clk);
        reset = 1'b0;
        drive_cpu_idle();
        drive_pim_idle();
        #1;

        check_bit(mem_req_ready, 1'b1, "adapter is ready after reset");

        // ------------------------------------------------------------
        // Test 2: CPU write reaches physical memory and has no response.
        // ------------------------------------------------------------
        cpu_req_valid = 1'b1;
        cpu_req_write = 1'b1;
        cpu_req_addr  = 32'h0000_0040;
        cpu_req_wdata = 32'h1234_5678;
        #1;

        check_bit(cpu_req_ready, 1'b1, "CPU write is accepted");
        check_bit(pim_req_ready, 1'b0, "idle PIM is not accepted");
        check_bit(memory_write_enable, 1'b1, "CPU write reaches RAM enable");
        check_word(memory_address, 32'h0000_0040, "CPU write reaches RAM address");
        check_word(memory_write_data, 32'h1234_5678, "CPU write reaches RAM data");

        @(posedge clk);
        #1;

        // Retire the accepted request immediately after its handshake edge.
        drive_cpu_idle();
        check_word(memory_dut.mem[16], 32'h1234_5678, "CPU write updates RAM");
        check_bit(cpu_rsp_valid, 1'b0, "CPU write creates no CPU response");
        check_bit(pim_rsp_valid, 1'b0, "CPU write creates no PIM response");

        // ------------------------------------------------------------
        // Test 3: CPU reads back its stored word through the full path.
        // ------------------------------------------------------------
        @(negedge clk);
        cpu_req_valid = 1'b1;
        cpu_req_write = 1'b0;
        cpu_req_addr  = 32'h0000_0040;
        #1;

        check_bit(cpu_req_ready, 1'b1, "CPU read is accepted");
        check_bit(memory_read_enable, 1'b1, "CPU read reaches RAM enable");

        @(posedge clk);
        #1;

        drive_cpu_idle();
        check_bit(cpu_rsp_valid, 1'b1, "CPU receives read response");
        check_word(cpu_rsp_rdata, 32'h1234_5678, "CPU receives stored word");
        check_bit(pim_rsp_valid, 1'b0, "CPU response is not routed to PIM");

        @(posedge clk);
        #1;
        check_bit(cpu_rsp_valid, 1'b0, "CPU response clears after one cycle");

        // ------------------------------------------------------------
        // Test 4: PIM independently writes and reads another RAM word.
        // ------------------------------------------------------------
        @(negedge clk);
        pim_req_valid = 1'b1;
        pim_req_write = 1'b1;
        pim_req_addr  = 32'h0000_0080;
        pim_req_wdata = 32'hCAFE_BABE;
        #1;

        check_bit(pim_req_ready, 1'b1, "PIM write is accepted");
        check_bit(memory_write_enable, 1'b1, "PIM write reaches RAM enable");

        @(posedge clk);
        #1;

        drive_pim_idle();
        check_word(memory_dut.mem[32], 32'hCAFE_BABE, "PIM write updates RAM");
        check_bit(pim_rsp_valid, 1'b0, "PIM write creates no response");

        @(negedge clk);
        pim_req_valid = 1'b1;
        pim_req_write = 1'b0;
        pim_req_addr  = 32'h0000_0080;

        @(posedge clk);
        #1;

        drive_pim_idle();
        check_bit(pim_rsp_valid, 1'b1, "PIM receives read response");
        check_word(pim_rsp_rdata, 32'hCAFE_BABE, "PIM receives stored word");
        check_bit(cpu_rsp_valid, 1'b0, "PIM response is not routed to CPU");

        @(posedge clk);
        #1;
        check_bit(pim_rsp_valid, 1'b0, "PIM response clears after one cycle");

        // ------------------------------------------------------------
        // Test 5: Contested reads alternate and responses follow owners.
        // last_grant is PIM, so CPU must win the first contested request.
        // ------------------------------------------------------------
        @(negedge clk);
        cpu_req_valid = 1'b1;
        cpu_req_write = 1'b0;
        cpu_req_addr  = 32'h0000_0040;

        pim_req_valid = 1'b1;
        pim_req_write = 1'b0;
        pim_req_addr  = 32'h0000_0080;
        #1;

        check_bit(cpu_req_ready, 1'b1, "CPU wins first contested read");
        check_bit(pim_req_ready, 1'b0, "PIM waits during CPU contested read");
        check_word(memory_address, 32'h0000_0040, "CPU contested address reaches RAM");

        // CPU read fires here. PIM remains valid for the next grant.
        @(posedge clk);
        #1;

        drive_cpu_idle();
        #1;
        check_bit(cpu_rsp_valid, 1'b1, "first contested response returns to CPU");
        check_word(cpu_rsp_rdata, 32'h1234_5678, "CPU contested response data");
        check_bit(pim_req_ready, 1'b1, "PIM receives next contested grant");
        check_word(memory_address, 32'h0000_0080, "PIM address replaces CPU address");

        // PIM read fires here, back-to-back with the CPU read.
        @(posedge clk);
        #1;

        drive_pim_idle();
        check_bit(cpu_rsp_valid, 1'b0, "second response is not routed to CPU");
        check_bit(pim_rsp_valid, 1'b1, "second contested response returns to PIM");
        check_word(pim_rsp_rdata, 32'hCAFE_BABE, "PIM contested response data");

        @(posedge clk);
        #1;
        check_bit(pim_rsp_valid, 1'b0, "contested response sequence completes");

        // ------------------------------------------------------------
        // Test 6: A CPU write is visible to a following contested PIM read.
        // last_grant is PIM, so CPU again wins the first contested request.
        // ------------------------------------------------------------
        @(negedge clk);
        cpu_req_valid = 1'b1;
        cpu_req_write = 1'b1;
        cpu_req_addr  = 32'h0000_00C0;
        cpu_req_wdata = 32'hABCD_1234;

        pim_req_valid = 1'b1;
        pim_req_write = 1'b0;
        pim_req_addr  = 32'h0000_00C0;
        #1;

        check_bit(cpu_req_ready, 1'b1, "CPU write wins mixed contention");
        check_bit(pim_req_ready, 1'b0, "PIM read waits behind CPU write");
        check_bit(memory_write_enable, 1'b1, "contested CPU write reaches RAM");

        @(posedge clk);
        #1;

        drive_cpu_idle();
        #1;
        check_word(memory_dut.mem[48], 32'hABCD_1234, "contested CPU write commits");
        check_bit(cpu_rsp_valid, 1'b0, "contested write creates no response");
        check_bit(pim_req_ready, 1'b1, "waiting PIM read receives next grant");
        check_bit(memory_read_enable, 1'b1, "waiting PIM read reaches RAM");

        @(posedge clk);
        #1;

        drive_pim_idle();
        check_bit(pim_rsp_valid, 1'b1, "PIM receives response after CPU write");
        check_word(pim_rsp_rdata, 32'hABCD_1234, "PIM observes CPU-written value");

        // ------------------------------------------------------------
        // Test 7: Reset clears protocol state but preserves RAM contents.
        // ------------------------------------------------------------
        reset = 1'b1;
        #1;

        check_bit(cpu_req_ready, 1'b0, "final reset blocks CPU requests");
        check_bit(pim_req_ready, 1'b0, "final reset blocks PIM requests");
        check_bit(cpu_rsp_valid, 1'b0, "final reset suppresses CPU response");
        check_bit(pim_rsp_valid, 1'b0, "final reset suppresses PIM response");
        check_word(memory_dut.mem[16], 32'h1234_5678, "reset preserves CPU-written RAM word");
        check_word(memory_dut.mem[32], 32'hCAFE_BABE, "reset preserves PIM-written RAM word");
        check_word(memory_dut.mem[48], 32'hABCD_1234, "reset preserves shared RAM word");

        $display("All end-to-end memory subsystem tests passed.");
        $finish;
    end

endmodule
