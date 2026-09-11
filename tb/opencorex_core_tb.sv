module opencorex_core_tb;

    localparam int MAX_CYCLES = 150;
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
        .INIT_FILE("programs/hex/integration_smoke.hex")
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

                check_register(1,  32'd12,        "ADDI writes x1");
                check_register(2,  32'd10,        "ADDI writes x2");
                check_register(3,  32'd22,        "ADD result");
                check_register(4,  32'd2,         "SUB result");
                check_register(5,  32'd8,         "AND result");
                check_register(6,  32'd14,        "OR result");
                check_register(7,  32'd6,         "XOR result");
                check_register(8,  32'd11,        "ADDI with nonzero rs1");
                check_register(9,  32'd11,        "LW result");
                check_register(10, 32'd17,        "BEQ skips fall-through");
                check_register(11, 32'h0000_003C, "JAL link address");
                check_register(12, 32'd23,        "JAL skips fall-through");
                check_register(31, DONE_VALUE,    "completion signature load");

                if (test_memory.mem[32] !== 32'd11) begin
                    $fatal(
                        1,
                        "FAIL: stored result | actual=%08h expected=%08h",
                        test_memory.mem[32],
                        32'd11
                    );
                end

                $display(
                    "PASS: stored result | memory[32]=%08h",
                    test_memory.mem[32]
                );

                $display(
                    "PASS: integration smoke test completed at cycle %0d",
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
