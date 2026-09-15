module opencorex_dot_product_tb;

    localparam int MAX_CYCLES = 900;

    localparam logic [31:0] RESULT_ADDR     = 32'h0000_0180;
    localparam logic [31:0] EXPECTED_RESULT = 32'h0000_00CE;

    localparam logic [31:0] SIGNATURE_ADDR = 32'h0000_01A0;
    localparam logic [31:0] DONE_ADDR      = 32'h0000_01BC;
    localparam logic [31:0] DONE_VALUE     = 32'h524B_5943;

    localparam logic [31:0] VECTOR_A_START = 32'h0000_0100;
    localparam logic [31:0] VECTOR_A_END   = 32'h0000_013C;
    localparam logic [31:0] VECTOR_B_START = 32'h0000_0140;
    localparam logic [31:0] VECTOR_B_END   = 32'h0000_017C;
    logic clk;
    logic reset;

    logic [31:0] mem_addr;
    logic [31:0] mem_read_data;
    logic [31:0] mem_write_data;
    logic mem_read;
    logic mem_write;
    logic error;

    int unsigned instruction_fetches;
    int unsigned vector_a_reads;
    int unsigned vector_b_reads;
    int unsigned signature_reads;
    int unsigned result_writes;
    int unsigned completion_writes;

    int unsigned mul_fetches;
    int unsigned add_fetches;
    int unsigned bne_fetches;

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
        .INIT_FILE("programs/hex/dot_product_16.hex")
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

    task automatic check_count (
        input int unsigned actual,
        input int unsigned expected,
        input string test_name
    );
        begin
            if (actual != expected) begin
                $fatal(
                    1,
                    "FAIL: %s | actual=%0d expected=%0d",
                    test_name,
                    actual,
                    expected
                );
            end

            $display(
                "PASS: %s | count=%0d",
                test_name,
                actual
            );
        end
    endtask

    initial begin
        clk = 1'b0;
        forever #5 clk = ~clk;
    end

        initial begin : run_test
        instruction_fetches = 0;
        vector_a_reads = 0;
        vector_b_reads = 0;
        signature_reads = 0;
        result_writes = 0;
        completion_writes = 0;
        mul_fetches = 0;
        add_fetches = 0;
        bne_fetches = 0;
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

                        // Classify every accepted memory-read transaction.
            if (mem_read) begin
                // Program instructions occupy byte addresses 0x00 through 0x3C.
                if (mem_addr <= 32'h0000_003C) begin
                    instruction_fetches++;

                    // Count benchmark operations by their fixed instruction addresses.
                    case (mem_addr)
                        32'h0000_0018: mul_fetches++;
                        32'h0000_001C: add_fetches++;
                        32'h0000_002C: bne_fetches++;
                        default: begin
                            // Other legal instruction fetches need no individual count.
                        end
                    endcase
                end
                else if ((mem_addr >= VECTOR_A_START) &&
                        (mem_addr <= VECTOR_A_END)) begin
                    vector_a_reads++;
                end
                else if ((mem_addr >= VECTOR_B_START) &&
                        (mem_addr <= VECTOR_B_END)) begin
                    vector_b_reads++;
                end
                else if (mem_addr == SIGNATURE_ADDR) begin
                    signature_reads++;
                end
                else begin
                    $fatal(
                        1,
                        "FAIL: unexpected memory read at cycle %0d address=%08h",
                        cycle,
                        mem_addr
                    );
                end
            end

            // Classify every accepted memory-write transaction.
            if (mem_write) begin
                case (mem_addr)
                    RESULT_ADDR: begin
                        result_writes++;

                        if (mem_write_data !== EXPECTED_RESULT) begin
                            $fatal(
                                1,
                                "FAIL: incorrect result store | actual=%08h expected=%08h",
                                mem_write_data,
                                EXPECTED_RESULT
                            );
                        end
                    end

                    DONE_ADDR: begin
                        completion_writes++;
                    end

                    default: begin
                        $fatal(
                            1,
                            "FAIL: unexpected memory write at cycle %0d address=%08h data=%08h",
                            cycle,
                            mem_addr,
                            mem_write_data
                        );
                    end
                endcase
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

                // Allow the synchronous completion write to commit to memory.
                @(negedge clk);

                // Verify the architectural register state after all 16 iterations.
                check_register(1,  32'h0000_0140, "final vector-A pointer");
                check_register(2,  32'h0000_0180, "final vector-B pointer");
                check_register(3,  32'h0000_0000, "final loop count");
                check_register(4,  EXPECTED_RESULT, "final accumulator");
                check_register(5,  32'h0000_0010, "final vector-A element");
                check_register(6,  32'h0000_0001, "final vector-B element");
                check_register(7,  32'h0000_0010, "final multiplication result");
                check_register(31, DONE_VALUE,     "completion signature");

                // Byte address 0x180 corresponds to memory word index 0x60 = 96.
                if (test_memory.mem[96] !== EXPECTED_RESULT) begin
                    $fatal(
                        1,
                        "FAIL: stored dot product incorrect | actual=%08h expected=%08h",
                        test_memory.mem[96],
                        EXPECTED_RESULT
                    );
                end

                $display(
                    "PASS: stored dot product | memory[96]=%08h",
                    test_memory.mem[96]
                );

                // The completion write targets byte address 0x1BC,
                // corresponding to word index 0x6F = 111.
                if (test_memory.mem[111] !== DONE_VALUE) begin
                    $fatal(
                        1,
                        "FAIL: completion write did not commit | actual=%08h expected=%08h",
                        test_memory.mem[111],
                        DONE_VALUE
                    );
                end

                $display(
                    "PASS: completion write committed | memory[111]=%08h",
                    test_memory.mem[111]
                );

                // Verify the benchmark's dynamic operation and memory-access counts.
                check_count(instruction_fetches, 135, "instruction fetches");
                check_count(vector_a_reads,       16, "vector-A reads");
                check_count(vector_b_reads,       16, "vector-B reads");
                check_count(signature_reads,       1, "signature reads");
                check_count(result_writes,         1, "result writes");
                check_count(completion_writes,     1, "completion writes");
                check_count(mul_fetches,          16, "MUL executions");
                check_count(add_fetches,          16, "accumulating ADD executions");
                check_count(bne_fetches,          16, "BNE executions");

                // The zero-based cycle index should be 740, representing 741
                // active processor cycles after reset release.
                if (cycle != 740) begin
                    $fatal(
                        1,
                        "FAIL: unexpected completion cycle | actual=%0d expected=740",
                        cycle
                    );
                end

                $display(
                    "PASS: 16-element dot product completed at cycle %0d | active cycles=%0d",
                    cycle,
                    cycle + 1
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
