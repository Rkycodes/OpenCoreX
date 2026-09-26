module pim_accelerator_tb;
    import pim_pkg::*;
    localparam logic [31:0] MMIO_BASE = 32'h4000_0000;
    logic clk = 0;
    always #5 clk <= ~clk;
    logic reset;
    logic cpu_req_valid, cpu_req_ready, cpu_req_write, cpu_rsp_valid;
    logic [31:0] cpu_req_addr, cpu_req_wdata, cpu_rsp_rdata;
    logic mmio_req_valid, mmio_req_ready, mmio_req_write, mmio_rsp_valid;
    logic [31:0] mmio_req_addr, mmio_req_wdata, mmio_rsp_rdata;
    logic ram_req_valid, ram_req_write;
    logic [31:0] ram_req_addr, ram_req_wdata;
    logic pim_busy, mem_req_valid, mem_req_ready, mem_req_write, mem_rsp_valid;
    logic [31:0] mem_req_addr, mem_req_wdata, mem_rsp_rdata;
    logic [31:0] ram [0:127];
    logic pending;
    logic [31:0] pending_data;
    int delay_left, cycles, reads, vector_reads, writes;
    logic held;
    logic [31:0] held_addr, held_data;
    logic held_write;

    cpu_address_router #(.RAM_WORDS(128)) router (
        .clk, .reset, .cpu_req_valid, .cpu_req_ready, .cpu_req_write,
        .cpu_req_addr, .cpu_req_wdata, .cpu_rsp_valid, .cpu_rsp_rdata,
        .ram_req_valid, .ram_req_ready(1'b1), .ram_req_write, .ram_req_addr,
        .ram_req_wdata, .ram_rsp_valid(1'b0), .ram_rsp_rdata(32'b0),
        .mmio_req_valid, .mmio_req_ready, .mmio_req_write, .mmio_req_addr,
        .mmio_req_wdata, .mmio_rsp_valid, .mmio_rsp_rdata, .pim_busy
    );
    pim_accelerator #(.RAM_WORDS(128), .BUFFER_WORDS(4), .MAX_OUTPUTS(3)) dut (
        .clk, .reset, .mmio_req_valid, .mmio_req_ready, .mmio_req_write,
        .mmio_req_addr, .mmio_req_wdata, .mmio_rsp_valid, .mmio_rsp_rdata,
        .pim_busy, .mem_req_valid, .mem_req_ready, .mem_req_write,
        .mem_req_addr, .mem_req_wdata, .mem_rsp_valid, .mem_rsp_rdata
    );

    assign mem_req_ready = !reset && (cycles % 3 == 1);

    always @(posedge clk or posedge reset) begin
        if (reset) begin
            pending <= 0;
            pending_data <= 0;
            delay_left <= 0;
            cycles <= 0;
            reads <= 0;
            vector_reads <= 0;
            writes <= 0;
            mem_rsp_valid <= 0;
            mem_rsp_rdata <= 0;
            held <= 0;
            held_addr <= 0;
            held_data <= 0;
            held_write <= 0;
        end else begin
            cycles <= cycles + 1;
            mem_rsp_valid <= 0;
            if (held && (!mem_req_valid || mem_req_addr !== held_addr
                         || mem_req_write !== held_write || mem_req_wdata !== held_data))
                $fatal(1, "stalled memory request changed");
            held <= mem_req_valid && !mem_req_ready;
            if (mem_req_valid && !mem_req_ready) begin
                held_addr <= mem_req_addr;
                held_data <= mem_req_wdata;
                held_write <= mem_req_write;
            end
            if (mem_req_valid && mem_req_ready) begin
                if (mem_req_addr[1:0] != 0 || mem_req_addr >= 512)
                    $fatal(1, "memory address outside RAM");
                if (mem_req_write) begin
                    if (pending) $fatal(1, "write while read pending");
                    ram[mem_req_addr >> 2] <= mem_req_wdata;
                    writes <= writes + 1;
                end else begin
                    if (pending) $fatal(1, "second outstanding read");
                    pending <= 1;
                    pending_data <= ram[mem_req_addr >> 2];
                    delay_left <= 1 + (reads % 4);
                    reads <= reads + 1;
                    if (mem_req_addr < 8) vector_reads <= vector_reads + 1;
                end
            end
            if (pending) begin
                if (delay_left == 0) begin
                    mem_rsp_valid <= 1;
                    mem_rsp_rdata <= pending_data;
                    pending <= 0;
                end else delay_left <= delay_left - 1;
            end
        end
    end

    task automatic cpu_write(input logic [11:0] offset, input logic [31:0] data);
        @(negedge clk);
        cpu_req_valid = 1;
        cpu_req_write = 1;
        cpu_req_addr = MMIO_BASE + {20'b0, offset};
        cpu_req_wdata = data;
        do @(posedge clk); while (!cpu_req_ready);
        @(negedge clk);
        cpu_req_valid = 0;
    endtask

    task automatic cpu_read(input logic [11:0] offset, output logic [31:0] data);
        @(negedge clk);
        cpu_req_valid = 1;
        cpu_req_write = 0;
        cpu_req_addr = MMIO_BASE + {20'b0, offset};
        cpu_req_wdata = 0;
        do @(posedge clk); while (!cpu_req_ready);
        @(negedge clk);
        cpu_req_valid = 0;
        if (!cpu_rsp_valid) @(posedge cpu_rsp_valid);
        data = cpu_rsp_rdata;
    endtask

    task automatic expect_reg(input logic [11:0] offset, input logic [31:0] expected);
        logic [31:0] actual;
        cpu_read(offset, actual);
        if (actual !== expected)
            $fatal(1, "MMIO offset %03x: got %08x expected %08x", offset, actual, expected);
    endtask

    task automatic await_idle;
        int watchdog;
        watchdog = 0;
        while (pim_busy) begin
            @(negedge clk);
            watchdog++;
            if (watchdog > 500) $fatal(1, "operation timed out");
        end
        repeat (2) @(negedge clk);
    endtask

    task automatic launch(input logic [31:0] word);
        @(negedge clk);
        cpu_req_valid = 1;
        cpu_req_write = 1;
        cpu_req_addr = MMIO_BASE + {20'b0, PIM_REG_COMMAND};
        cpu_req_wdata = word;
        #1;
        if (!cpu_req_ready || !mmio_req_valid || pim_busy)
            $fatal(1, "START store was blocked before acceptance");
        @(posedge clk);
        #1;
        if (!pim_busy || cpu_req_ready !== 1'b0)
            $fatal(1, "registered busy did not follow accepted START");
        if (dut.controller.active_descriptor !== dut.mmio.cmd_descriptor
            || dut.controller.active_command != word)
            $fatal(1, "accepted command snapshot incorrect");
        @(negedge clk);
        cpu_req_valid = 1;
        cpu_req_addr = MMIO_BASE + {20'b0, PIM_REG_STATUS};
        cpu_req_write = 0;
        #1;
        if (cpu_req_ready || mmio_req_valid || ram_req_valid
            || ram_req_write || ram_req_addr != 0 || ram_req_wdata != 0)
            $fatal(1, "later CPU traffic was not blocked by busy");
        cpu_req_valid = 0;
    endtask

    initial begin
        reset = 1;
        cpu_req_valid = 0;
        cpu_req_write = 0;
        cpu_req_addr = 0;
        cpu_req_wdata = 0;
        ram[0] = 3;
        ram[1] = 5;
        ram[16] = 7;
        ram[17] = 11;
        ram[32] = 0;
        repeat (2) @(negedge clk);
        reset = 0;
        cpu_write(PIM_REG_VECTOR_BASE, 0);
        cpu_write(PIM_REG_VECTOR_LENGTH, 2);
        cpu_write(PIM_REG_MATRIX_BASE, 64);
        cpu_write(PIM_REG_MATRIX_COLUMN_STRIDE, 8);
        cpu_write(PIM_REG_OUTPUT_BASE, 128);
        cpu_write(PIM_REG_OUTPUT_COUNT, 1);
        expect_reg(PIM_REG_BUFFER_WORDS, 4);
        expect_reg(PIM_REG_MAX_OUTPUTS, 3);

        launch(1);
        await_idle();
        if (ram[32] != 76 || reads != 4 || vector_reads != 2 || writes != 1)
            $fatal(1, "cold vector result or traffic incorrect");
        expect_reg(PIM_REG_STATUS, 32'h0000_000a);
        expect_reg(PIM_REG_VALID_COUNT, 2);
        expect_reg(PIM_REG_RESIDENT_VECTOR_BASE, 0);
        expect_reg(PIM_REG_RESIDENT_VECTOR_LENGTH, 2);
        expect_reg(PIM_REG_STATUS, 32'h0000_000a);

        launch(3);
        await_idle();
        if (ram[32] != 76 || reads != 6 || vector_reads != 2 || writes != 2)
            $fatal(1, "warm reuse issued vector reads or wrong result");
        expect_reg(PIM_REG_STATUS, 32'h0000_000a);

        cpu_write(PIM_REG_BUFFER_CONTROL, 1);
        expect_reg(PIM_REG_VALID_COUNT, 0);
        expect_reg(PIM_REG_RESIDENT_VECTOR_LENGTH, 0);
        expect_reg(PIM_REG_STATUS, 32'h0000_0002);
        launch(1);
        await_idle();
        if (ram[32] != 76 || reads != 10 || vector_reads != 4 || writes != 3)
            $fatal(1, "invalidation did not force refill");
        expect_reg(PIM_REG_VALID_COUNT, 2);

        cpu_write(PIM_REG_VECTOR_LENGTH, 0);
        launch(1);
        await_idle();
        if (reads != 10 || writes != 3 || vector_reads != 4)
            $fatal(1, "validation rejection caused memory traffic");
        expect_reg(PIM_REG_STATUS, 32'h0000_000c);
        expect_reg(PIM_REG_ERROR_CODE, {24'b0, PIM_ERROR_INVALID_VECTOR_LENGTH});
        expect_reg(PIM_REG_STATUS, 32'h0000_000c);
        cpu_write(PIM_REG_STATUS_CLEAR, 32'h0000_0006);
        expect_reg(PIM_REG_STATUS, 32'h0000_0008);
        expect_reg(PIM_REG_ERROR_CODE, 0);

        cpu_write(PIM_REG_VECTOR_LENGTH, 2);
        launch(1);
        wait (mem_req_valid || pending);
        @(negedge clk);
        reset = 1;
        cpu_req_valid = 0;
        #1;
        if (pim_busy || mem_req_valid || mem_rsp_valid)
            $fatal(1, "reset did not abort operation");
        @(negedge clk);
        reset = 0;
        repeat (5) @(negedge clk);
        if (pim_busy || mem_req_valid || reads != 0 || writes != 0)
            $fatal(1, "aborted operation resumed after reset");
        expect_reg(PIM_REG_STATUS, 0);
        expect_reg(PIM_REG_VALID_COUNT, 0);
        $display("PASS: pim_accelerator_tb");
        $finish;
    end
endmodule
