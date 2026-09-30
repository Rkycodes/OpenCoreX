module opencorex_pim_cold_warm_tb;
    import pim_pkg::*;

    localparam int MAX_CYCLES = 15_000;
    localparam logic [31:0] MMIO_BASE = 32'h4000_0000;
    localparam logic [31:0] VECTOR_BASE = 32'h0000_0100;
    localparam logic [31:0] MATRIX_BASE = 32'h0000_0140;
    localparam logic [31:0] OUTPUT_BASE = 32'h0000_0940;
    localparam logic [31:0] SIGNATURE = 32'h524b_5943;

    logic clk = 0;
    always #5 clk <= ~clk;
    logic reset;
    logic memory_read_enable, memory_write_enable, error;
    logic [31:0] memory_address, memory_write_data, memory_read_data;
    logic [31:0] expected [0:31];
    logic [31:0] original_vector [0:15];
    logic [31:0] original_matrix [0:511];

    int vector_reads [0:1];
    int matrix_reads [0:1];
    int output_writes [0:1];
    int buffer_writes [0:1];
    int buffer_reads [0:1];
    int bypasses [0:1];
    int macs [0:1];
    int begin_vectors [0:1];
    int blocked_cycles [0:1];
    int start_cycle [0:1];
    int final_cycle [0:1];

    opencorex_pim_subsystem dut (
        .clk, .reset, .memory_read_enable, .memory_write_enable,
        .memory_address, .memory_write_data, .memory_read_data, .error
    );
    memory #(
        .WORDS(1024), .INIT_FILE("programs/hex/pim_cold_warm_1x16_16x32.hex")
    ) test_memory (
        .clk, .read_enable(memory_read_enable),
        .write_enable(memory_write_enable), .address(memory_address),
        .write_data(memory_write_data), .read_data(memory_read_data)
    );

    function automatic logic [31:0] mmio_write_addr(input int index);
        case (index)
            0: return MMIO_BASE + 32'h00;
            1: return MMIO_BASE + 32'h04;
            2: return MMIO_BASE + 32'h08;
            3: return MMIO_BASE + 32'h0c;
            4: return MMIO_BASE + 32'h10;
            5: return MMIO_BASE + 32'h14;
            6, 8: return MMIO_BASE + 32'h18;
            7: return MMIO_BASE + 32'h28;
            default: return 32'hffff_ffff;
        endcase
    endfunction

    function automatic logic [31:0] mmio_write_data(input int index);
        case (index)
            0: return VECTOR_BASE;
            1: return 16;
            2: return MATRIX_BASE;
            3: return 64;
            4: return OUTPUT_BASE;
            5: return 32;
            6: return 1;
            7: return 2;  // STATUS_CLEAR.DONE W1C
            8: return 3;  // START | REUSE_VECTOR
            default: return 32'hffff_ffff;
        endcase
    endfunction

    function automatic logic [31:0] mmio_read_addr(input int index);
        case (index)
            0, 4, 5: return MMIO_BASE + 32'h1c;
            1: return MMIO_BASE + 32'h20;
            2: return MMIO_BASE + 32'h2c;
            3: return MMIO_BASE + 32'h30;
            default: return 32'hffff_ffff;
        endcase
    endfunction

    function automatic logic [31:0] mmio_read_data(input int index);
        case (index)
            0, 5: return 32'h0000_000a; // DONE | VECTOR_FULL
            1, 3: return 16;
            2: return VECTOR_BASE;
            4: return 32'h0000_0008;    // DONE cleared, buffer retained
            default: return 32'hffff_ffff;
        endcase
    endfunction

    initial begin : run_benchmark
        int command_index, mmio_writes, mmio_read_requests, mmio_read_responses;
        int clear_cycle, done_cycle, literal_reads, signature_reads;
        bit signature_seen, bypass_check, pc_snapshot_valid;
        logic [31:0] bypass_value, held_pc;
        $readmemh("programs/hex/matvec_1x16_16x32_expected.hex", expected);
        reset = 1;
        command_index = -1;
        mmio_writes = 0;
        mmio_read_requests = 0;
        mmio_read_responses = 0;
        clear_cycle = -1;
        done_cycle = -1;
        literal_reads = 0;
        signature_reads = 0;
        signature_seen = 0;
        bypass_check = 0;
        bypass_value = 0;
        held_pc = 0;
        pc_snapshot_valid = 0;
        for (int c = 0; c < 2; c++) begin
            vector_reads[c] = 0;
            matrix_reads[c] = 0;
            output_writes[c] = 0;
            buffer_writes[c] = 0;
            buffer_reads[c] = 0;
            bypasses[c] = 0;
            macs[c] = 0;
            begin_vectors[c] = 0;
            blocked_cycles[c] = 0;
            start_cycle[c] = -1;
            final_cycle[c] = -1;
        end
        repeat (2) @(posedge clk);
        for (int i = 0; i < 16; i++)
            original_vector[i] = test_memory.mem['h040 + i];
        for (int i = 0; i < 512; i++)
            original_matrix[i] = test_memory.mem['h050 + i];
        if (dut.accelerator_inst.buffer_valid_count != 0 ||
            dut.accelerator_inst.buffer_vector_full)
            $fatal(1, "vector buffer was not invalid at cold start");
        @(negedge clk);
        reset = 0;

        for (int cycle = 0; cycle < MAX_CYCLES; cycle++) begin
            bypass_check = 0;
            @(posedge clk);
            if (error || dut.accelerator_inst.ctrl_error_set ||
                dut.accelerator_inst.mmio.status_error)
                $fatal(1, "CPU or PIM error at cycle %0d", cycle);
            if (memory_read_enable && memory_write_enable)
                $fatal(1, "physical RAM read/write collision");
            if ((memory_read_enable || memory_write_enable) &&
                (memory_address[1:0] != 0 || memory_address >= 4096))
                $fatal(1, "invalid physical RAM access %08h", memory_address);

            if (dut.mmio_req_valid && dut.mmio_req_ready) begin
                if (memory_read_enable || memory_write_enable)
                    $fatal(1, "MMIO leaked to physical RAM");
                if (dut.mmio_req_write) begin
                    if (mmio_writes >= 9 ||
                        dut.mmio_req_addr !== mmio_write_addr(mmio_writes) ||
                        dut.mmio_req_wdata !== mmio_write_data(mmio_writes))
                        $fatal(1, "unexpected MMIO write %0d: %08h=%08h",
                               mmio_writes, dut.mmio_req_addr, dut.mmio_req_wdata);
                    if (mmio_writes == 7) begin
                        if (command_index != 0 || final_cycle[0] < 0 ||
                            mmio_read_responses != 4 || dut.pim_busy)
                            $fatal(1, "STATUS_CLEAR before cold completion");
                        clear_cycle = cycle;
                    end
                    if (mmio_writes == 6 || mmio_writes == 8) begin
                        command_index++;
                        if (command_index > 1 || dut.pim_busy ||
                            !dut.cpu_req_ready || !dut.accelerator_inst.cmd_start)
                            $fatal(1, "START did not launch command %0d", command_index);
                        if (command_index == 1) begin
                            if (clear_cycle < 0 || mmio_read_responses != 5 ||
                                !dut.accelerator_inst.buffer_vector_full ||
                                dut.accelerator_inst.buffer_valid_count != 16 ||
                                dut.accelerator_inst.resident_vector_base != VECTOR_BASE ||
                                dut.accelerator_inst.resident_vector_length != 16 ||
                                dut.accelerator_inst.buffer_begin_vector ||
                                dut.accelerator_inst.buffer_invalidate)
                                $fatal(1, "warm START lacks a valid reusable vector");
                            for (int i = 0; i < 16; i++) begin
                                if (!dut.accelerator_inst.vector_buffer.entry_valid[i] ||
                                    dut.accelerator_inst.vector_buffer.words[i] !==
                                        original_vector[i])
                                    $fatal(1, "resident vector differs at %0d", i);
                            end
                        end
                        start_cycle[command_index] = cycle;
                        pc_snapshot_valid = 0;
                    end
                    mmio_writes++;
                end else begin
                    if (mmio_read_requests >= 6 ||
                        dut.mmio_req_addr !== mmio_read_addr(mmio_read_requests) ||
                        dut.pim_busy)
                        $fatal(1, "unexpected MMIO read %0d at %08h",
                               mmio_read_requests, dut.mmio_req_addr);
                    mmio_read_requests++;
                end
            end
            if (dut.mmio_rsp_valid) begin
                if (mmio_read_responses >= mmio_read_requests ||
                    dut.mmio_rsp_rdata !== mmio_read_data(mmio_read_responses) ||
                    !dut.cpu_rsp_valid ||
                    dut.cpu_rsp_rdata !== dut.mmio_rsp_rdata)
                    $fatal(1, "MMIO response %0d=%08h expected=%08h",
                           mmio_read_responses, dut.mmio_rsp_rdata,
                           mmio_read_data(mmio_read_responses));
                mmio_read_responses++;
            end

            if (dut.pim_busy) begin
                if (command_index < 0 || cycle - start_cycle[command_index] > 8000)
                    $fatal(1, "PIM busy watchdog expired");
                if (dut.cpu_req_ready || dut.ram_req_valid || dut.mmio_req_valid)
                    $fatal(1, "CPU progressed during PIM busy");
                if (dut.cpu_req_valid) blocked_cycles[command_index]++;
                if (pc_snapshot_valid &&
                    dut.core_inst.datapath_inst.PC !== held_pc)
                    $fatal(1, "CPU PC advanced during PIM busy");
            end

            if (dut.accelerator_inst.buffer_begin_vector) begin
                if (command_index != 0)
                    $fatal(1, "warm command reinitialized vector buffer");
                begin_vectors[command_index]++;
            end
            if (dut.accelerator_inst.buffer_write_enable) begin
                if (command_index != 0 || !dut.pim_rsp_valid ||
                    dut.accelerator_inst.buffer_write_index !=
                        4'(buffer_writes[0]))
                    $fatal(1, "unexpected vector-buffer write");
                buffer_writes[command_index]++;
                bypasses[command_index]++;
                bypass_check = 1;
                bypass_value = dut.pim_rsp_rdata;
            end
            if (dut.accelerator_inst.buffer_read_enable) begin
                if (command_index < 0 ||
                    dut.accelerator_inst.buffer_read_index !=
                        4'(buffer_reads[command_index] % 16))
                    $fatal(1, "buffer read index out of order");
                buffer_reads[command_index]++;
            end
            if (dut.accelerator_inst.mac_start) begin
                if (command_index < 0) $fatal(1, "MAC before START");
                macs[command_index]++;
            end

            if (dut.pim_req_valid && dut.pim_req_ready) begin
                if (command_index < 0)
                    $fatal(1, "PIM request before START");
                if (dut.pim_req_write) begin
                    if (!memory_write_enable ||
                        memory_address != dut.pim_req_addr ||
                        memory_write_data != dut.pim_req_wdata ||
                        output_writes[command_index] >= 32 ||
                        dut.pim_req_addr != OUTPUT_BASE +
                            32'(4 * output_writes[command_index]) ||
                        dut.pim_req_wdata !== expected[output_writes[command_index]])
                        $fatal(1, "bad PIM output store for command %0d",
                               command_index);
                    output_writes[command_index]++;
                    if (output_writes[command_index] == 32)
                        final_cycle[command_index] = cycle;
                end else begin
                    if (!memory_read_enable ||
                        memory_address != dut.pim_req_addr)
                        $fatal(1, "PIM read not routed to physical RAM");
                    if (dut.pim_req_addr >= VECTOR_BASE &&
                        dut.pim_req_addr < MATRIX_BASE) begin
                        if (command_index != 0 ||
                            dut.pim_req_addr != VECTOR_BASE +
                                32'(4 * vector_reads[0]))
                            $fatal(1, "unexpected external vector read");
                        vector_reads[command_index]++;
                    end else if (dut.pim_req_addr >= MATRIX_BASE &&
                                 dut.pim_req_addr < OUTPUT_BASE) begin
                        if (dut.pim_req_addr != MATRIX_BASE +
                            32'(4 * matrix_reads[command_index]))
                            $fatal(1, "matrix read out of order");
                        matrix_reads[command_index]++;
                    end else $fatal(1, "unexpected PIM read %08h", dut.pim_req_addr);
                end
            end
            if (dut.pim_rsp_valid && (dut.cpu_rsp_valid || dut.ram_rsp_valid))
                $fatal(1, "PIM response reached CPU");

            if (memory_read_enable &&
                !(dut.pim_req_valid && dut.pim_req_ready)) begin
                if (!dut.ram_req_valid || !dut.ram_req_ready)
                    $fatal(1, "unowned CPU RAM read");
                if (memory_address == 32'h80) begin
                    literal_reads++;
                    if (literal_reads != 1) $fatal(1, "MMIO literal reread");
                end else if (memory_address == 32'h9c0) begin
                    signature_reads++;
                    if (signature_reads != 1 || final_cycle[1] < 0 ||
                        mmio_read_responses != 6)
                        $fatal(1, "early signature read");
                end else if (memory_address == 0 ||
                             (memory_address >= 32'ha00 &&
                              memory_address <= 32'ha78)) begin
                    if (!dut.core_inst.MemRead ||
                        dut.core_inst.MemAddrSource)
                        $fatal(1, "code read as data");
                end else $fatal(1, "unexpected CPU RAM read %08h", memory_address);
            end
            if (memory_write_enable &&
                !(dut.pim_req_valid && dut.pim_req_ready)) begin
                if (!dut.ram_req_valid || !dut.ram_req_ready ||
                    memory_address != 32'h9c4 ||
                    memory_write_data != SIGNATURE ||
                    final_cycle[1] < 0 || mmio_read_responses != 6)
                    $fatal(1, "unexpected or early CPU RAM write");
                done_cycle = cycle;
                signature_seen = 1;
            end

            if (command_index >= 0 &&
                start_cycle[command_index] == cycle) begin
                #1;
                if (!dut.pim_busy) $fatal(1, "registered busy missing after START");
                held_pc = dut.core_inst.datapath_inst.PC;
                pc_snapshot_valid = 1;
            end
            if (bypass_check) begin
                #1;
                if (dut.accelerator_inst.controller.vector_operand !== bypass_value)
                    $fatal(1, "cold vector-response bypass mismatch");
            end
            if (final_cycle[0] == cycle || final_cycle[1] == cycle) begin
                #1;
                for (int i = 0; i < 32; i++)
                    if (test_memory.mem['h250 + i] !== expected[i])
                        $fatal(1, "command %0d output memory mismatch at %0d",
                               command_index, i);
            end
            if (signature_seen) break;
        end

        if (!signature_seen || command_index != 1 ||
            mmio_writes != 9 || mmio_read_requests != 6 ||
            mmio_read_responses != 6 || literal_reads != 1 ||
            signature_reads != 1 || clear_cycle < 0)
            $fatal(1, "two-command CPU sequence incomplete");
        for (int c = 0; c < 2; c++) begin
            if (matrix_reads[c] != 512 || output_writes[c] != 32 ||
                macs[c] != 512 || blocked_cycles[c] == 0 ||
                final_cycle[c] <= start_cycle[c])
                $fatal(1, "command %0d incomplete", c);
        end
        if (vector_reads[0] != 16 || buffer_writes[0] != 16 ||
            bypasses[0] != 16 || buffer_reads[0] != 496 ||
            begin_vectors[0] != 1 ||
            vector_reads[1] != 0 || buffer_writes[1] != 0 ||
            bypasses[1] != 0 || buffer_reads[1] != 512 ||
            begin_vectors[1] != 0)
            $fatal(1, "cold/warm vector event discrepancy");

        @(negedge clk);
        for (int i = 0; i < 16; i++)
            if (test_memory.mem['h040 + i] !== original_vector[i])
                $fatal(1, "input vector changed");
        for (int i = 0; i < 512; i++)
            if (test_memory.mem['h050 + i] !== original_matrix[i])
                $fatal(1, "matrix changed");
        if (test_memory.mem['h271] !== SIGNATURE)
            $fatal(1, "completion signature missing");
        if (dut.accelerator_inst.buffer_valid_count != 16 ||
            !dut.accelerator_inst.buffer_vector_full)
            $fatal(1, "warm command lost resident vector");

        $display("COLD_WARM cold start_to_final=%0d blocked=%0d setup=%0d completion=%0d vec=%0d matrix=%0d out=%0d bw=%0d br=%0d bypass=%0d mac=%0d mmio_w=7 mmio_r=4",
                 final_cycle[0] - start_cycle[0], blocked_cycles[0],
                 start_cycle[0] + 1, clear_cycle - final_cycle[0],
                 vector_reads[0], matrix_reads[0], output_writes[0],
                 buffer_writes[0], buffer_reads[0], bypasses[0], macs[0]);
        $display("COLD_WARM warm start_to_final=%0d blocked=%0d setup=%0d completion=%0d vec=%0d matrix=%0d out=%0d bw=%0d br=%0d bypass=%0d mac=%0d mmio_w=1 mmio_r=2",
                 final_cycle[1] - start_cycle[1], blocked_cycles[1],
                 start_cycle[1] - clear_cycle, done_cycle - final_cycle[1],
                 vector_reads[1], matrix_reads[1], output_writes[1],
                 buffer_writes[1], buffer_reads[1], bypasses[1], macs[1]);
        $display("COLD_WARM status_clear=1 total_cycles=%0d", done_cycle + 1);
        $display("PASS: opencorex_pim_cold_warm_tb");
        $finish;
    end
endmodule
