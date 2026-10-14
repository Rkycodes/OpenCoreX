// Exercises the production CPU-only cache integration, independently of the PIM top.
module opencorex_cached_cpu_tb;
    logic clk=0;
    always #5 clk <= ~clk;
    logic reset=1, error;
    logic memory_read_enable, memory_write_enable;
    logic [31:0] memory_address, memory_write_data, memory_read_data;
    logic unused_pim_ready, unused_pim_valid;
    logic [31:0] unused_pim_data;
    logic [31:0] expected [0:31], operands [0:527];
    int outputs=0, fetches=0;
    opencorex_memory_subsystem #(.ICACHE_ENABLE(1'b1)) dut (
        .clk, .reset, .error, .pim_req_valid(1'b0), .pim_req_write(1'b0),
        .pim_req_addr(32'b0), .pim_req_wdata(32'b0),
        .pim_req_ready(unused_pim_ready), .pim_rsp_valid(unused_pim_valid),
        .pim_rsp_rdata(unused_pim_data), .memory_read_enable, .memory_write_enable,
        .memory_address, .memory_write_data, .memory_read_data
    );
    memory #(.WORDS(1024), .INIT_FILE("programs/hex/matvec_1x16_16x32_resident.hex")) ram (
        .clk, .read_enable(memory_read_enable), .write_enable(memory_write_enable),
        .address(memory_address), .write_data(memory_write_data), .read_data(memory_read_data)
    );
    initial begin
        $readmemh("programs/hex/matvec_1x16_16x32_expected.hex",expected);
        repeat (2) @(posedge clk);
        for (int i=0;i<528;i++) operands[i]=ram.mem['h40+i];
        @(negedge clk); reset=0;
        for (int cycle=0;cycle<20000;cycle++) begin
            @(posedge clk);
            if (error) $fatal(1,"CPU error");
            if (dut.cpu_req_valid && dut.cpu_req_ready && dut.cpu_req_is_fetch) fetches++;
            if (memory_write_enable) begin
                if (memory_address >= 'h940 && memory_address < 'h9c0) begin
                    if (outputs>=32 || memory_address != 'h940+32'(4*outputs) ||
                        memory_write_data !== expected[outputs]) $fatal(1,"output mismatch");
                    outputs++;
                end else if (memory_address == 'h9c4) begin
                    if (outputs!=32 || fetches!=1752 || cycle+1!=11738 ||
                        memory_write_data !== 32'h524b5943) $fatal(1,"completion mismatch");
                    @(negedge clk);
                    for (int i=0;i<528;i++)
                        if (ram.mem['h40+i] !== operands[i]) $fatal(1,"operand modified");
                    $display("PASS: opencorex_cached_cpu_tb 11738 cycles, 32 outputs");
                    $finish;
                end else $fatal(1,"unexpected/code RAM write");
            end
        end
        $fatal(1,"CPU timeout");
    end
endmodule
