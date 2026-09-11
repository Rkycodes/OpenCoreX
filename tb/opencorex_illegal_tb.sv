module opencorex_illegal_tb;

    localparam int MAX_WAIT_CYCLES = 40;
    localparam int STICKY_CHECK_CYCLES = 5;

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
        .INIT_FILE("programs/hex/illegal_instruction.hex")
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
        bit saw_error;
        logic [31:0] frozen_mem_addr;

        reset = 1'b1;
        saw_error = 1'b0;
        frozen_mem_addr = 32'b0;

        repeat (2) @(posedge clk);

        @(negedge clk);
        reset = 1'b0;

        // Wait for the illegal instruction to enter ERROR.
        for (int cycle = 0; cycle < MAX_WAIT_CYCLES; cycle++) begin
            @(negedge clk);

            if (error === 1'b1) begin
                saw_error = 1'b1;
                frozen_mem_addr = mem_addr;

                $display(
                    "PASS: illegal instruction entered ERROR at cycle %0d",
                    cycle
                );

                break;
            end

            if (error !== 1'b0) begin
                $fatal(
                    1,
                    "FAIL: error has unknown value at cycle %0d",
                    cycle
                );
            end
        end

        if (!saw_error) begin
            $fatal(
                1,
                "FAIL: illegal instruction did not enter ERROR within %0d cycles",
                MAX_WAIT_CYCLES
            );
        end

        // Verify instructions before the illegal instruction completed.
        check_register(
            1,
            32'd42,
            "state before illegal instruction is preserved"
        );

        check_register(
            2,
            32'd17,
            "second register write before ERROR"
        );

        if (test_memory.mem[33] !== 32'd17) begin
            $fatal(
                1,
                "FAIL: memory changed unexpectedly | actual=%08h expected=%08h",
                test_memory.mem[33],
                32'd17
            );
        end

        $display(
            "PASS: pre-error memory value preserved | memory[33]=%08h",
            test_memory.mem[33]
        );

        // Verify ERROR remains sticky and blocks external activity.
        repeat (STICKY_CHECK_CYCLES) begin
            @(negedge clk);

            if (error !== 1'b1) begin
                $fatal(
                    1,
                    "FAIL: ERROR state was not sticky"
                );
            end

            if (mem_read !== 1'b0 || mem_write !== 1'b0) begin
                $fatal(
                    1,
                    "FAIL: memory activity occurred in ERROR | read=%b write=%b",
                    mem_read,
                    mem_write
                );
            end

            if (mem_addr !== frozen_mem_addr) begin
                $fatal(
                    1,
                    "FAIL: PC-derived memory address changed in ERROR | actual=%08h expected=%08h",
                    mem_addr,
                    frozen_mem_addr
                );
            end

            if (dut.datapath_inst
                   .register_file_inst
                   .registers[1] !== 32'd42) begin
                $fatal(
                    1,
                    "FAIL: x1 changed while ERROR was active"
                );
            end

            if (test_memory.mem[33] !== 32'd17) begin
                $fatal(
                    1,
                    "FAIL: memory changed while ERROR was active"
                );
            end
        end

        $display(
            "PASS: ERROR remained sticky for %0d cycles",
            STICKY_CHECK_CYCLES
        );

        $display(
            "PASS: illegal instruction produced no architectural side effects"
        );

        $finish;
    end

endmodule
