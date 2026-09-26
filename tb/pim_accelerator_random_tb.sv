module pim_accelerator_random_tb;
    import pim_pkg::*;
    localparam logic [31:0] MMIO_BASE = 32'h4000_0000;
    localparam logic [31:0] DEFAULT_SEED = 32'h6d52_7c91;
    logic clk = 0;
    always #5 clk <= ~clk;
    logic reset;
    logic req_valid, req_ready, req_write, rsp_valid;
    logic [31:0] req_addr, req_wdata, rsp_rdata;
    logic pim_busy, mem_req_valid, mem_req_ready, mem_req_write, mem_rsp_valid;
    logic [31:0] mem_req_addr, mem_req_wdata, mem_rsp_rdata;
    logic [31:0] ram [0:1023];
    logic [31:0] expected [0:31];
    logic [31:0] rng, seed;
    logic pending, held;
    logic [31:0] pending_addr, pending_data;
    logic [31:0] held_addr, held_data;
    logic held_write;
    logic [31:0] output_seen [0:1];
    logic [19:0] delay_seen;
    int delay_left, selected_delay, accepted_cycle, cycle_count;
    int run_index, vector_reads [0:1], weight_reads [0:1], output_writes [0:1];
    int responses, accepted_reads, stalled_cycles;

    pim_accelerator #(.RAM_WORDS(1024)) dut (
        .clk, .reset, .mmio_req_valid(req_valid), .mmio_req_ready(req_ready),
        .mmio_req_write(req_write), .mmio_req_addr(req_addr),
        .mmio_req_wdata(req_wdata), .mmio_rsp_valid(rsp_valid),
        .mmio_rsp_rdata(rsp_rdata), .pim_busy, .mem_req_valid,
        .mem_req_ready, .mem_req_write, .mem_req_addr, .mem_req_wdata,
        .mem_rsp_valid, .mem_rsp_rdata
    );

    assign mem_req_ready = !reset && rng[0] && rng[3];

    always @(posedge clk or posedge reset) begin
        if (reset) begin
            rng <= seed;
            pending <= 0;
            pending_addr <= 0;
            pending_data <= 0;
            delay_left <= 0;
            selected_delay <= 0;
            accepted_cycle <= 0;
            cycle_count <= 0;
            mem_rsp_valid <= 0;
            mem_rsp_rdata <= 0;
            held <= 0;
            held_addr <= 0;
            held_data <= 0;
            held_write <= 0;
            output_seen[0] <= 0;
            output_seen[1] <= 0;
            delay_seen <= 0;
            vector_reads[0] <= 0;
            vector_reads[1] <= 0;
            weight_reads[0] <= 0;
            weight_reads[1] <= 0;
            output_writes[0] <= 0;
            output_writes[1] <= 0;
            responses <= 0;
            accepted_reads <= 0;
            stalled_cycles <= 0;
        end else begin
            rng <= {rng[30:0], rng[31] ^ rng[21] ^ rng[1] ^ rng[0]};
            cycle_count <= cycle_count + 1;
            mem_rsp_valid <= 0;
            if (held && (!mem_req_valid || mem_req_write !== held_write
                         || mem_req_addr !== held_addr || mem_req_wdata !== held_data))
                $fatal(1, "stalled PIM request payload changed");
            held <= mem_req_valid && !mem_req_ready;
            if (mem_req_valid && !mem_req_ready) begin
                held_addr <= mem_req_addr;
                held_data <= mem_req_wdata;
                held_write <= mem_req_write;
                stalled_cycles <= stalled_cycles + 1;
            end
            if (mem_req_valid && mem_req_ready) begin
                if (mem_req_addr[1:0] != 0 || mem_req_addr >= 4096)
                    $fatal(1, "PIM requested invalid RAM address");
                if (mem_req_write) begin
                    if (pending || mem_rsp_valid)
                        $fatal(1, "PIM write overlapped outstanding read");
                    if (run_index < 0 || run_index > 1
                        || mem_req_addr < 32'h940 || mem_req_addr >= 32'h9c0)
                        $fatal(1, "unexpected PIM output write");
                    if (output_seen[run_index][(mem_req_addr - 32'h940) >> 2])
                        $fatal(1, "duplicate PIM output write");
                    if (mem_req_wdata !== expected[(mem_req_addr - 32'h940) >> 2])
                        $fatal(1, "wrong PIM output data");
                    output_seen[run_index][(mem_req_addr - 32'h940) >> 2] <= 1;
                    output_writes[run_index] <= output_writes[run_index] + 1;
                    ram[mem_req_addr >> 2] <= mem_req_wdata;
                end else begin
                    if (pending || mem_rsp_valid)
                        $fatal(1, "more than one outstanding PIM read");
                    if (run_index < 0 || run_index > 1)
                        $fatal(1, "read before command");
                    pending <= 1;
                    pending_addr <= mem_req_addr;
                    pending_data <= ram[mem_req_addr >> 2];
                    selected_delay <= 1 + (int'(rng[9:5]) % 20);
                    delay_left <= int'(rng[9:5]) % 20;
                    accepted_cycle <= cycle_count;
                    delay_seen[(int'(rng[9:5]) % 20)] <= 1;
                    accepted_reads <= accepted_reads + 1;
                    if (mem_req_addr >= 32'h100 && mem_req_addr < 32'h140)
                        vector_reads[run_index] <= vector_reads[run_index] + 1;
                    else if (mem_req_addr >= 32'h140 && mem_req_addr < 32'h940)
                        weight_reads[run_index] <= weight_reads[run_index] + 1;
                    else
                        $fatal(1, "unexpected PIM read address %08x", mem_req_addr);
                end
            end
            if (pending) begin
                if (delay_left == 0) begin
                    if (cycle_count - accepted_cycle != selected_delay
                        || ram[pending_addr >> 2] !== pending_data)
                        $fatal(1, "ordered response latency or ownership violation");
                    mem_rsp_valid <= 1;
                    mem_rsp_rdata <= pending_data;
                    responses <= responses + 1;
                    pending <= 0;
                end else delay_left <= delay_left - 1;
            end
        end
    end

    task automatic mmio_write(input logic [11:0] offset, input logic [31:0] data);
        @(negedge clk);
        req_valid = 1;
        req_write = 1;
        req_addr = MMIO_BASE + {20'b0, offset};
        req_wdata = data;
        do @(posedge clk); while (!req_ready);
        @(negedge clk);
        req_valid = 0;
    endtask

    task automatic mmio_read(input logic [11:0] offset,
                             input logic [31:0] expected_data);
        @(negedge clk);
        req_valid = 1;
        req_write = 0;
        req_addr = MMIO_BASE + {20'b0, offset};
        req_wdata = 0;
        do @(posedge clk); while (!req_ready);
        @(negedge clk);
        req_valid = 0;
        if (!rsp_valid) @(posedge rsp_valid);
        if (rsp_rdata !== expected_data)
            $fatal(1, "MMIO read %03x got %08x expected %08x",
                   offset, rsp_rdata, expected_data);
    endtask

    task automatic launch_and_wait(input logic [31:0] command);
        int watchdog;
        mmio_write(PIM_REG_COMMAND, command);
        if (!pim_busy) $fatal(1, "accepted START did not set busy");
        watchdog = 0;
        while (pim_busy) begin
            @(negedge clk);
            watchdog++;
            if (watchdog > 30_000) $fatal(1, "randomized command watchdog expired");
        end
        repeat (2) @(negedge clk);
    endtask

    initial begin
        seed = DEFAULT_SEED;
        if ($value$plusargs("SEED=%h", seed) && seed == 0)
            $fatal(1, "SEED must be nonzero");
        reset = 1;
        req_valid = 0;
        req_write = 0;
        req_addr = 0;
        req_wdata = 0;
        run_index = -1;
        $readmemh("programs/hex/matvec_1x16_16x32.hex", ram);
        $readmemh("programs/hex/matvec_1x16_16x32_expected.hex", expected);
        repeat (2) @(negedge clk);
        reset = 0;
        mmio_write(PIM_REG_VECTOR_BASE, 32'h100);
        mmio_write(PIM_REG_VECTOR_LENGTH, 16);
        mmio_write(PIM_REG_MATRIX_BASE, 32'h140);
        mmio_write(PIM_REG_MATRIX_COLUMN_STRIDE, 64);
        mmio_write(PIM_REG_OUTPUT_BASE, 32'h940);
        mmio_write(PIM_REG_OUTPUT_COUNT, 32);
        run_index = 0;
        launch_and_wait(1);
        mmio_read(PIM_REG_STATUS, 32'h0000_000a);
        run_index = 1;
        launch_and_wait(3);
        mmio_read(PIM_REG_STATUS, 32'h0000_000a);

        if (vector_reads[0] != 16 || weight_reads[0] != 512
            || output_writes[0] != 32 || output_seen[0] != 32'hffff_ffff
            || vector_reads[1] != 0 || weight_reads[1] != 512
            || output_writes[1] != 32 || output_seen[1] != 32'hffff_ffff
            || accepted_reads != 1040 || responses != accepted_reads
            || pending || stalled_cycles == 0 || delay_seen != 20'hfffff)
            $fatal(1, "random stress coverage/count failure: delays=%05x stalls=%0d reads=%0d responses=%0d",
                   delay_seen, stalled_cycles, accepted_reads, responses);
        for (int i = 0; i < 32; i++)
            if (ram['h250+i] !== expected[i])
                $fatal(1, "random stress output %0d incorrect", i);
        $display("PASS: pim_accelerator_random_tb seed=%08x stalls=%0d delays=%05x",
                 seed, stalled_cycles, delay_seen);
        $finish;
    end
endmodule
