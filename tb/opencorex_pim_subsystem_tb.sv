module opencorex_pim_subsystem_tb;
    import pim_pkg::*;
    logic clk = 0;
    always #5 clk <= ~clk;
    logic reset;
    logic memory_read_enable, memory_write_enable;
    logic [31:0] memory_address, memory_write_data, memory_read_data;
    logic error;

    opencorex_pim_subsystem dut (
        .clk, .reset, .memory_read_enable, .memory_write_enable,
        .memory_address, .memory_write_data, .memory_read_data, .error
    );
    memory #(.WORDS(1024)) test_memory (
        .clk, .read_enable(memory_read_enable),
        .write_enable(memory_write_enable), .address(memory_address),
        .write_data(memory_write_data), .read_data(memory_read_data)
    );

    function automatic logic [31:0] encode_addi(input logic [4:0] rd,
                                                 input logic [4:0] rs,
                                                 input logic [11:0] imm);
        return {imm, rs, 3'b000, rd, 7'h13};
    endfunction
    function automatic logic [31:0] encode_lw(input logic [4:0] rd,
                                               input logic [4:0] base_reg,
                                               input logic [11:0] imm);
        return {imm, base_reg, 3'b010, rd, 7'h03};
    endfunction    function automatic logic [31:0] encode_sw(input logic [4:0] value_reg,
                                               input logic [4:0] base_reg,
                                               input logic [11:0] imm);
        return {imm[11:5], value_reg, base_reg, 3'b010, imm[4:0], 7'h23};
    endfunction

    task automatic load_program;
        test_memory.mem[0] = encode_lw(5'd1, 5'd0, 12'd128);
        test_memory.mem[1] = encode_addi(5'd2, 5'd0, 12'd256);
        test_memory.mem[2] = encode_sw(5'd2, 5'd1, 12'd0);
        test_memory.mem[3] = encode_addi(5'd2, 5'd0, 12'd2);
        test_memory.mem[4] = encode_sw(5'd2, 5'd1, 12'd4);
        test_memory.mem[5] = encode_addi(5'd2, 5'd0, 12'd320);
        test_memory.mem[6] = encode_sw(5'd2, 5'd1, 12'd8);
        test_memory.mem[7] = encode_addi(5'd2, 5'd0, 12'd8);
        test_memory.mem[8] = encode_sw(5'd2, 5'd1, 12'd12);
        test_memory.mem[9] = encode_addi(5'd2, 5'd0, 12'd384);
        test_memory.mem[10] = encode_sw(5'd2, 5'd1, 12'd16);
        test_memory.mem[11] = encode_addi(5'd2, 5'd0, 12'd2);
        test_memory.mem[12] = encode_sw(5'd2, 5'd1, 12'd20);
        test_memory.mem[13] = encode_addi(5'd2, 5'd0, 12'd1);
        test_memory.mem[14] = encode_sw(5'd2, 5'd1, 12'd24);
        test_memory.mem[15] = encode_addi(5'd3, 5'd0, 12'd123);
        test_memory.mem[16] = encode_sw(5'd3, 5'd0, 12'd448);
        test_memory.mem[17] = 32'h0000_0063;
        test_memory.mem[32] = 32'h4000_0000;
        test_memory.mem[64] = 32'd3;
        test_memory.mem[65] = 32'd5;
        test_memory.mem[80] = 32'd7;
        test_memory.mem[81] = 32'd11;
        test_memory.mem[82] = 32'd13;
        test_memory.mem[83] = 32'd17;
        test_memory.mem[96] = 32'hdead_beef;
        test_memory.mem[97] = 32'hdead_beef;
        test_memory.mem[112] = 0;
    endtask

    task automatic run_complete;
        bit start_seen, blocked_seen, final_seen, marker_seen;
        int pim_reads, pim_responses, output_writes;
        start_seen = 0;
        blocked_seen = 0;
        final_seen = 0;
        marker_seen = 0;
        pim_reads = 0;
        pim_responses = 0;
        output_writes = 0;
        for (int cycle = 0; cycle < 1500; cycle++) begin
            @(posedge clk);
            if (error) $fatal(1, "CPU error during PIM system run");
            if (memory_read_enable && memory_write_enable)
                $fatal(1, "external RAM read/write collision");
            if (dut.mmio_req_valid && dut.mmio_req_ready
                && dut.mmio_req_write && dut.mmio_req_addr == 32'h4000_0018) begin
                if (start_seen || dut.pim_busy || !dut.cpu_req_ready)
                    $fatal(1, "START store did not complete while idle");
                start_seen = 1;
                #1;
                if (!dut.pim_busy || dut.cpu_req_ready)
                    $fatal(1, "registered busy did not follow START acceptance");
            end else if (start_seen) begin
                if (dut.pim_busy && dut.cpu_req_valid) begin
                    blocked_seen = 1;
                    if (dut.cpu_req_ready || dut.ram_req_valid || dut.mmio_req_valid)
                        $fatal(1, "CPU request escaped busy router block");
                end
                if (dut.pim_req_valid && dut.pim_req_ready && !dut.pim_req_write)
                    pim_reads++;
                if (dut.pim_rsp_valid) begin
                    pim_responses++;
                    if (dut.cpu_rsp_valid || dut.ram_rsp_valid)
                        $fatal(1, "PIM RAM response appeared on CPU channel");
                end
                if (memory_write_enable && memory_address == 32'h0000_01c0) begin
                    if (!final_seen || dut.pim_busy)
                        $fatal(1, "CPU resumed before final PIM write acceptance");
                    marker_seen = 1;
                    if (memory_write_data != 123) $fatal(1, "CPU marker data incorrect");
                end
                if (memory_write_enable
                    && memory_address >= 32'h0000_0180
                    && memory_address <= 32'h0000_0184) begin
                    if (!dut.pim_req_valid || !dut.pim_req_ready || !dut.pim_req_write)
                        $fatal(1, "PIM write did not reach external RAM");
                    if (!dut.pim_busy) $fatal(1, "busy dropped before result write");
                    if (memory_address != 32'h0000_0180 + 32'(output_writes * 4))
                        $fatal(1, "output write order incorrect");
                    if (memory_write_data != (output_writes == 0 ? 32'd76 : 32'd124))
                        $fatal(1, "output arithmetic incorrect");
                    output_writes++;
                    if (output_writes == 2) begin
                        final_seen = 1;
                        #1;
                        if (dut.pim_busy) $fatal(1, "busy remained high after final write");
                    end
                end
                if (marker_seen) break;
            end
        end
        if (!start_seen || !blocked_seen || !final_seen || !marker_seen
            || output_writes != 2 || pim_reads != 6 || pim_responses != 6)
            $fatal(1, "incomplete CPU/PIM routing coverage: start=%0b blocked=%0b final=%0b marker=%0b writes=%0d reads=%0d responses=%0d",
                   start_seen, blocked_seen, final_seen, marker_seen,
                   output_writes, pim_reads, pim_responses);
        @(negedge clk);
        if (test_memory.mem[96] != 76 || test_memory.mem[97] != 124
            || test_memory.mem[112] != 123)
            $fatal(1, "external RAM results incorrect");
    endtask

    task automatic run_reset_after_first_write;
        bit first_seen;
        first_seen = 0;
        for (int cycle = 0; cycle < 1500; cycle++) begin
            @(posedge clk);
            if (error) $fatal(1, "CPU error before reset injection");
            if (memory_write_enable && memory_address == 32'h0000_0180) begin
                if (!dut.pim_busy || !dut.pim_req_valid || !dut.pim_req_ready)
                    $fatal(1, "first PIM result write not accepted");
                first_seen = 1;
                break;
            end
        end
        if (!first_seen) $fatal(1, "reset test timed out");
        @(negedge clk);
        reset = 1;
        #1;
        if (dut.pim_busy || dut.pim_req_valid || memory_write_enable)
            $fatal(1, "reset failed to abort PIM control");
        if (test_memory.mem[96] != 76 || test_memory.mem[97] != 32'hdead_beef)
            $fatal(1, "reset did not preserve only the accepted RAM write");
        repeat (2) @(negedge clk);
        reset = 0;
        repeat (5) begin
            @(negedge clk);
            if (dut.pim_busy || dut.pim_req_valid)
                $fatal(1, "aborted PIM command resumed after reset");
        end
        if (test_memory.mem[96] != 76 || test_memory.mem[97] != 32'hdead_beef)
            $fatal(1, "accepted RAM write changed after reset");
    endtask

    initial begin
        reset = 1;
        load_program();
        repeat (2) @(negedge clk);
        reset = 0;
        run_complete();
        reset = 1;
        load_program();
        repeat (2) @(negedge clk);
        reset = 0;
        run_reset_after_first_write();
        $display("PASS: opencorex_pim_subsystem_tb");
        $finish;
    end
endmodule
