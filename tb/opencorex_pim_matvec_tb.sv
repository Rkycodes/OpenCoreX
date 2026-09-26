module opencorex_pim_matvec_tb;

    localparam int MAX_CYCLES = 25_000;

    localparam int INPUT_LENGTH  = 16;
    localparam int OUTPUT_LENGTH = 32;
    localparam int MATRIX_WORDS  = INPUT_LENGTH * OUTPUT_LENGTH;

    localparam logic [31:0] PROGRAM_LAST_ADDR = 32'h0000_0058;
    localparam logic [31:0] VECTOR_START      = 32'h0000_0100;
    localparam logic [31:0] VECTOR_END        = 32'h0000_013C;
    localparam logic [31:0] MATRIX_START      = 32'h0000_0140;
    localparam logic [31:0] MATRIX_END        = 32'h0000_093C;
    localparam logic [31:0] OUTPUT_START      = 32'h0000_0940;
    localparam logic [31:0] OUTPUT_END        = 32'h0000_09BC;
    localparam logic [31:0] SIGNATURE_ADDR    = 32'h0000_09C0;
    localparam logic [31:0] DONE_ADDR         = 32'h0000_09C4;
    localparam logic [31:0] DONE_VALUE        = 32'h524B_5943;

    localparam int VECTOR_START_WORD = 32'h0040;
    localparam int MATRIX_START_WORD = 32'h0050;
    localparam int OUTPUT_START_WORD = 32'h0250;
    localparam int DONE_WORD         = 32'h0271;

    logic clk;
    logic reset;

    logic        memory_read_enable;
    logic        memory_write_enable;
    logic [31:0] memory_address;
    logic [31:0] memory_write_data;
    logic [31:0] memory_read_data;
    logic        error;

    logic        pim_req_ready;
    logic        pim_rsp_valid;
    logic [31:0] pim_rsp_rdata;

    logic [31:0] expected_outputs [0:OUTPUT_LENGTH-1];
    logic [31:0] original_vector [0:INPUT_LENGTH-1];
    logic [31:0] original_matrix [0:MATRIX_WORDS-1];

    int unsigned instruction_fetches;
    int unsigned vector_reads;
    int unsigned matrix_reads;
    int unsigned signature_reads;
    int unsigned result_writes;
    int unsigned completion_writes;
    int unsigned mul_fetches;
    int unsigned accumulating_add_fetches;
    int unsigned inner_bne_fetches;
    int unsigned outer_bne_fetches;

    logic [31:0] expected_store_addr;

    // PIM is intentionally inactive in this regression. Its output signals
    // remain observable so the test can verify the idle-channel contract.
    opencorex_pim_subsystem dut (
        .clk                 (clk),
        .reset               (reset),

        .memory_read_enable  (memory_read_enable),
        .memory_write_enable (memory_write_enable),
        .memory_address      (memory_address),
        .memory_write_data   (memory_write_data),
        .memory_read_data    (memory_read_data),

        .error               (error)
    );

    assign pim_req_ready = dut.pim_req_ready;
    assign pim_rsp_valid = dut.pim_rsp_valid;
    assign pim_rsp_rdata = dut.pim_rsp_rdata;

    memory #(
        .WORDS     (1024),
        .INIT_FILE ("programs/hex/matvec_1x16_16x32.hex")
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
            actual = dut.core_inst
                        .datapath_inst
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

    initial begin
        $readmemh(
            "programs/hex/matvec_1x16_16x32_expected.hex",
            expected_outputs
        );
    end

    initial begin : run_test
        instruction_fetches = 0;
        vector_reads = 0;
        matrix_reads = 0;
        signature_reads = 0;
        result_writes = 0;
        completion_writes = 0;
        mul_fetches = 0;
        accumulating_add_fetches = 0;
        inner_bne_fetches = 0;
        outer_bne_fetches = 0;
        expected_store_addr = OUTPUT_START;

        reset = 1'b1;
        repeat (2) @(posedge clk);

        for (int i = 0; i < INPUT_LENGTH; i++) begin
            original_vector[i] = test_memory.mem[VECTOR_START_WORD + i];
        end

        for (int i = 0; i < MATRIX_WORDS; i++) begin
            original_matrix[i] = test_memory.mem[MATRIX_START_WORD + i];
        end

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

            // Ready may legally be either 0 or 1 while valid is low, but it
            // must be a known protocol value after reset is released.
            if ($isunknown(pim_req_ready)) begin
                $fatal(
                    1,
                    "FAIL: idle PIM ready is unknown at cycle %0d",
                    cycle
                );
            end

            // No PIM read was requested, so no PIM response may be claimed.
            // Response data is meaningful only when response valid is high.
            if (pim_rsp_valid !== 1'b0) begin
                $fatal(
                    1,
                    "FAIL: unexpected PIM response at cycle %0d data=%08h",
                    cycle,
                    pim_rsp_rdata
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
                    "FAIL: misaligned access at cycle %0d address=%08h",
                    cycle,
                    memory_address
                );
            end

            // Count accepted physical reads. With PIM inactive, every one of
            // these transactions belongs to the CPU.
            if (memory_read_enable) begin
                if (memory_address <= PROGRAM_LAST_ADDR) begin
                    instruction_fetches++;

                    case (memory_address)
                        32'h0000_0028: mul_fetches++;
                        32'h0000_002C: accumulating_add_fetches++;
                        32'h0000_003C: inner_bne_fetches++;
                        32'h0000_004C: outer_bne_fetches++;
                        default: begin
                        end
                    endcase
                end
                else if ((memory_address >= VECTOR_START) &&
                         (memory_address <= VECTOR_END)) begin
                    vector_reads++;
                end
                else if ((memory_address >= MATRIX_START) &&
                         (memory_address <= MATRIX_END)) begin
                    matrix_reads++;
                end
                else if (memory_address == SIGNATURE_ADDR) begin
                    signature_reads++;
                end
                else begin
                    $fatal(
                        1,
                        "FAIL: unexpected read at cycle %0d address=%08h",
                        cycle,
                        memory_address
                    );
                end
            end

            if (memory_write_enable) begin
                if ((memory_address >= OUTPUT_START) &&
                    (memory_address <= OUTPUT_END)) begin
                    if (result_writes >= OUTPUT_LENGTH) begin
                        $fatal(1, "FAIL: more than %0d result writes", OUTPUT_LENGTH);
                    end

                    expected_store_addr = OUTPUT_START + (result_writes * 4);

                    if (memory_address !== expected_store_addr) begin
                        $fatal(
                            1,
                            "FAIL: y[%0d] address actual=%08h expected=%08h",
                            result_writes,
                            memory_address,
                            expected_store_addr
                        );
                    end

                    if (memory_write_data !== expected_outputs[result_writes]) begin
                        $fatal(
                            1,
                            "FAIL: y[%0d] data actual=%08h expected=%08h",
                            result_writes,
                            memory_write_data,
                            expected_outputs[result_writes]
                        );
                    end

                    $display(
                        "PASS: y[%0d] store | address=%08h value=%08h",
                        result_writes,
                        memory_address,
                        memory_write_data
                    );
                    result_writes++;
                end
                else if (memory_address == DONE_ADDR) begin
                    completion_writes++;

                    if (memory_write_data !== DONE_VALUE) begin
                        $fatal(
                            1,
                            "FAIL: completion value actual=%08h expected=%08h",
                            memory_write_data,
                            DONE_VALUE
                        );
                    end
                end
                else begin
                    $fatal(
                        1,
                        "FAIL: unexpected write at cycle %0d address=%08h data=%08h",
                        cycle,
                        memory_address,
                        memory_write_data
                    );
                end
            end

            if (memory_write_enable && (memory_address == DONE_ADDR)) begin
                @(negedge clk);

                check_register(5,  32'h0000_0100, "constant vector base");
                check_register(6,  32'h0000_0940, "final matrix pointer");
                check_register(7,  32'h0000_09C0, "final output pointer");
                check_register(8,  32'h0000_0000, "final outer-loop count");
                check_register(9,  32'h0000_0140, "final working vector pointer");
                check_register(10, 32'h0000_0000, "final inner-loop count");
                check_register(11, 32'hFFFF_FFD7, "final accumulator y[31]");
                check_register(12, 32'h0000_0002, "final vector element");
                check_register(13, 32'hFFFF_FFEF, "final matrix element");
                check_register(14, 32'hFFFF_FFDE, "final multiplication result");
                check_register(31, DONE_VALUE, "RKYC completion signature");

                for (int i = 0; i < OUTPUT_LENGTH; i++) begin
                    if (test_memory.mem[OUTPUT_START_WORD + i] !==
                        expected_outputs[i]) begin
                        $fatal(
                            1,
                            "FAIL: stored y[%0d] actual=%08h expected=%08h",
                            i,
                            test_memory.mem[OUTPUT_START_WORD + i],
                            expected_outputs[i]
                        );
                    end
                end

                if (test_memory.mem[DONE_WORD] !== DONE_VALUE) begin
                    $fatal(
                        1,
                        "FAIL: completion write actual=%08h expected=%08h",
                        test_memory.mem[DONE_WORD],
                        DONE_VALUE
                    );
                end

                for (int i = 0; i < INPUT_LENGTH; i++) begin
                    if (test_memory.mem[VECTOR_START_WORD + i] !==
                        original_vector[i]) begin
                        $fatal(1, "FAIL: vector modified at index %0d", i);
                    end
                end

                for (int i = 0; i < MATRIX_WORDS; i++) begin
                    if (test_memory.mem[MATRIX_START_WORD + i] !==
                        original_matrix[i]) begin
                        $fatal(1, "FAIL: matrix modified at flat index %0d", i);
                    end
                end

                $display("PASS: all %0d output words committed correctly", OUTPUT_LENGTH);
                $display("PASS: input vector and matrix unchanged");

                check_count(instruction_fetches, 4327, "instruction fetches through completion");
                check_count(vector_reads, 512, "input-vector reads");
                check_count(matrix_reads, 512, "matrix reads");
                check_count(signature_reads, 1, "signature reads");
                check_count(result_writes, 32, "result writes");
                check_count(completion_writes, 1, "completion writes");
                check_count(mul_fetches, 512, "MUL executions");
                check_count(accumulating_add_fetches, 512, "accumulating ADD executions");
                check_count(inner_bne_fetches, 512, "inner-loop BNE executions");
                check_count(outer_bne_fetches, 32, "outer-loop BNE executions");

                if (cycle != 23_684) begin
                    $fatal(
                        1,
                        "FAIL: completion cycle actual=%0d expected=23684",
                        cycle
                    );
                end

                $display(
                    "PASS: subsystem matrix-vector benchmark completed at cycle %0d | active cycles=%0d",
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
