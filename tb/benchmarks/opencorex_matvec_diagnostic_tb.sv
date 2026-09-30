// Compile with -GSTREAMING=0/1 and -GSUBSYSTEM=0/1 to cover both images and paths.
module opencorex_matvec_diagnostic_tb #(
    parameter int STREAMING = 0,
    parameter int SUBSYSTEM = 0
);
    localparam int MAX_CYCLES = 30_000;
    localparam logic [31:0] KERNEL_START = 32'h0000_0a00;
    localparam logic [31:0] KERNEL_LAST  = 32'h0000_0b34;
    localparam logic [31:0] VECTOR_START = 32'h0000_0100;
    localparam logic [31:0] MATRIX_START = 32'h0000_0140;
    localparam logic [31:0] OUTPUT_START = 32'h0000_0940;
    localparam logic [31:0] SIGNATURE_ADDR = 32'h0000_09c0;
    localparam logic [31:0] DONE_ADDR = 32'h0000_09c4;
    localparam logic [31:0] SIGNATURE = 32'h524b_5943;
    localparam int EXPECTED_FETCHES = (STREAMING != 0) ? 2248 : 1752;
    localparam int EXPECTED_VECTOR_READS = (STREAMING != 0) ? 512 : 16;
    localparam string IMAGE = (STREAMING != 0)
        ? "programs/hex/matvec_1x16_16x32_streaming.hex"
        : "programs/hex/matvec_1x16_16x32_resident.hex";

    logic clk;
    logic reset;
    logic memory_read_enable, memory_write_enable;
    logic [31:0] memory_address, memory_write_data, memory_read_data;
    logic error, fetch_request;
    logic [31:0] registers [0:31];
    logic [31:0] expected [0:31];
    logic [31:0] original_vector [0:15];
    logic [31:0] original_matrix [0:511];
    int unsigned instruction_fetches, vector_reads, matrix_reads;
    int unsigned signature_reads, output_writes, completion_writes;
    int unsigned mul_fetches, accumulating_add_fetches;

    initial begin
        clk = 1'b0;
        forever #5 clk = ~clk;
    end

    if (SUBSYSTEM != 0) begin : subsystem
        logic pim_req_ready, pim_rsp_valid;
        logic [31:0] pim_rsp_rdata;
        opencorex_memory_subsystem dut (
            .clk(clk), .reset(reset),
            .pim_req_valid(1'b0), .pim_req_ready(pim_req_ready),
            .pim_req_write(1'b0), .pim_req_addr(32'b0),
            .pim_req_wdata(32'b0), .pim_rsp_valid(pim_rsp_valid),
            .pim_rsp_rdata(pim_rsp_rdata),
            .memory_read_enable(memory_read_enable),
            .memory_write_enable(memory_write_enable),
            .memory_address(memory_address),
            .memory_write_data(memory_write_data),
            .memory_read_data(memory_read_data), .error(error)
        );
        assign fetch_request = dut.core_inst.MemRead &&
                               !dut.core_inst.MemAddrSource;
        for (genvar r = 0; r < 32; r++) begin : reg_view
            assign registers[r] = dut.core_inst.datapath_inst
                                      .register_file_inst.registers[r];
        end
        always_comb begin
            if (!reset && ($isunknown(pim_req_ready) ||
                           pim_rsp_valid !== 1'b0))
                $fatal(1, "unexpected idle PIM state: ready=%b response=%b data=%08h",
                       pim_req_ready, pim_rsp_valid, pim_rsp_rdata);
        end
    end else begin : direct
        logic mem_req_valid, mem_req_ready, mem_req_write, mem_rsp_valid;
        logic [31:0] mem_req_addr, mem_req_wdata, mem_rsp_rdata;
        opencorex_core dut (
            .clk(clk), .reset(reset),
            .mem_req_valid(mem_req_valid), .mem_req_ready(mem_req_ready),
            .mem_req_write(mem_req_write), .mem_req_addr(mem_req_addr),
            .mem_req_wdata(mem_req_wdata), .mem_rsp_valid(mem_rsp_valid),
            .mem_rsp_rdata(mem_rsp_rdata), .error(error)
        );
        synchronous_memory_adapter adapter (
            .clk(clk), .reset(reset),
            .req_valid(mem_req_valid), .req_ready(mem_req_ready),
            .req_write(mem_req_write), .req_addr(mem_req_addr),
            .req_wdata(mem_req_wdata), .rsp_valid(mem_rsp_valid),
            .rsp_rdata(mem_rsp_rdata),
            .memory_read_enable(memory_read_enable),
            .memory_write_enable(memory_write_enable),
            .memory_address(memory_address),
            .memory_write_data(memory_write_data),
            .memory_read_data(memory_read_data)
        );
        assign fetch_request = dut.MemRead && !dut.MemAddrSource;
        for (genvar r = 0; r < 32; r++) begin : reg_view
            assign registers[r] = dut.datapath_inst.register_file_inst.registers[r];
        end
    end

    memory #(.WORDS(1024), .INIT_FILE(IMAGE)) test_memory (
        .clk(clk), .read_enable(memory_read_enable),
        .write_enable(memory_write_enable), .address(memory_address),
        .write_data(memory_write_data), .read_data(memory_read_data)
    );

    initial $readmemh("programs/hex/matvec_1x16_16x32_expected.hex", expected);

    initial begin : run_test
        instruction_fetches = 0;
        vector_reads = 0;
        matrix_reads = 0;
        signature_reads = 0;
        output_writes = 0;
        completion_writes = 0;
        mul_fetches = 0;
        accumulating_add_fetches = 0;
        reset = 1'b1;
        repeat (2) @(posedge clk);
        for (int i = 0; i < 16; i++)
            original_vector[i] = test_memory.mem['h040 + i];
        for (int i = 0; i < 512; i++)
            original_matrix[i] = test_memory.mem['h050 + i];
        @(negedge clk);
        reset = 1'b0;

        for (int cycle = 0; cycle < MAX_CYCLES; cycle++) begin
            @(posedge clk);
            if (error !== 1'b0)
                $fatal(1, "core error at cycle %0d", cycle);
            if (memory_read_enable && memory_write_enable)
                $fatal(1, "simultaneous physical read and write");
            if ((memory_read_enable || memory_write_enable) &&
                memory_address[1:0] != 2'b00)
                $fatal(1, "misaligned access %08h", memory_address);

            if (memory_read_enable) begin
                if (fetch_request) begin
                    if (memory_address != 0 &&
                        !(memory_address >= KERNEL_START &&
                          memory_address <= KERNEL_LAST))
                        $fatal(1, "instruction fetch outside code %08h",
                               memory_address);
                    instruction_fetches++;
                    if (memory_address != 0) begin
                        logic [31:0] instruction;
                        instruction = test_memory.mem[memory_address >> 2];
                        if (instruction[6:0] == 7'b0110011 &&
                            instruction[31:25] == 7'b0000001 &&
                            instruction[14:12] == 3'b000)
                            mul_fetches++;
                        if (instruction[6:0] == 7'b0110011 &&
                            instruction[31:25] == 7'b0000000 &&
                            instruction[14:12] == 3'b000 &&
                            instruction[11:7] == 5'd11 &&
                            instruction[19:15] == 5'd11 &&
                            instruction[24:20] == 5'd14)
                            accumulating_add_fetches++;
                    end
                end else if (memory_address >= VECTOR_START &&
                             memory_address < MATRIX_START) begin
                    if (memory_address != VECTOR_START + (vector_reads % 16) * 4)
                        $fatal(1, "vector read out of order %08h", memory_address);
                    vector_reads++;
                end else if (memory_address >= MATRIX_START &&
                             memory_address < OUTPUT_START) begin
                    if (memory_address != MATRIX_START + matrix_reads * 4)
                        $fatal(1, "matrix read out of order %08h", memory_address);
                    matrix_reads++;
                end else if (memory_address == SIGNATURE_ADDR) begin
                    signature_reads++;
                end else begin
                    $fatal(1, "unexpected data read %08h", memory_address);
                end
            end
            if (memory_write_enable) begin
                if (memory_address >= OUTPUT_START &&
                    memory_address < SIGNATURE_ADDR) begin
                    if (output_writes >= 32 ||
                        memory_address != OUTPUT_START + output_writes * 4 ||
                        memory_write_data !== expected[output_writes])
                        $fatal(1, "bad output store y[%0d] %08h=%08h",
                               output_writes, memory_address, memory_write_data);
                    output_writes++;
                end else if (memory_address == DONE_ADDR) begin
                    if (output_writes != 32 || memory_write_data !== SIGNATURE)
                        $fatal(1, "early or incorrect completion store");
                    completion_writes++;
                end else begin
                    $fatal(1, "unexpected write %08h", memory_address);
                end
            end
            if (completion_writes != 0) begin
                @(negedge clk);
                if (completion_writes != 1 || instruction_fetches != EXPECTED_FETCHES ||
                    vector_reads != EXPECTED_VECTOR_READS || matrix_reads != 512 ||
                    signature_reads != 1 || output_writes != 32 ||
                    mul_fetches != 512 || accumulating_add_fetches != 512)
                    $fatal(1, "counts fetch=%0d vec=%0d matrix=%0d sig=%0d out=%0d done=%0d mul=%0d add=%0d",
                           instruction_fetches, vector_reads, matrix_reads,
                           signature_reads, output_writes, completion_writes,
                           mul_fetches, accumulating_add_fetches);
                for (int i = 0; i < 32; i++)
                    if (test_memory.mem['h250 + i] !== expected[i])
                        $fatal(1, "stored output mismatch y[%0d]", i);
                if (test_memory.mem['h271] !== SIGNATURE ||
                    registers[31] !== SIGNATURE)
                    $fatal(1, "completion signature missing");
                for (int i = 0; i < 16; i++) begin
                    if (test_memory.mem['h040 + i] !== original_vector[i])
                        $fatal(1, "vector changed at %0d", i);
                    if (STREAMING == 0 && registers[15 + i] !== original_vector[i])
                        $fatal(1, "resident x%0d changed", 15 + i);
                end
                for (int i = 0; i < 512; i++)
                    if (test_memory.mem['h050 + i] !== original_matrix[i])
                        $fatal(1, "matrix changed at %0d", i);
                $display("DIAGNOSTIC mode=%s path=%s cycles=%0d fetches=%0d vector_reads=%0d matrix_reads=%0d output_writes=%0d mul=%0d add=%0d",
                         (STREAMING != 0) ? "streaming" : "resident",
                         (SUBSYSTEM != 0) ? "subsystem" : "direct",
                         cycle + 1, instruction_fetches, vector_reads,
                         matrix_reads, output_writes, mul_fetches,
                         accumulating_add_fetches);
                $display("PASS: opencorex_matvec_diagnostic_tb");
                $finish;
            end
        end
        $fatal(1, "diagnostic timeout");
    end
endmodule
