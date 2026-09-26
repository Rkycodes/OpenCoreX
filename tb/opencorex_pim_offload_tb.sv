module opencorex_pim_offload_tb;
    import pim_pkg::*;

    localparam int MAX_CYCLES = 20_000;
    localparam int VECTOR_WORD = 'h040;
    localparam int MATRIX_WORD = 'h050;
    localparam int OUTPUT_WORD = 'h250;
    localparam int DONE_WORD = 'h271;
    localparam logic [31:0] MMIO_BASE = 32'h4000_0000;
    localparam logic [31:0] SIGNATURE = 32'h524b_5943;

    logic clk = 0;
    always #5 clk <= ~clk;
    logic reset;
    logic memory_read_enable, memory_write_enable;
    logic [31:0] memory_address, memory_write_data, memory_read_data;
    logic error;
    logic [31:0] expected [0:31];
    logic [31:0] original_vector [0:15];
    logic [31:0] original_matrix [0:511];

    opencorex_pim_subsystem dut (
        .clk, .reset, .memory_read_enable, .memory_write_enable,
        .memory_address, .memory_write_data, .memory_read_data, .error
    );
    memory #(
        .WORDS(1024),
        .INIT_FILE("programs/hex/pim_offload_1x16_16x32.hex")
    ) test_memory (
        .clk, .read_enable(memory_read_enable),
        .write_enable(memory_write_enable), .address(memory_address),
        .write_data(memory_write_data), .read_data(memory_read_data)
    );

    task automatic check_mmio_write(input int index);
        logic [31:0] expected_addr, expected_data;
        case (index)
            0: begin expected_addr = MMIO_BASE + 32'h00; expected_data = 32'h100; end
            1: begin expected_addr = MMIO_BASE + 32'h04; expected_data = 16; end
            2: begin expected_addr = MMIO_BASE + 32'h08; expected_data = 32'h140; end
            3: begin expected_addr = MMIO_BASE + 32'h0c; expected_data = 64; end
            4: begin expected_addr = MMIO_BASE + 32'h10; expected_data = 32'h940; end
            5: begin expected_addr = MMIO_BASE + 32'h14; expected_data = 32; end
            6: begin expected_addr = MMIO_BASE + 32'h18; expected_data = 1; end
            default: $fatal(1, "extra MMIO write");
        endcase
        if (dut.mmio_req_addr !== expected_addr || dut.mmio_req_wdata !== expected_data)
            $fatal(1, "MMIO write %0d: addr=%08x data=%08x", index,
                   dut.mmio_req_addr, dut.mmio_req_wdata);
    endtask

    initial begin : benchmark
        int mmio_writes, mmio_reads;
        int vector_reads, matrix_reads, output_writes, pim_responses;
        int blocked_cycles, start_cycle, final_cycle, total_cycles;
        int success_loop_fetches, literal_reads;
        bit start_seen, final_seen, status_seen, status_request_seen, signature_seen;
        logic [31:0] pc_during_busy;
        bit pc_snapshot_valid;

        $readmemh("programs/hex/matvec_1x16_16x32_expected.hex", expected);
        reset = 1;
        mmio_writes = 0;
        mmio_reads = 0;
        vector_reads = 0;
        matrix_reads = 0;
        output_writes = 0;
        pim_responses = 0;
        blocked_cycles = 0;
        start_cycle = -1;
        final_cycle = -1;
        total_cycles = 0;
        success_loop_fetches = 0;
        literal_reads = 0;
        start_seen = 0;
        final_seen = 0;
        status_seen = 0;
        status_request_seen = 0;
        signature_seen = 0;
        pc_during_busy = 0;
        pc_snapshot_valid = 0;
        repeat (2) @(posedge clk);
        for (int i = 0; i < 16; i++)
            original_vector[i] = test_memory.mem[VECTOR_WORD+i];
        for (int i = 0; i < 512; i++)
            original_matrix[i] = test_memory.mem[MATRIX_WORD+i];
        @(negedge clk);
        reset = 0;

        for (int cycle = 0; cycle < MAX_CYCLES; cycle++) begin
            @(posedge clk);
            if (error) $fatal(1, "CPU entered ERROR at cycle %0d", cycle);
            if (memory_read_enable && memory_write_enable)
                $fatal(1, "simultaneous external RAM read and write");
            if ((memory_read_enable || memory_write_enable)
                && (memory_address[1:0] != 0 || memory_address >= 4096))
                $fatal(1, "invalid external RAM transaction %08x", memory_address);
            if (memory_read_enable && memory_address == 32'h80) begin
                literal_reads++;
                if (literal_reads != 1 || start_seen)
                    $fatal(1, "CPU fetched or reread MMIO base literal");
            end

            if (dut.mmio_req_valid && dut.mmio_req_ready) begin
                if (memory_read_enable || memory_write_enable)
                    $fatal(1, "MMIO transaction leaked to external RAM");
                if (dut.mmio_req_write) begin
                    check_mmio_write(mmio_writes);
                    mmio_writes++;
                    if (dut.mmio_req_addr == MMIO_BASE + 32'h18) begin
                        if (start_seen || dut.pim_busy || !dut.cpu_req_ready)
                            $fatal(1, "START store not accepted before busy");
                        start_seen = 1;
                        start_cycle = cycle;
                    end
                end else begin
                    mmio_reads++;
                    if (dut.mmio_req_addr != MMIO_BASE + 32'h1c
                        || !final_seen || dut.pim_busy)
                        $fatal(1, "STATUS read preceded final PIM write");
                    status_request_seen = 1;
                end
            end

            if (start_seen && dut.pim_busy) begin
                if (dut.cpu_req_ready || dut.ram_req_valid || dut.mmio_req_valid)
                    $fatal(1, "CPU made request progress while PIM busy");
                if (dut.cpu_req_valid) blocked_cycles++;
                if (pc_snapshot_valid
                    && dut.core_inst.datapath_inst.PC !== pc_during_busy)
                    $fatal(1, "CPU PC advanced during PIM busy");
            end

            if (dut.pim_req_valid && dut.pim_req_ready) begin
                if (dut.pim_req_write) begin
                    if (dut.pim_req_addr < 32'h940 || dut.pim_req_addr >= 32'h9c0
                        || dut.pim_req_addr != 32'h940 + 32'(output_writes * 4))
                        $fatal(1, "unexpected PIM output write %08x", dut.pim_req_addr);
                    if (!memory_write_enable || memory_address != dut.pim_req_addr
                        || memory_write_data != dut.pim_req_wdata)
                        $fatal(1, "PIM output write did not reach external RAM");
                    if (dut.pim_req_wdata !== expected[output_writes])
                        $fatal(1, "PIM y[%0d]=%08x expected=%08x", output_writes,
                               dut.pim_req_wdata, expected[output_writes]);
                    output_writes++;
                    if (output_writes == 32) begin
                        final_seen = 1;
                        final_cycle = cycle;
                    end
                end else begin
                    if (!memory_read_enable || memory_address != dut.pim_req_addr)
                        $fatal(1, "PIM read did not reach external RAM");
                    if (dut.pim_req_addr >= 32'h100 && dut.pim_req_addr < 32'h140)
                        vector_reads++;
                    else if (dut.pim_req_addr >= 32'h140 && dut.pim_req_addr < 32'h940)
                        matrix_reads++;
                    else
                        $fatal(1, "unexpected PIM read %08x", dut.pim_req_addr);
                end
            end
            if (dut.pim_rsp_valid) begin
                pim_responses++;
                if (dut.cpu_rsp_valid || dut.ram_rsp_valid)
                    $fatal(1, "PIM read response appeared on CPU channel");
            end

            if (dut.mmio_rsp_valid) begin
                if (!status_request_seen || !final_seen || status_seen)
                    $fatal(1, "unexpected MMIO response");
                if (dut.mmio_rsp_rdata[PIM_STATUS_DONE_BIT] != 1'b1
                    || dut.mmio_rsp_rdata[PIM_STATUS_ERROR_BIT] != 1'b0)
                    $fatal(1, "STATUS does not indicate successful completion");
                status_seen = 1;
            end

            if (memory_write_enable && memory_address == 32'h9c4) begin
                if (!status_seen || !final_seen || dut.pim_busy
                    || memory_write_data != SIGNATURE)
                    $fatal(1, "completion signature written before confirmed DONE");
                signature_seen = 1;
                total_cycles = cycle + 1;
            end
            if (memory_read_enable && memory_address == 32'h64)
                success_loop_fetches++;

            if (start_seen && start_cycle == cycle) begin
                #1;
                if (!dut.pim_busy || dut.cpu_req_ready)
                    $fatal(1, "registered busy did not follow accepted START");
                pc_during_busy = dut.core_inst.datapath_inst.PC;
                pc_snapshot_valid = 1;
            end
            if (final_seen && final_cycle == cycle) begin
                #1;
                if (dut.pim_busy)
                    $fatal(1, "busy not released after final output acceptance");
            end
            if (signature_seen) break;
        end
        if (!signature_seen) $fatal(1, "offload benchmark timed out");
        if (mmio_writes != 7 || mmio_reads != 1 || !status_seen
            || vector_reads != 16 || matrix_reads != 512
            || output_writes != 32 || pim_responses != 528
            || blocked_cycles == 0 || literal_reads != 1)
            $fatal(1, "offload counts: mmio_w=%0d mmio_r=%0d vec=%0d matrix=%0d out=%0d responses=%0d blocked=%0d",
                   mmio_writes, mmio_reads, vector_reads, matrix_reads,
                   output_writes, pim_responses, blocked_cycles);

        @(negedge clk);
        for (int i = 0; i < 32; i++) begin
            if (test_memory.mem[OUTPUT_WORD+i] !== expected[i])
                $fatal(1, "stored output y[%0d] mismatch", i);
        end
        for (int i = 0; i < 16; i++) begin
            if (test_memory.mem[VECTOR_WORD+i] !== original_vector[i])
                $fatal(1, "vector changed at %0d", i);
        end
        for (int i = 0; i < 512; i++) begin
            if (test_memory.mem[MATRIX_WORD+i] !== original_matrix[i])
                $fatal(1, "matrix changed at %0d", i);
        end
        if (test_memory.mem[DONE_WORD] !== SIGNATURE
            || test_memory.mem['h020] !== MMIO_BASE)
            $fatal(1, "signature or MMIO literal changed");

        repeat (25) begin
            @(posedge clk);
            if (error || dut.pim_busy || memory_write_enable
                || (memory_read_enable && memory_address == 32'h80))
                $fatal(1, "program did not remain in safe success loop");
            if (memory_read_enable && memory_address == 32'h64)
                success_loop_fetches++;
        end
        if (success_loop_fetches < 2)
            $fatal(1, "success self-loop was not executed");

        $display("PIM offload cycles: total CPU program=%0d, START-to-final-output=%0d, CPU blocked=%0d",
                 total_cycles, final_cycle - start_cycle, blocked_cycles);
        $display("PIM traffic: vector reads=%0d, matrix reads=%0d, output writes=%0d",
                 vector_reads, matrix_reads, output_writes);
        $display("PASS: opencorex_pim_offload_tb");
        $finish;
    end
endmodule
