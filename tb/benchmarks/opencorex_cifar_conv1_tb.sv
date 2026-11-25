// Full Conv1_1 programs run on the CPU and PIM RTL with the existing latency responder.
module opencorex_cifar_conv1_tb #(parameter bit CACHE_ENABLE = 1);
    import pim_pkg::*;

    localparam int RAM_WORDS = 262144, SIDE = 32, CHANNELS = 3, FILTERS = 64;
    localparam int TERMS = 27, POSITIONS = SIDE * SIDE, TILE = 128;
    localparam int OUTPUTS = POSITIONS * FILTERS, PATCH_WORDS = POSITIONS * TERMS;
    localparam int INPUT = 'h10000, PATCH = 'h14000, WEIGHTS = 'h30000;
    localparam int OUTPUT = 'h40000, FILTER_OUTPUT = 'h80000;
    localparam int SIGNATURE = 'h440, DONE = 'h444, PHASE = 'h448;
    localparam int MMIO = 'h40000000;
    localparam int CPU = 0, PER_DOT = 1, ACTIVATIONS = 2, RELOAD = 3, RETAIN = 4;

    logic clk = 0;
    always #5 clk <= ~clk;
    logic reset, error, memory_read_enable, memory_write_enable;
    logic [31:0] memory_address, memory_write_data, memory_read_data;
    int read_delay = 1, mode = CPU;
    bit weights_first;

    cache_study_subsystem #(.ICACHE_ENABLE(CACHE_ENABLE), .RAM_WORDS(RAM_WORDS),
        .BUFFER_WORDS(128), .MAX_OUTPUTS(128), .MAC_LANES(1)) dut (
        .clk, .reset, .read_delay, .fetch_delay(read_delay), .error,
        .memory_read_enable, .memory_write_enable, .memory_address,
        .memory_write_data, .memory_read_data
    );
    memory #(.WORDS(RAM_WORDS)) test_memory (
        .clk, .read_enable(memory_read_enable), .write_enable(memory_write_enable),
        .address(memory_address), .write_data(memory_write_data), .read_data(memory_read_data)
    );

    logic [31:0] raw[OUTPUTS], patches[PATCH_WORDS];
    int phase = 0, phase_cycles[4], cycle;
    int commands, cold_commands, status_reads, status_responses, mmio_writes;
    int start_edge, command_end, command_cycles, pim_busy_cycles;
    int cpu_wait_cycles, cpu_blocked_cycles, response_edge;
    bit read_pending, read_from_pim;
    logic [31:0] expected_response;
    int input_reads, activation_reads, weight_reads, fetch_reads, control_reads;
    int patch_writes, raw_writes, gather_reads, gather_writes, ram_reads, ram_writes;
    int buffer_loads, buffer_reads, buffer_begins, pim_macs, cpu_muls;

    function automatic bit in_region(input logic [31:0] address, input int base, words);
        return address >= base && address < base + 4 * words;
    endfunction

    function automatic int canonical(input int index);
        return weights_first ? (index % POSITIONS) * FILTERS + index / POSITIONS : index;
    endfunction

    task automatic check_launch;
        pim_descriptor_t descriptor;
        int vector_base, matrix_base, output_base, count, command_word;
        descriptor = dut.accelerator_inst.cmd_descriptor;
        count = weights_first ? TILE : (mode == PER_DOT ? 1 : FILTERS);
        if (weights_first) begin
            vector_base = WEIGHTS + 4 * TERMS * (commands / (POSITIONS / TILE));
            matrix_base = PATCH + 4 * TERMS * TILE * (commands % (POSITIONS / TILE));
            output_base = FILTER_OUTPUT + 4 * TILE * commands;
        end else begin
            vector_base = PATCH + 4 * TERMS * (raw_writes / FILTERS);
            matrix_base = WEIGHTS + 4 * TERMS * (raw_writes % FILTERS);
            output_base = OUTPUT + 4 * raw_writes;
        end
        command_word = (mode == RETAIN && commands % (POSITIONS / TILE) != 0) ? 3 : 1;
        if (dut.mmio_req_wdata != command_word || raw_writes != commands * count ||
            status_responses != commands || dut.pim_busy ||
            descriptor.vector_base != vector_base || descriptor.matrix_base != matrix_base ||
            descriptor.output_base != output_base || descriptor.output_count != count ||
            descriptor.vector_length != TERMS || descriptor.matrix_column_stride != 4 * TERMS)
            $fatal(1, "descriptor mismatch at command %0d", commands);
        if (command_word == 3 &&
            (!dut.accelerator_inst.buffer_vector_full ||
             dut.accelerator_inst.resident_vector_base != vector_base ||
             dut.accelerator_inst.resident_vector_length != TERMS))
            $fatal(1, "warm command requires matching resident weights");
        cold_commands += int'(command_word == 1);
        start_edge = cycle;
        command_end = raw_writes + count;
        commands++;
    endtask

    task automatic check_read;
        bit pim_access;
        int index, expected_index;
        pim_access = dut.pim_req_valid && dut.pim_req_ready && !dut.pim_req_write;
        if (read_pending || dut.mem_rsp_valid || (mode == CPU && pim_access))
            $fatal(1, "overlapping read or unexpected PIM requester");
        read_pending = 1;
        read_from_pim = pim_access;
        response_edge = cycle + read_delay;
        expected_response = test_memory.mem[memory_address >> 2];
        ram_reads++;
        if (in_region(memory_address, 0, 4) || in_region(memory_address, 'h1000, 4096)) begin
            if (pim_access) $fatal(1, "PIM read executable memory");
            fetch_reads++;
        end else if (in_region(memory_address, INPUT, CHANNELS * POSITIONS)) begin
            if (phase != 1 || pim_access) $fatal(1, "input read phase or owner");
            input_reads++;
        end else if (in_region(memory_address, PATCH, PATCH_WORDS)) begin
            index = (int'(memory_address) - PATCH) / 4;
            expected_index = weights_first ? activation_reads % PATCH_WORDS :
                (mode == ACTIVATIONS ? activation_reads : activation_reads / (TERMS * FILTERS) * TERMS
                 + activation_reads % TERMS);
            if (phase != 2 || pim_access != (mode != CPU) || index != expected_index)
                $fatal(1, "packed activation read sequence at %0d, got %0d expected %0d",
                       activation_reads, index, expected_index);
            activation_reads++;
        end else if (in_region(memory_address, WEIGHTS, FILTERS * TERMS)) begin
            index = (int'(memory_address) - WEIGHTS) / 4;
            expected_index = weights_first ?
                (mode == RELOAD ? weight_reads / (TERMS * (POSITIONS / TILE)) * TERMS
                 + weight_reads % TERMS : weight_reads) : weight_reads % (FILTERS * TERMS);
            if (phase != 2 || pim_access != (mode != CPU) || index != expected_index)
                $fatal(1, "weight read sequence at %0d, got %0d expected %0d",
                       weight_reads, index, expected_index);
            weight_reads++;
        end else if (weights_first && in_region(memory_address, FILTER_OUTPUT, OUTPUTS)) begin
            expected_index = (gather_reads % FILTERS) * POSITIONS + gather_reads / FILTERS;
            if (phase != 3 || pim_access || gather_reads >= OUTPUTS ||
                memory_address != FILTER_OUTPUT + 4 * expected_index ||
                expected_response !== raw[gather_reads])
                $fatal(1, "gather source mismatch at %0d", gather_reads);
            gather_reads++;
        end else if (!pim_access && (in_region(memory_address, 'h500, 64) ||
                                     (memory_address == SIGNATURE && phase == 3))) begin
            control_reads++;
        end else $fatal(1, "unclassified read at %h", memory_address);
    endtask

    task automatic check_write(output bit finished);
        bit pim_access;
        int base;
        finished = 0;
        pim_access = dut.pim_req_valid && dut.pim_req_ready && dut.pim_req_write;
        base = weights_first ? FILTER_OUTPUT : OUTPUT;
        ram_writes++;
        if (read_pending || dut.mem_rsp_valid) $fatal(1, "write during outstanding read");
        if (in_region(memory_address, PATCH, PATCH_WORDS)) begin
            if (phase != 1 || pim_access || memory_address != PATCH + 4 * patch_writes ||
                memory_write_data !== patches[patch_writes])
                $fatal(1, "packed value mismatch at %0d", patch_writes);
            patch_writes++;
        end else if (phase == 2 && in_region(memory_address, base, OUTPUTS)) begin
            if (pim_access != (mode != CPU) || memory_address != base + 4 * raw_writes ||
                memory_write_data !== raw[canonical(raw_writes)])
                $fatal(1, "raw output mismatch at %0d, got %h expected %h", raw_writes,
                       memory_write_data, raw[canonical(raw_writes)]);
            raw_writes++;
            if (pim_access && raw_writes == command_end) begin
                command_cycles += cycle - start_edge;
                $display("COMMAND,%0d,%0d,%0d,%0d", commands - 1, start_edge, cycle, cycle - start_edge);
            end
        end else if (weights_first && phase == 3 && in_region(memory_address, OUTPUT, OUTPUTS)) begin
            if (pim_access || memory_address != OUTPUT + 4 * gather_writes ||
                memory_write_data !== raw[gather_writes])
                $fatal(1, "canonical output mismatch at %0d", gather_writes);
            gather_writes++;
        end else if (memory_address == PHASE) begin
            if (pim_access || phase >= 3 || memory_write_data != phase + 1)
                $fatal(1, "invalid phase transition");
            phase++;
        end else if (memory_address == DONE) begin
            if (pim_access || phase != 3 || memory_write_data !== 32'h524b5943 || dut.pim_busy)
                $fatal(1, "invalid completion");
            finished = 1;
        end else $fatal(1, "unclassified write at %h", memory_address);
    endtask

    task automatic metric(input string name, input int value);
        $display("METRIC,%s,%0d", name, value);
    endtask

    initial begin : benchmark
        string image, raw_file, patch_file;
        bit finished;
        if (!$value$plusargs("MODE=%d", mode) || mode < CPU || mode > RETAIN ||
            !$value$plusargs("DELAY=%d", read_delay) || read_delay < 1 || read_delay > 20 ||
            !$value$plusargs("IMAGE=%s", image) || !$value$plusargs("RAW=%s", raw_file) ||
            !$value$plusargs("PATCHES=%s", patch_file))
            $fatal(1, "missing or invalid benchmark arguments");
        weights_first = mode == RELOAD || mode == RETAIN;
        reset = 1;
        #1;
        $readmemh(image, test_memory.mem);
        $readmemh(raw_file, raw);
        $readmemh(patch_file, patches);
        repeat (2) @(posedge clk);
        @(negedge clk);
        reset = 0;
        for (cycle = 0; cycle < 200000000; cycle++) begin
            @(posedge clk);
            phase_cycles[phase]++;
            if (error || dut.accelerator_inst.ctrl_error_set || dut.accelerator_inst.mmio.status_error)
                $fatal(1, "CPU or PIM error");
            if (dut.pim_busy) begin
                pim_busy_cycles++;
                if (dut.cpu_req_ready || dut.ram_req_valid || dut.mmio_req_valid)
                    $fatal(1, "CPU access accepted while PIM busy");
            end
            if (dut.cpu_req_valid && !dut.cpu_req_ready) begin
                cpu_wait_cycles++;
                if (dut.pim_busy) cpu_blocked_cycles++;
            end else if (!dut.cpu_rsp_valid &&
                         (dut.core_inst.controller_inst.current_state == 1 ||
                          dut.core_inst.controller_inst.current_state == 8)) begin
                // FETCH_CAPTURE or MEM_READ_CAPTURE waiting for the response.
                cpu_wait_cycles++;
            end
            if (dut.cpu_req_valid && dut.cpu_req_ready && dut.cpu_req_is_fetch && phase == 2) begin
                logic [31:0] instruction;
                instruction = test_memory.mem[dut.cpu_req_addr >> 2];
                if ((instruction & 32'hfe00707f) == 32'h02000033)
                    cpu_muls++;
            end
            if (dut.mmio_req_valid && dut.mmio_req_ready) begin
                if (phase != 2 || mode == CPU || memory_read_enable || memory_write_enable)
                    $fatal(1, "MMIO phase or isolation");
                if (dut.mmio_req_write) begin
                    mmio_writes++;
                    if (dut.mmio_req_addr == MMIO + 32'(PIM_REG_COMMAND)) check_launch();
                end else begin
                    if (dut.mmio_req_addr != MMIO + 32'(PIM_REG_STATUS) || dut.pim_busy)
                        $fatal(1, "unexpected status read");
                    status_reads++;
                end
            end
            if (dut.mmio_rsp_valid) begin
                if (status_responses >= status_reads || dut.mmio_rsp_rdata != 10)
                    $fatal(1, "status must be DONE and VECTOR_FULL");
                status_responses++;
            end
            if (memory_read_enable && memory_write_enable) $fatal(1, "RAM port collision");
            if ((memory_read_enable || memory_write_enable) &&
                (memory_address >= 4 * RAM_WORDS || memory_address[1:0] != 0))
                $fatal(1, "RAM address out of range or unaligned");
            if (memory_read_enable) check_read();
            if (memory_write_enable) check_write(finished);
            if (dut.mem_rsp_valid) begin
                if (!read_pending || cycle != response_edge ||
                    dut.mem_rsp_rdata !== expected_response ||
                    dut.pim_rsp_valid != read_from_pim || dut.cache_rsp_valid == read_from_pim)
                    $fatal(1, "read timing, data or owner");
                read_pending = 0;
            end else if (read_pending && cycle >= response_edge) $fatal(1, "missing read response");

            buffer_begins += int'(dut.accelerator_inst.buffer_begin_vector);
            buffer_loads += int'(dut.accelerator_inst.buffer_write_enable);
            buffer_reads += int'(dut.accelerator_inst.buffer_read_enable);
            pim_macs += int'(dut.accelerator_inst.mac_start);
            if (mode == ACTIVATIONS && commands == 1 && cycle - start_edge < 240 &&
                (memory_read_enable || memory_write_enable || dut.pim_rsp_valid ||
                 dut.accelerator_inst.buffer_read_enable || dut.accelerator_inst.mac_start ||
                 dut.accelerator_inst.mac_done))
                $display("EDGE,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%08h",
                    cycle - start_edge, memory_read_enable, dut.pim_rsp_valid, memory_write_enable,
                    dut.accelerator_inst.buffer_write_enable, dut.accelerator_inst.buffer_read_enable,
                    dut.accelerator_inst.mac_start, dut.accelerator_inst.mac_done,
                    dut.accelerator_inst.controller.vector_index, memory_address);
            if (finished) break;
        end
        if (!finished || read_pending || raw_writes != OUTPUTS || patch_writes != PATCH_WORDS ||
            status_reads != commands || status_responses != commands || pim_busy_cycles != command_cycles ||
            buffer_begins != cold_commands || buffer_loads + buffer_reads != pim_macs ||
            cpu_muls + pim_macs != OUTPUTS * TERMS ||
            (weights_first && (gather_reads != OUTPUTS || gather_writes != OUTPUTS)))
            $fatal(1, "incomplete execution or counter mismatch");
        @(negedge clk);
        foreach (raw[i])
            if (test_memory.mem[OUTPUT / 4 + i] !== raw[i])
                $fatal(1, "final stored tensor mismatch at %0d", i);

        metric("cycles", cycle + 1);
        metric("setup_cycles", phase_cycles[0]);
        metric("packing_cycles", phase_cycles[1]);
        metric("compute_cycles", phase_cycles[2]);
        metric("output_phase_cycles", phase_cycles[3]);
        metric("cpu_wait_cycles", cpu_wait_cycles);
        metric("cpu_blocked_cycles", cpu_blocked_cycles);
        metric("cpu_non_wait_cycles", cycle + 1 - cpu_wait_cycles);
        metric("pim_cycles", pim_busy_cycles);
        metric("cpu_muls", cpu_muls);
        metric("pim_macs", pim_macs);
        metric("commands", commands);
        metric("cold_commands", cold_commands);
        metric("mmio_reads", status_reads);
        metric("mmio_writes", mmio_writes);
        metric("input_reads", input_reads);
        metric("activation_reads", activation_reads);
        metric("weight_reads", weight_reads);
        metric("fetch_reads", fetch_reads);
        metric("control_reads", control_reads);
        metric("gather_reads", gather_reads);
        metric("gather_writes", gather_writes);
        metric("patch_writes", patch_writes);
        metric("output_writes", raw_writes);
        metric("ram_reads", ram_reads);
        metric("ram_writes", ram_writes);
        metric("buffer_loads", buffer_loads);
        metric("buffer_reuses", buffer_reads);
        metric("outputs_checked", OUTPUTS);
        $display("PASS: opencorex_cifar_conv1_tb");
        $finish;
    end
endmodule
