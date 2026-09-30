module opencorex_memory_latency_tb;
    logic clk = 0;
    always #5 clk <= ~clk;
    logic reset;
    logic memory_read_enable, memory_write_enable, error;
    logic [31:0] memory_address, memory_write_data, memory_read_data;
    int read_delay, fetch_delay, mode, fixed_fetch;
    logic [31:0] expected [0:31], original_vector [0:15], original_matrix [0:511];
    int vec [0:1], matrix [0:1], outputs [0:1], bw [0:1], br [0:1], mac [0:1];
    int blocked [0:1], start_edge [0:1], final_edge [0:1], pim_wait [0:1];
    int begin_vector [0:1];

    // Generated from the production subsystem, replacing only its RAM adapter.
    latency_pim_subsystem dut (
        .clk, .reset, .read_delay, .fetch_delay,
        .memory_read_enable, .memory_write_enable, .memory_address,
        .memory_write_data, .memory_read_data, .error
    );
    memory #(.WORDS(1024)) test_memory (
        .clk, .read_enable(memory_read_enable), .write_enable(memory_write_enable),
        .address(memory_address), .write_data(memory_write_data), .read_data(memory_read_data)
    );

    initial begin : experiment
        string image;
        int fetches, cpu_vector, cpu_matrix, cpu_other, cpu_outputs, completion_writes;
        int mmio_w, mmio_r, mmio_responses, command_index, clear_edge, done_edge;
        int cpu_blocked, busy_blocked, fetch_wait, data_wait, pending_edge, pending_due;
        int pending_kind, ram_reads, ram_responses, baseline;
        bit pending_command, pending, stalled, stalled_write, signature_seen;
        logic [31:0] stalled_addr, stalled_data, pending_data;
        logic [31:0] held_pc;

        mode = 0; read_delay = 1; fixed_fetch = 0;
        if (!$value$plusargs("MODE=%d", mode)) mode = 0;
        if (!$value$plusargs("DELAY=%d", read_delay)) read_delay = 1;
        if (!$value$plusargs("FIXED_FETCH=%d", fixed_fetch)) fixed_fetch = 0;
        if (mode < 0 || mode > 4 || read_delay < 1 || read_delay > 20 ||
            (fixed_fetch != 0 && fixed_fetch != 1)) $fatal(1, "bad sweep arguments");
        fetch_delay = fixed_fetch != 0 ? 1 : read_delay;
        case (mode)
            0: begin image = "programs/hex/matvec_1x16_16x32.hex"; baseline = 23685; end
            1: begin image = "programs/hex/matvec_1x16_16x32_streaming.hex"; baseline = 13290; end
            2: begin image = "programs/hex/matvec_1x16_16x32_resident.hex"; baseline = 9818; end
            3: begin image = "programs/hex/pim_offload_1x16_16x32.hex"; baseline = 4272; end
            4: begin image = "programs/hex/pim_cold_warm_1x16_16x32.hex"; baseline = 8452; end
            default: $fatal(1, "invalid mode");
        endcase
        reset = 1;
        fetches = 0; cpu_vector = 0; cpu_matrix = 0; cpu_other = 0;
        cpu_outputs = 0; completion_writes = 0; mmio_w = 0; mmio_r = 0;
        mmio_responses = 0; command_index = -1; clear_edge = -1; done_edge = -1;
        cpu_blocked = 0; busy_blocked = 0; fetch_wait = 0; data_wait = 0;
        pending = 0; pending_kind = 0; pending_command = 0; pending_edge = -1;
        pending_due = -1; pending_data = 0; ram_reads = 0; ram_responses = 0;
        stalled = 0; stalled_write = 0; stalled_addr = 0; stalled_data = 0;
        signature_seen = 0; held_pc = 0;
        for (int c = 0; c < 2; c++) begin
            vec[c] = 0; matrix[c] = 0; outputs[c] = 0; bw[c] = 0; br[c] = 0;
            mac[c] = 0; blocked[c] = 0; start_edge[c] = -1; final_edge[c] = -1;
            pim_wait[c] = 0; begin_vector[c] = 0;
        end
        #1;
        $readmemh(image, test_memory.mem);
        $readmemh("programs/hex/matvec_1x16_16x32_expected.hex", expected);
        repeat (2) @(posedge clk);
        for (int i = 0; i < 16; i++) original_vector[i] = test_memory.mem['h40+i];
        for (int i = 0; i < 512; i++) original_matrix[i] = test_memory.mem['h50+i];
        @(negedge clk);
        reset = 0;

        for (int cycle = 0; cycle < 200000; cycle++) begin
            @(posedge clk);
            if (error || dut.accelerator_inst.ctrl_error_set ||
                dut.accelerator_inst.mmio.status_error) $fatal(1, "CPU/PIM error");
            if (memory_read_enable && memory_write_enable) $fatal(1, "port collision");
            if ((memory_read_enable || memory_write_enable) &&
                (memory_address[1:0] != 0 || memory_address >= 4096))
                $fatal(1, "invalid RAM address");
            if (stalled && (!dut.mem_req_valid || dut.mem_req_write != stalled_write ||
                dut.mem_req_addr != stalled_addr || dut.mem_req_wdata != stalled_data))
                $fatal(1, "request changed under backpressure");
            stalled = dut.mem_req_valid && !dut.mem_req_ready;
            stalled_write = dut.mem_req_write;
            stalled_addr = dut.mem_req_addr;
            stalled_data = dut.mem_req_wdata;

            // Independent response deadline, data and ownership scoreboard.
            if (dut.mem_rsp_valid) begin
                if (!pending || cycle != pending_due || dut.mem_rsp_rdata !== pending_data)
                    $fatal(1, "wrong/unsolicited RAM response at %0d due %0d", cycle, pending_due);
                if (pending_kind == 2) begin
                    if (!dut.pim_rsp_valid || dut.cpu_rsp_valid || dut.ram_rsp_valid)
                        $fatal(1, "wrong PIM response owner");
                end else if (!dut.ram_rsp_valid || !dut.cpu_rsp_valid || dut.pim_rsp_valid)
                    $fatal(1, "wrong CPU response owner");
                pending = 0;
                ram_responses++;
            end else if (pending) begin
                if (cycle >= pending_due || cycle <= pending_edge)
                    $fatal(1, "missing RAM response");
                case (pending_kind)
                    0: fetch_wait++;
                    1: data_wait++;
                    2: pim_wait[pending_command]++;
                    default: $fatal(1, "bad pending owner");
                endcase
            end
            if (memory_read_enable) begin
                if (pending || dut.mem_rsp_valid) $fatal(1, "more than one outstanding read");
                pending = 1;
                pending_edge = cycle;
                pending_data = test_memory.mem[memory_address >> 2];
                pending_kind = 1;
                pending_command = command_index == 1;
                if (dut.pim_req_valid && dut.pim_req_ready) begin
                    if (command_index < 0 || final_edge[command_index] >= 0)
                        $fatal(1, "PIM read outside command");
                    pending_kind = 2;
                    if (memory_address >= 'h100 && memory_address < 'h140) begin
                        if (command_index != 0 || memory_address != 'h100 + 32'(4*vec[0]))
                            $fatal(1, "invalid vector sequence");
                        vec[command_index]++;
                    end else if (memory_address >= 'h140 && memory_address < 'h940) begin
                        if (memory_address != 'h140 + 32'(4*matrix[command_index]))
                            $fatal(1, "invalid matrix sequence");
                        matrix[command_index]++;
                    end else $fatal(1, "unexpected PIM data read");
                end else begin
                    if (!dut.ram_req_valid || !dut.ram_req_ready) $fatal(1, "unowned RAM read");
                    if (dut.core_inst.MemRead && !dut.core_inst.MemAddrSource) begin
                        pending_kind = 0; fetches++;
                    end else if (memory_address >= 'h100 && memory_address < 'h140)
                        cpu_vector++;
                    else if (memory_address >= 'h140 && memory_address < 'h940)
                        cpu_matrix++;
                    else if (memory_address == 'h9c0 || (mode >= 3 && memory_address == 'h80))
                        cpu_other++;
                    else $fatal(1, "unexpected CPU data read");
                end
                pending_due = cycle + (pending_kind == 0 ? fetch_delay : read_delay);
                ram_reads++;
            end
            if (memory_write_enable) begin
                if (pending || dut.mem_rsp_valid) $fatal(1, "write while read outstanding");
                if (memory_address >= 'h940 && memory_address < 'h9c0) begin
                    if (mode >= 3) begin
                        if (command_index < 0 || !dut.pim_req_valid || !dut.pim_req_ready ||
                            outputs[command_index] >= 32 ||
                            memory_address != 'h940 + 32'(4*outputs[command_index]) ||
                            memory_write_data !== expected[outputs[command_index]])
                            $fatal(1, "bad PIM output");
                        outputs[command_index]++;
                        if (outputs[command_index] == 32) final_edge[command_index] = cycle;
                    end else begin
                        if (cpu_outputs >= 32 ||
                            memory_address != 'h940 + 32'(4*cpu_outputs) ||
                            memory_write_data !== expected[cpu_outputs])
                            $fatal(1, "bad CPU output");
                        cpu_outputs++;
                    end
                end else if (memory_address == 'h9c4) begin
                    if (memory_write_data !== 32'h524b5943 || completion_writes != 0 ||
                        (mode < 3 && cpu_outputs != 32) ||
                        (mode >= 3 && (final_edge[mode == 4 ? 1 : 0] < 0 ||
                         dut.pim_busy || mmio_responses != (mode == 4 ? 6 : 1))))
                        $fatal(1, "bad completion");
                    completion_writes++;
                    done_edge = cycle; signature_seen = 1;
                end else $fatal(1, "unexpected RAM write");
            end

            if (dut.mmio_req_valid && dut.mmio_req_ready) begin
                if (mode < 3 || memory_read_enable || memory_write_enable)
                    $fatal(1, "invalid MMIO routing");
                if (dut.mmio_req_write) begin
                    mmio_w++;
                    if (dut.mmio_req_addr == 'h40000028) begin
                        if (command_index != 0 || final_edge[0] < 0 ||
                            mmio_responses != 4 || dut.mmio_req_wdata != 2)
                            $fatal(1, "bad clear");
                        clear_edge = cycle;
                    end
                    if (dut.mmio_req_addr == 'h40000018) begin
                        command_index++;
                        if (command_index > (mode == 4 ? 1 : 0) || dut.pim_busy ||
                            dut.mmio_req_wdata != (command_index == 0 ? 1 : 3))
                            $fatal(1, "bad START");
                        if (command_index == 1) begin
                            if (clear_edge < 0 || mmio_responses != 5 ||
                                !dut.accelerator_inst.buffer_vector_full ||
                                dut.accelerator_inst.buffer_valid_count != 16 ||
                                dut.accelerator_inst.resident_vector_base != 'h100 ||
                                dut.accelerator_inst.resident_vector_length != 16)
                                $fatal(1, "warm without successful cold fill");
                            for (int i = 0; i < 16; i++)
                                if (!dut.accelerator_inst.vector_buffer.entry_valid[i] ||
                                    dut.accelerator_inst.vector_buffer.words[i] !== original_vector[i])
                                    $fatal(1, "invalid warm contents");
                        end
                        start_edge[command_index] = cycle;
                    end
                end else mmio_r++;
            end
            if (dut.mmio_rsp_valid) begin
                logic [31:0] status_expected;
                if (mode == 3) status_expected = 10;
                else case (mmio_responses)
                    0,5: status_expected = 10;
                    1,3: status_expected = 16;
                    2: status_expected = 'h100;
                    4: status_expected = 8;
                    default: $fatal(1, "extra status response");
                endcase
                if (mmio_responses >= mmio_r || dut.mmio_rsp_rdata !== status_expected)
                    $fatal(1, "bad MMIO response");
                mmio_responses++;
            end
            if (dut.cpu_req_valid && !dut.cpu_req_ready) cpu_blocked++;
            if (dut.pim_busy) begin
                if (command_index < 0 || dut.cpu_req_ready || dut.ram_req_valid || dut.mmio_req_valid)
                    $fatal(1, "CPU progressed while PIM busy");
                if (dut.core_inst.datapath_inst.PC !== held_pc)
                    $fatal(1, "PC moved during busy");
                if (dut.cpu_req_valid) begin
                    blocked[command_index]++; busy_blocked++;
                end
            end
            if (dut.accelerator_inst.buffer_invalidate)
                $fatal(1, "buffer invalidated between commands");
            if (dut.accelerator_inst.buffer_begin_vector) begin
                if (command_index != 0) $fatal(1, "warm buffer reinitialization");
                begin_vector[0]++;
            end
            if (dut.accelerator_inst.buffer_write_enable) bw[command_index]++;
            if (dut.accelerator_inst.buffer_read_enable) br[command_index]++;
            if (dut.accelerator_inst.mac_start) mac[command_index]++;

            // Inspect committed outputs after each command, not just after warm overwrite.
            if (command_index >= 0 && final_edge[command_index] == cycle) begin
                #1;
                for (int i = 0; i < 32; i++)
                    if (test_memory.mem['h250+i] !== expected[i]) $fatal(1, "stored command output");
            end
            if (command_index >= 0 && start_edge[command_index] == cycle) begin
                #1;
                held_pc = dut.core_inst.datapath_inst.PC;
            end
            if (signature_seen) break;
        end
        if (!signature_seen || pending || ram_reads != ram_responses) $fatal(1, "incomplete run");
        @(negedge clk);
        for (int i = 0; i < 32; i++)
            if (test_memory.mem['h250+i] !== expected[i]) $fatal(1, "stored output mismatch");
        for (int i = 0; i < 16; i++)
            if (test_memory.mem['h40+i] !== original_vector[i]) $fatal(1, "vector changed");
        for (int i = 0; i < 512; i++)
            if (test_memory.mem['h50+i] !== original_matrix[i]) $fatal(1, "matrix changed");
        if (test_memory.mem['h271] !== 32'h524b5943) $fatal(1, "missing signature");
        if (read_delay == 1 && done_edge + 1 != baseline)
            $fatal(1, "one-cycle baseline changed: got %0d expected %0d", done_edge+1, baseline);
        if (fetches != (mode == 0 ? 4327 : mode == 1 ? 2248 : mode == 2 ? 1752 :
                        mode == 3 ? 25 : 31) ||
            cpu_other != (mode < 3 ? 1 : 2) ||
            cpu_vector != (mode == 2 ? 16 : mode < 3 ? 512 : 0) ||
            cpu_matrix != (mode < 3 ? 512 : 0) ||
            mmio_w != (mode == 3 ? 7 : mode == 4 ? 9 : 0) ||
            mmio_r != (mode == 3 ? 1 : mode == 4 ? 6 : 0) ||
            mmio_responses != mmio_r)
            $fatal(1, "unexpected program traffic");
        for (int c = 0; c <= command_index; c++) begin
            if (vec[c] != (c == 0 ? 16 : 0) || matrix[c] != 512 ||
                outputs[c] != 32 || mac[c] != 512 ||
                bw[c] != (c == 0 ? 16 : 0) || br[c] != (c == 0 ? 496 : 512) ||
                begin_vector[c] != (c == 0 ? 1 : 0) ||
                (read_delay == 1 && final_edge[c] - start_edge[c] != (c == 0 ? 4141 : 4140)))
                $fatal(1, "unexpected command measurements");
        end
        $display("PROGRAM,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d",
            mode, read_delay, fetch_delay, done_edge+1, fetches,
            cpu_vector+vec[0]+vec[1], cpu_matrix+matrix[0]+matrix[1],
            cpu_outputs+outputs[0]+outputs[1], completion_writes, mmio_w, mmio_r,
            cpu_blocked, busy_blocked, fetch_wait, data_wait, pim_wait[0]+pim_wait[1]);
        for (int c = 0; c <= command_index; c++)
            $display("COMMAND,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d",
                mode, read_delay, fetch_delay, c, start_edge[c], final_edge[c],
                final_edge[c]-start_edge[c], blocked[c],
                c == 0 ? start_edge[0]+1 : start_edge[1]-clear_edge,
                c == 0 && mode == 4 ? clear_edge-final_edge[0] : done_edge-final_edge[c],
                vec[c], matrix[c], outputs[c], bw[c], br[c], mac[c], pim_wait[c]);
        $display("PASS: opencorex_memory_latency_tb");
        $finish;
    end
endmodule
