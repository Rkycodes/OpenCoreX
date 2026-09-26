module opencorex_pim_system_regression_tb;
    import pim_pkg::*;
    localparam int MAX_CYCLES = 30_000;
    localparam logic [31:0] MMIO_BASE = 32'h4000_0000;
    logic clk = 0;
    always #5 clk <= ~clk;
    logic reset;
    logic memory_read_enable, memory_write_enable, error;
    logic [31:0] memory_address, memory_write_data, memory_read_data;
    logic [31:0] expected [0:31];
    logic [31:0] original_vector [0:15];
    logic [31:0] original_matrix [0:511];
    int vector_reads [0:6];
    int weight_reads [0:6];
    int output_writes [0:6];
    int buffer_writes [0:6];
    int buffer_reads [0:6];
    int bypasses [0:6];
    int begin_vectors [0:6];

    opencorex_pim_subsystem dut (
        .clk, .reset, .memory_read_enable, .memory_write_enable,
        .memory_address, .memory_write_data, .memory_read_data, .error
    );
    memory #(
        .WORDS(1024), .INIT_FILE("programs/hex/pim_system_regression.hex")
    ) test_memory (
        .clk, .read_enable(memory_read_enable), .write_enable(memory_write_enable),
        .address(memory_address), .write_data(memory_write_data),
        .read_data(memory_read_data)
    );

    function automatic logic [31:0] expected_read_data(input int index);
        case (index)
            0, 1, 3, 6, 19: return 32'h0000_000a;
            4, 13, 18: return 32'h0000_0008;
            5, 2: return 0;
            7, 9, 11, 14, 16: return 32'h0000_000c;
            8, 10, 12: return 32'(PIM_ERROR_VECTOR_REUSE_MISMATCH);
            15, 17: return 32'(PIM_ERROR_INVALID_VECTOR_LENGTH);
            default: return 32'hffff_ffff;
        endcase
    endfunction

    function automatic logic [31:0] expected_read_addr(input int index);
        case (index)
            2, 8, 10, 12, 15, 17: return MMIO_BASE + 32'h24;
            default: return MMIO_BASE + 32'h1c;
        endcase
    endfunction

    initial begin : system_run
        int command_index, command_cycle, read_requests, read_responses;
        int invalidations, clears, busy_blocked_cycles;
        bit signature_seen;
        logic [31:0] held_pc;
        bit held_pc_valid, check_bypass;
        logic [31:0] bypass_value;
        $readmemh("programs/hex/matvec_1x16_16x32_expected.hex", expected);
        reset = 1;
        command_index = -1;
        command_cycle = -1;
        read_requests = 0;
        read_responses = 0;
        invalidations = 0;
        clears = 0;
        busy_blocked_cycles = 0;
        signature_seen = 0;
        held_pc = 0;
        held_pc_valid = 0;
        for (int i = 0; i < 7; i++) begin
            vector_reads[i] = 0;
            weight_reads[i] = 0;
            output_writes[i] = 0;
            buffer_writes[i] = 0;
            buffer_reads[i] = 0;
            bypasses[i] = 0;
            begin_vectors[i] = 0;
        end
        repeat (2) @(posedge clk);
        for (int i = 0; i < 16; i++)
            original_vector[i] = test_memory.mem['h40+i];
        for (int i = 0; i < 512; i++)
            original_matrix[i] = test_memory.mem['h50+i];
        @(negedge clk);
        reset = 0;

        for (int cycle = 0; cycle < MAX_CYCLES; cycle++) begin
            check_bypass = 0;
            @(posedge clk);
            if (error) $fatal(1, "CPU error in system regression");
            if (memory_read_enable && memory_write_enable)
                $fatal(1, "external RAM collision");
            if ((memory_read_enable || memory_write_enable)
                && (memory_address[1:0] != 0 || memory_address >= 4096))
                $fatal(1, "MMIO or invalid address reached external RAM");

            if (dut.mmio_req_valid && dut.mmio_req_ready) begin
                if (memory_read_enable || memory_write_enable)
                    $fatal(1, "MMIO transaction leaked to external RAM");
                if (dut.mmio_req_write) begin
                    if (dut.mmio_req_addr == MMIO_BASE + 32'h18) begin
                        command_index++;
                        if (command_index > 6) $fatal(1, "extra command");
                        if (dut.mmio_req_wdata != ((command_index == 1 || command_index == 3) ? 3 : 1))
                            $fatal(1, "wrong command word at index %0d", command_index);
                        if (dut.pim_busy || !dut.cpu_req_ready)
                            $fatal(1, "CPU START store did not complete before busy");
                        if (command_index == 4) begin
                            if (dut.accelerator_inst.cmd_start)
                                $fatal(1, "sticky error accepted a command");
                        end else if (!dut.accelerator_inst.cmd_start)
                            $fatal(1, "valid command not accepted");
                        command_cycle = cycle;
                        held_pc_valid = 0;
                    end else if (dut.mmio_req_addr == MMIO_BASE + 32'h4c) begin
                        invalidations++;
                        if (invalidations != 1 || !dut.accelerator_inst.buffer_invalidate)
                            $fatal(1, "buffer invalidation not accepted");
                    end else if (dut.mmio_req_addr == MMIO_BASE + 32'h28) begin
                        clears++;
                        if (clears > 3 || dut.mmio_req_wdata != (clears == 1 ? 2 : 4))
                            $fatal(1, "unexpected STATUS_CLEAR");
                    end
                end else begin
                    if (read_requests >= 20
                        || dut.mmio_req_addr != expected_read_addr(read_requests))
                        $fatal(1, "unexpected MMIO read %0d at %08x",
                               read_requests, dut.mmio_req_addr);
                    if (dut.pim_busy)
                        $fatal(1, "CPU MMIO read escaped busy block");
                    read_requests++;
                end
            end
            if (dut.mmio_rsp_valid) begin
                if (read_responses >= read_requests
                    || dut.mmio_rsp_rdata !== expected_read_data(read_responses)
                    || !dut.cpu_rsp_valid
                    || dut.cpu_rsp_rdata !== dut.mmio_rsp_rdata)
                    $fatal(1, "MMIO response %0d: got %08x expected %08x",
                           read_responses, dut.mmio_rsp_rdata,
                           expected_read_data(read_responses));
                read_responses++;
            end

            if (dut.pim_busy) begin
                if (cycle - command_cycle > 8000)
                    $fatal(1, "PIM command watchdog expired");
                if (dut.cpu_req_ready || dut.ram_req_valid || dut.mmio_req_valid)
                    $fatal(1, "CPU advanced while PIM busy");
                if (dut.cpu_req_valid) busy_blocked_cycles++;
                if (held_pc_valid && dut.core_inst.datapath_inst.PC !== held_pc)
                    $fatal(1, "CPU PC advanced while PIM busy");
            end

            if (dut.accelerator_inst.buffer_begin_vector) begin
                if (command_index < 0) $fatal(1, "buffer begin before command");
                begin_vectors[command_index]++;
            end
            if (dut.accelerator_inst.buffer_write_enable) begin
                if (command_index < 0 || !dut.pim_rsp_valid)
                    $fatal(1, "buffer write without PIM vector response");
                buffer_writes[command_index]++;
                bypasses[command_index]++;
                check_bypass = 1;
                bypass_value = dut.pim_rsp_rdata;
            end
            if (dut.accelerator_inst.buffer_read_enable) begin
                if (command_index < 0) $fatal(1, "buffer read before command");
                buffer_reads[command_index]++;
            end

            if (dut.pim_req_valid && dut.pim_req_ready) begin
                if (command_index < 0 || command_index == 3
                    || command_index == 4 || command_index == 5)
                    $fatal(1, "rejected command produced PIM memory traffic");
                if (dut.pim_req_write) begin
                    if (!memory_write_enable
                        || memory_address != dut.pim_req_addr
                        || memory_write_data != dut.pim_req_wdata
                        || dut.pim_req_addr != 32'h940 + 32'(4 * output_writes[command_index]))
                        $fatal(1, "PIM output write not accepted exactly once");
                    if (output_writes[command_index] >= 32
                        || dut.pim_req_wdata !== expected[output_writes[command_index]])
                        $fatal(1, "incorrect PIM output");
                    output_writes[command_index]++;
                end else begin
                    if (!memory_read_enable || memory_address != dut.pim_req_addr)
                        $fatal(1, "PIM read not routed to external RAM");
                    if (dut.pim_req_addr >= 32'h100 && dut.pim_req_addr < 32'h140)
                        vector_reads[command_index]++;
                    else if (dut.pim_req_addr >= 32'h140 && dut.pim_req_addr < 32'h940)
                        weight_reads[command_index]++;
                    else
                        $fatal(1, "unexpected PIM read %08x", dut.pim_req_addr);
                end
            end
            if (dut.pim_rsp_valid && (dut.cpu_rsp_valid || dut.ram_rsp_valid))
                $fatal(1, "PIM response reached CPU");

            if (memory_write_enable && memory_address == 32'h9c4) begin
                if (command_index != 6 || read_responses != 20
                    || memory_write_data != 32'h524b_5943)
                    $fatal(1, "CPU signature written before recovery completed");
                signature_seen = 1;
            end

            if (command_index >= 0 && command_index != 4
                && command_cycle == cycle) begin
                #1;
                if (!dut.pim_busy) $fatal(1, "registered busy missing after START");
                held_pc = dut.core_inst.datapath_inst.PC;
                held_pc_valid = 1;
            end
            if (check_bypass) begin
                #1;
                if (dut.accelerator_inst.controller.vector_operand !== bypass_value)
                    $fatal(1, "response bypass operand mismatch");
            end
            if (signature_seen) break;
        end
        if (!signature_seen || command_index != 6
            || read_requests != 20 || read_responses != 20
            || invalidations != 1 || clears != 3 || busy_blocked_cycles == 0)
            $fatal(1, "system regression sequence incomplete");

        for (int i = 0; i < 7; i++) begin
            if (i == 0 || i == 2 || i == 6) begin
                if (vector_reads[i] != 16 || weight_reads[i] != 512
                    || output_writes[i] != 32 || buffer_writes[i] != 16
                    || bypasses[i] != 16 || buffer_reads[i] != 496
                    || begin_vectors[i] != 1)
                    $fatal(1, "cold/refill command %0d counts: vec=%0d weight=%0d out=%0d bw=%0d br=%0d",
                           i, vector_reads[i], weight_reads[i], output_writes[i],
                           buffer_writes[i], buffer_reads[i]);
            end else if (i == 1) begin
                if (vector_reads[i] != 0 || weight_reads[i] != 512
                    || output_writes[i] != 32 || buffer_writes[i] != 0
                    || bypasses[i] != 0 || buffer_reads[i] != 512
                    || begin_vectors[i] != 0)
                    $fatal(1, "warm reuse counts incorrect");
            end else if (vector_reads[i] != 0 || weight_reads[i] != 0
                         || output_writes[i] != 0 || buffer_writes[i] != 0
                         || buffer_reads[i] != 0 || bypasses[i] != 0
                         || begin_vectors[i] != 0)
                $fatal(1, "rejected command %0d changed memory or buffer", i);
        end
        @(negedge clk);
        for (int i = 0; i < 32; i++)
            if (test_memory.mem['h250+i] !== expected[i])
                $fatal(1, "final output %0d incorrect", i);
        for (int i = 0; i < 16; i++)
            if (test_memory.mem['h40+i] !== original_vector[i])
                $fatal(1, "vector changed");
        for (int i = 0; i < 512; i++)
            if (test_memory.mem['h50+i] !== original_matrix[i])
                $fatal(1, "matrix changed");
        if (test_memory.mem['h271] !== 32'h524b_5943)
            $fatal(1, "completion signature missing");

        // Restart the CPU image and abort the first command just after its
        // first output write. The RAM has no reset and must retain that write.
        reset = 1;
        $readmemh("programs/hex/pim_system_regression.hex", test_memory.mem);
        repeat (2) @(negedge clk);
        reset = 0;
        for (int cycle = 0; cycle < 10_000; cycle++) begin
            @(posedge clk);
            if (memory_write_enable && memory_address == 32'h940) begin
                if (!dut.pim_busy || !dut.pim_req_valid || !dut.pim_req_ready)
                    $fatal(1, "first output write was not accepted");
                break;
            end
            if (cycle == 9999) $fatal(1, "reset injection timed out");
        end
        @(negedge clk);
        reset = 1;
        #1;
        if (dut.pim_busy || dut.pim_req_valid || memory_write_enable
            || test_memory.mem['h250] !== expected[0]
            || test_memory.mem['h251] !== 0)
            $fatal(1, "reset did not abort control and preserve accepted write");
        repeat (2) @(negedge clk);
        reset = 0;
        for (int cycle = 0; cycle < 500; cycle++) begin
            @(posedge clk);
            if (dut.mmio_req_valid && dut.mmio_req_ready
                && dut.mmio_req_write
                && dut.mmio_req_addr == MMIO_BASE + 32'h18)
                break;
            if (dut.pim_busy || dut.pim_req_valid
                || test_memory.mem['h250] !== expected[0]
                || test_memory.mem['h251] !== 0)
                $fatal(1, "aborted PIM command resumed before a fresh START");
            if (cycle == 499) $fatal(1, "CPU did not reach fresh START after reset");
        end
        $display("PASS: opencorex_pim_system_regression_tb");
        $finish;
    end
endmodule
