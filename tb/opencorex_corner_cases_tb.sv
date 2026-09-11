module opencorex_corner_cases_tb;

    localparam int MAX_CYCLES = 200;
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
        .INIT_FILE("programs/hex/integration_corner_cases.hex")
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

        initial begin : run_test
        reset = 1'b1;

        // Hold reset through two active clock edges.
        repeat (2) @(posedge clk);

        // Release reset away from the active edge.
        @(negedge clk);
        reset = 1'b0;

        for (int cycle = 0; cycle < MAX_CYCLES; cycle++) begin
            // Sample the transaction accepted by memory on this edge.
            @(posedge clk);

            if (error !== 1'b0) begin
                $fatal(
                    1,
                    "FAIL: core entered ERROR state at cycle %0d",
                    cycle
                );
            end

            if (mem_read && mem_write) begin
                $fatal(
                    1,
                    "FAIL: mem_read and mem_write asserted together at cycle %0d",
                    cycle
                );
            end

            if ((mem_read || mem_write) &&
                (mem_addr[1:0] != 2'b00)) begin
                $fatal(
                    1,
                    "FAIL: misaligned memory access at cycle %0d address=%08h",
                    cycle,
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

                // Allow the synchronous memory write to commit.
                @(negedge clk);

                check_register(
                    1,
                    32'hFFFF_FFFB,
                    "negative ADDI immediate"
                );

                check_register(
                    2,
                    32'd3,
                    "positive ADDI operand"
                );

                check_register(
                    3,
                    32'hFFFF_FFFE,
                    "negative ADD result"
                );

                check_register(
                    4,
                    32'hFFFF_FFF8,
                    "negative SUB result"
                );

                check_register(
                    5,
                    32'd7,
                    "write to x0 is ignored"
                );

                check_register(
                    6,
                    32'd23,
                    "not-taken BEQ executes fall-through"
                );

                check_register(
                    7,
                    32'd2,
                    "backward BEQ executes once"
                );

                check_register(
                    8,
                    32'd1,
                    "backward BEQ comparison value"
                );

                check_register(
                    13,
                    32'd2,
                    "backward JAL executes once"
                );

                check_register(
                    14,
                    32'd2,
                    "backward JAL loop limit"
                );

                check_register(
                    31,
                    DONE_VALUE,
                    "completion signature load"
                );


                $display(
                    "PASS: legal corner-case integration test completed at cycle %0d",
                    cycle
                );

                $finish;
            end
        end

        $fatal(
            1,
            "FAIL: timeout after %0d cycles without completion",
            MAX_CYCLES
        );
    end

endmodule
