module opencorex_dot_product_tb;

    localparam int MAX_CYCLES = 900;

    localparam logic [31:0] RESULT_ADDR     = 32'h0000_0180;
    localparam logic [31:0] EXPECTED_RESULT = 32'h0000_00CE;
    localparam logic [31:0] SIGNATURE_ADDR  = 32'h0000_01A0;
    localparam logic [31:0] DONE_ADDR       = 32'h0000_01BC;
    localparam logic [31:0] DONE_VALUE      = 32'h524B_5943;
    localparam logic [31:0] VECTOR_A_START  = 32'h0000_0100;
    localparam logic [31:0] VECTOR_A_END    = 32'h0000_013C;
    localparam logic [31:0] VECTOR_B_START  = 32'h0000_0140;
    localparam logic [31:0] VECTOR_B_END    = 32'h0000_017C;

    logic clk;
    logic reset;

    logic        mem_req_valid;
    logic        mem_req_ready;
    logic        mem_req_write;
    logic [31:0] mem_req_addr;
    logic [31:0] mem_req_wdata;
    logic        mem_rsp_valid;
    logic [31:0] mem_rsp_rdata;

    logic        memory_read_enable;
    logic        memory_write_enable;
    logic [31:0] memory_address;
    logic [31:0] memory_write_data;
    logic [31:0] memory_read_data;
    logic        error;

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
        .clk           (clk),
        .reset         (reset),

        .mem_req_valid (mem_req_valid),
        .mem_req_ready (mem_req_ready),
        .mem_req_write (mem_req_write),
        .mem_req_addr  (mem_req_addr),
        .mem_req_wdata (mem_req_wdata),

        .mem_rsp_valid (mem_rsp_valid),
        .mem_rsp_rdata (mem_rsp_rdata),

        .error         (error)
    );

    synchronous_memory_adapter memory_adapter (
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
        .WORDS     (1024),
        .INIT_FILE ("programs/hex/dot_product_16.hex")
    ) test_memory (
        .clk          (clk),
        .read_enable  (memory_read_enable),
        .write_enable (memory_write_enable),
        .address      (memory_address),
        .write_data   (memory_write_data),
        .read_data    (memory_read_data)
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

            $display("PASS: %s | count=%0d", test_name, actual);
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

        repeat (2) @(posedge clk);

        @(negedge clk);
        reset = 1'b0;

        for (int cycle = 0; cycle < MAX_CYCLES; cycle++) begin
            @(posedge clk);

            if (error !== 1'b0) begin
                $fatal(
                    1,
                    "FAIL: core entered ERROR state at cycle %0d",
                    cycle
                );
            end

            if (memory_read_enable && memory_write_enable) begin
                $fatal(
                    1,
                    "FAIL: physical read and write asserted together at cycle %0d",
                    cycle
                );
            end

            if ((memory_read_enable || memory_write_enable) &&
                (memory_address[1:0] != 2'b00)) begin
                $fatal(
                    1,
                    "FAIL: misaligned memory access at cycle %0d address=%08h",
                    cycle,
                    memory_address
                );
            end

            // Count accepted physical reads, not cycles where a request may
            // merely remain valid under backpressure.
            if (memory_read_enable) begin
                if (memory_address <= 32'h0000_003C) begin
                    instruction_fetches++;

                    case (memory_address)
                        32'h0000_0018: mul_fetches++;
                        32'h0000_001C: add_fetches++;
                        32'h0000_002C: bne_fetches++;
                        default: begin
                        end
                    endcase
                end
                else if ((memory_address >= VECTOR_A_START) &&
                         (memory_address <= VECTOR_A_END)) begin
                    vector_a_reads++;
                end
                else if ((memory_address >= VECTOR_B_START) &&
                         (memory_address <= VECTOR_B_END)) begin
                    vector_b_reads++;
                end
                else if (memory_address == SIGNATURE_ADDR) begin
                    signature_reads++;
                end
                else begin
                    $fatal(
                        1,
                        "FAIL: unexpected memory read at cycle %0d address=%08h",
                        cycle,
                        memory_address
                    );
                end
            end

            if (memory_write_enable) begin
                case (memory_address)
                    RESULT_ADDR: begin
                        result_writes++;

                        if (memory_write_data !== EXPECTED_RESULT) begin
                            $fatal(
                                1,
                                "FAIL: incorrect result store | actual=%08h expected=%08h",
                                memory_write_data,
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
                            memory_address,
                            memory_write_data
                        );
                    end
                endcase
            end

            if (memory_write_enable && (memory_address == DONE_ADDR)) begin
                if (memory_write_data !== DONE_VALUE) begin
                    $fatal(
                        1,
                        "FAIL: incorrect completion value | actual=%08h expected=%08h",
                        memory_write_data,
                        DONE_VALUE
                    );
                end

                @(negedge clk);

                check_register(1,  32'h0000_0140, "final vector-A pointer");
                check_register(2,  32'h0000_0180, "final vector-B pointer");
                check_register(3,  32'h0000_0000, "final loop count");
                check_register(4,  EXPECTED_RESULT, "final accumulator");
                check_register(5,  32'h0000_0010, "final vector-A element");
                check_register(6,  32'h0000_0001, "final vector-B element");
                check_register(7,  32'h0000_0010, "final multiplication result");
                check_register(31, DONE_VALUE,     "completion signature");

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

                check_count(instruction_fetches, 135, "instruction fetches");
                check_count(vector_a_reads,       16, "vector-A reads");
                check_count(vector_b_reads,       16, "vector-B reads");
                check_count(signature_reads,       1, "signature reads");
                check_count(result_writes,         1, "result writes");
                check_count(completion_writes,     1, "completion writes");
                check_count(mul_fetches,          16, "MUL executions");
                check_count(add_fetches,          16, "accumulating ADD executions");
                check_count(bne_fetches,          16, "BNE executions");

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
