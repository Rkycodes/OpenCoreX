module opencorex_reset_tb;

    localparam int MAX_CYCLES = 100;
    localparam int TARGET_WAIT_CYCLES = 50;

    localparam logic [31:0] TARGET_ADDR = 32'h0000_000C;
    localparam logic [31:0] DONE_ADDR = 32'h0000_00BC;
    localparam logic [31:0] DONE_VALUE = 32'h524B_5943;

    logic clk;
    logic reset;

    logic [31:0] mem_addr;
    logic [31:0] mem_read_data;
    logic [31:0] mem_write_data;
    logic mem_read;
    logic mem_write;
    logic error;

    opencorex_core dut (
        .clk(clk),
        .reset(reset),
        .mem_read_data(mem_read_data),
        .mem_addr(mem_addr),
        .mem_write_data(mem_write_data),
        .mem_read(mem_read),
        .mem_write(mem_write),
        .error(error)
    );

    memory #(
        .WORDS(1024),
        .INIT_FILE("programs/hex/reset_during_execution.hex")
    ) test_memory (
        .clk(clk),
        .read_enable(mem_read),
        .write_enable(mem_write),
        .address(mem_addr),
        .write_data(mem_write_data),
        .read_data(mem_read_data)
    );

    task automatic check_register (
        input int unsigned register_index,
        input logic [31:0] expected,
        input string test_name
    );
        logic [31:0] actual;

        begin
            actual = dut.datapath_inst
                        .register_file_inst
                        .registers[register_index];

            if (actual !== expected) begin
                $fatal(
                    1,
                    "FAIL: %s | x%0d=%08h expected=%08h",
                    test_name,
                    register_index,
                    actual,
                    expected
                );
            end

            $display(
                "PASS: %s | x%0d=%08h",
                test_name,
                register_index,
                actual
            );
        end
    endtask

    initial begin
        clk = 1'b0;
        forever #5 clk = ~clk;
    end

    initial begin
        $dumpfile("opencorex_reset_tb.vcd");
        $dumpvars(0, opencorex_reset_tb);
    end

    initial begin : run_test
        bit saw_target;

        reset = 1'b1;
        saw_target = 1'b0;

        repeat (2) @(posedge clk);

        @(negedge clk);
        reset = 1'b0;

        // Wait for the ADD at address 0x0C to be fetched.
        for (int cycle = 0;
             cycle < TARGET_WAIT_CYCLES;
             cycle++) begin

            @(posedge clk);

            if (error !== 1'b0) begin
                $fatal(
                    1,
                    "FAIL: core entered ERROR before reset test"
                );
            end

            if (mem_read && mem_addr == TARGET_ADDR) begin
                saw_target = 1'b1;
                break;
            end
        end

        if (!saw_target) begin
            $fatal(
                1,
                "FAIL: ADD at address %08h was never fetched",
                TARGET_ADDR
            );
        end

        // FETCH_CAPTURE completes on the first edge.
        // DECODE completes on the second edge, entering R_EXEC.
        @(posedge clk);
        @(posedge clk);

        // Assert reset between active clock edges while ADD is in flight.
        #1;
        reset = 1'b1;

        // Allow asynchronous reset assignments to settle.
        #1;

        if (mem_addr !== 32'h0000_0000) begin
            $fatal(
                1,
                "FAIL: reset did not restore fetch address | actual=%08h",
                mem_addr
            );
        end

        if (error !== 1'b0) begin
            $fatal(
                1,
                "FAIL: error asserted during reset"
            );
        end

        check_register(
            3,
            32'd99,
            "in-flight ADD did not write back"
        );

        $display(
            "PASS: asynchronous reset restored address zero before another clock edge"
        );

        // Hold reset, then release it away from an active edge.
        repeat (2) @(posedge clk);

        @(negedge clk);
        reset = 1'b0;

        // Verify that execution restarts and completes normally.
        for (int cycle = 0; cycle < MAX_CYCLES; cycle++) begin
            @(posedge clk);

            if (error !== 1'b0) begin
                $fatal(
                    1,
                    "FAIL: core entered ERROR after restart at cycle %0d",
                    cycle
                );
            end

            if (mem_read && mem_write) begin
                $fatal(
                    1,
                    "FAIL: simultaneous memory read and write"
                );
            end

            if ((mem_read || mem_write) &&
                mem_addr[1:0] != 2'b00) begin
                $fatal(
                    1,
                    "FAIL: misaligned memory access at address %08h",
                    mem_addr
                );
            end

            if (mem_write && mem_addr == DONE_ADDR) begin
                if (mem_write_data !== DONE_VALUE) begin
                    $fatal(
                        1,
                        "FAIL: incorrect completion value | actual=%08h expected=%08h",
                        mem_write_data,
                        DONE_VALUE
                    );
                end

                @(negedge clk);

                check_register(1,  32'd5,      "restart writes x1");
                check_register(2,  32'd7,      "restart writes x2");
                check_register(3,  32'd12,     "restarted ADD completes");
                check_register(31, DONE_VALUE, "signature reloads after restart");

                if (test_memory.mem[32] !== 32'd12) begin
                    $fatal(
                        1,
                        "FAIL: restarted store | actual=%08h expected=%08h",
                        test_memory.mem[32],
                        32'd12
                    );
                end

                $display(
                    "PASS: reset test restarted and completed at cycle %0d",
                    cycle
                );

                $finish;
            end
        end

        $fatal(
            1,
            "FAIL: timeout after reset restart"
        );
    end

endmodule
