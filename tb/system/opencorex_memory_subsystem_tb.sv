module opencorex_memory_subsystem_tb;

    localparam int MAX_CYCLES = 175;
    localparam logic [31:0] DONE_ADDR = 32'h0000_00BC;
    localparam logic [31:0] DONE_VALUE = 32'h524B_5943;
    localparam logic [31:0] PIM_TEST_ADDR = 32'h0000_0FFC;
    localparam logic [31:0] PIM_TEST_VALUE = 32'hDEAD_BEEF;

    logic clk;
    logic reset;

    logic        pim_req_valid;
    logic        pim_req_ready;
    logic        pim_req_write;
    logic [31:0] pim_req_addr;
    logic [31:0] pim_req_wdata;
    logic        pim_rsp_valid;
    logic [31:0] pim_rsp_rdata;

    logic        memory_read_enable;
    logic        memory_write_enable;
    logic [31:0] memory_address;
    logic [31:0] memory_write_data;
    logic [31:0] memory_read_data;

    logic error;
    logic pim_contention_test_complete;

    opencorex_memory_subsystem dut (
        .clk                 (clk),
        .reset               (reset),

        .pim_req_valid       (pim_req_valid),
        .pim_req_ready       (pim_req_ready),
        .pim_req_write       (pim_req_write),
        .pim_req_addr        (pim_req_addr),
        .pim_req_wdata       (pim_req_wdata),
        .pim_rsp_valid       (pim_rsp_valid),
        .pim_rsp_rdata       (pim_rsp_rdata),

        .memory_read_enable  (memory_read_enable),
        .memory_write_enable (memory_write_enable),
        .memory_address      (memory_address),
        .memory_write_data   (memory_write_data),
        .memory_read_data    (memory_read_data),

        .error               (error)
    );

    memory #(
        .WORDS     (1024),
        .INIT_FILE ("programs/hex/integration_smoke.hex")
    ) test_memory (
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

    // Inject a PIM write during a CPU fetch. The first CPU fetch establishes
    // CPU as last_grant. At the next CPU request, round-robin arbitration must
    // therefore grant PIM and stall CPU for exactly that accepted PIM request.
    initial begin : inject_pim_contention
        logic [31:0] stalled_cpu_address;

        pim_req_valid = 1'b0;
        pim_req_write = 1'b0;
        pim_req_addr  = 32'b0;
        pim_req_wdata = 32'b0;
        pim_contention_test_complete = 1'b0;

        wait (reset == 1'b0);

        // Wait for the first accepted CPU transaction.
        do begin
            @(posedge clk);
        end while (!(dut.cpu_req_valid && dut.cpu_req_ready));

        // Wait for a later CPU request, then create simultaneous contention.
        do begin
            @(negedge clk);
        end while (!dut.cpu_req_valid);

        stalled_cpu_address = dut.cpu_req_addr;
        pim_req_valid = 1'b1;
        pim_req_write = 1'b1;
        pim_req_addr  = PIM_TEST_ADDR;
        pim_req_wdata = PIM_TEST_VALUE;
        #1;

        check_bit(dut.cpu_req_ready, 1'b0, "PIM arbitration stalls CPU fetch");
        check_bit(pim_req_ready, 1'b1, "PIM wins contention after CPU grant");
        check_word(
            dut.cpu_req_addr,
            stalled_cpu_address,
            "CPU fetch address is stable before stalled edge"
        );
        check_word(memory_address, PIM_TEST_ADDR, "PIM address reaches external RAM");

        // PIM write is accepted on this edge.
        @(posedge clk);
        #1;

        pim_req_valid = 1'b0;
        pim_req_write = 1'b0;
        pim_req_addr  = 32'b0;
        pim_req_wdata = 32'b0;
        #1;

        check_bit(dut.cpu_req_valid, 1'b1, "CPU fetch remains valid after stall");
        check_bit(dut.cpu_req_ready, 1'b1, "CPU receives port after PIM write");
        check_word(
            dut.cpu_req_addr,
            stalled_cpu_address,
            "CPU fetch address remains stable across stalled edge"
        );
        check_word(
            test_memory.mem[PIM_TEST_ADDR >> 2],
            PIM_TEST_VALUE,
            "PIM write commits to external RAM"
        );

        // CPU fetch is accepted on the next edge.
        @(posedge clk);
        #1;
        pim_contention_test_complete = 1'b1;
        $display("PASS: CPU resumes after requester-local PIM contention");
    end

    initial begin : run_test
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

            // This test issues one PIM write and no PIM reads. Any asserted
            // response is therefore a routing or response-tracking defect.
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
                    "FAIL: misaligned physical access at cycle %0d address=%08h",
                    cycle,
                    memory_address
                );
            end

            if (memory_write_enable && memory_address == DONE_ADDR) begin
                if (memory_write_data !== DONE_VALUE) begin
                    $fatal(
                        1,
                        "FAIL: completion value actual=%08h expected=%08h",
                        memory_write_data,
                        DONE_VALUE
                    );
                end

                @(negedge clk);

                check_bit(
                    pim_contention_test_complete,
                    1'b1,
                    "PIM contention test completed before CPU program"
                );
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

                check_word(
                    test_memory.mem[32],
                    32'd11,
                    "CPU store result"
                );
                check_word(
                    test_memory.mem[PIM_TEST_ADDR >> 2],
                    PIM_TEST_VALUE,
                    "PIM data remains intact"
                );

                $display(
                    "PASS: integrated CPU/PIM memory path completed at cycle %0d",
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
