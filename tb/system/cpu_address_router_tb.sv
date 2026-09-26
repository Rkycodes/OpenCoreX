module cpu_address_router_tb;

    localparam logic [31:0] RAM_BASE = 32'h0000_0000;
    localparam int unsigned RAM_WORDS = 16;
    localparam logic [31:0] PIM_MMIO_BASE = 32'h4000_0000;
    localparam int unsigned PIM_MMIO_BYTES = 4096;

    logic clk;
    logic reset;

    logic        cpu_req_valid;
    logic        cpu_req_ready;
    logic        cpu_req_write;
    logic [31:0] cpu_req_addr;
    logic [31:0] cpu_req_wdata;
    logic        cpu_rsp_valid;
    logic [31:0] cpu_rsp_rdata;

    logic        ram_req_valid;
    logic        ram_req_ready;
    logic        ram_req_write;
    logic [31:0] ram_req_addr;
    logic [31:0] ram_req_wdata;
    logic        ram_rsp_valid;
    logic [31:0] ram_rsp_rdata;

    logic        mmio_req_valid;
    logic        mmio_req_ready;
    logic        mmio_req_write;
    logic [31:0] mmio_req_addr;
    logic [31:0] mmio_req_wdata;
    logic        mmio_rsp_valid;
    logic [31:0] mmio_rsp_rdata;

    logic pim_busy;

    string selected_test;
    logic  source_before_write;

    cpu_address_router #(
        .RAM_BASE(RAM_BASE),
        .RAM_WORDS(RAM_WORDS),
        .PIM_MMIO_BASE(PIM_MMIO_BASE),
        .PIM_MMIO_BYTES(PIM_MMIO_BYTES)
    ) dut (
        .clk(clk),
        .reset(reset),
        .cpu_req_valid(cpu_req_valid),
        .cpu_req_ready(cpu_req_ready),
        .cpu_req_write(cpu_req_write),
        .cpu_req_addr(cpu_req_addr),
        .cpu_req_wdata(cpu_req_wdata),
        .cpu_rsp_valid(cpu_rsp_valid),
        .cpu_rsp_rdata(cpu_rsp_rdata),
        .ram_req_valid(ram_req_valid),
        .ram_req_ready(ram_req_ready),
        .ram_req_write(ram_req_write),
        .ram_req_addr(ram_req_addr),
        .ram_req_wdata(ram_req_wdata),
        .ram_rsp_valid(ram_rsp_valid),
        .ram_rsp_rdata(ram_rsp_rdata),
        .mmio_req_valid(mmio_req_valid),
        .mmio_req_ready(mmio_req_ready),
        .mmio_req_write(mmio_req_write),
        .mmio_req_addr(mmio_req_addr),
        .mmio_req_wdata(mmio_req_wdata),
        .mmio_rsp_valid(mmio_rsp_valid),
        .mmio_rsp_rdata(mmio_rsp_rdata),
        .pim_busy(pim_busy)
    );

    initial begin
        clk = 1'b0;
        forever #5 clk = ~clk;
    end

    task automatic check(input logic condition, input string message);
        if (!condition)
            $fatal(1, "CHECK FAILED: %s", message);
    endtask

    task automatic initialize_inputs;
        reset = 1'b0;
        cpu_req_valid = 1'b0;
        cpu_req_write = 1'b0;
        cpu_req_addr = 32'b0;
        cpu_req_wdata = 32'b0;
        ram_req_ready = 1'b0;
        ram_rsp_valid = 1'b0;
        ram_rsp_rdata = 32'b0;
        mmio_req_ready = 1'b0;
        mmio_rsp_valid = 1'b0;
        mmio_rsp_rdata = 32'b0;
        pim_busy = 1'b0;
    endtask

    task automatic apply_reset;
        @(negedge clk);
        reset = 1'b1;
        cpu_req_valid = 1'b1;
        ram_req_ready = 1'b1;
        ram_rsp_valid = 1'b1;
        mmio_req_ready = 1'b1;
        mmio_rsp_valid = 1'b1;
        #1;
        check(!cpu_req_ready, "reset must suppress CPU ready");
        check(!ram_req_valid && !mmio_req_valid,
              "reset must suppress downstream requests");
        check(!cpu_rsp_valid && (cpu_rsp_rdata == 32'b0),
              "reset must suppress CPU responses");

        @(posedge clk);
        #1;
        cpu_req_valid = 1'b0;
        ram_req_ready = 1'b0;
        ram_rsp_valid = 1'b0;
        mmio_req_ready = 1'b0;
        mmio_rsp_valid = 1'b0;
        reset = 1'b0;
    endtask

    task automatic check_write_route(
        input logic [31:0] address,
        input logic        expect_mmio
    );
        logic [31:0] data;

        data = address ^ 32'h5a5a_a5a5;
        @(negedge clk);
        cpu_req_valid = 1'b1;
        cpu_req_write = 1'b1;
        cpu_req_addr = address;
        cpu_req_wdata = data;
        ram_req_ready = !expect_mmio;
        mmio_req_ready = expect_mmio;
        #1;

        check(cpu_req_ready, "selected ready must reach the CPU");

        if (expect_mmio) begin
            check(mmio_req_valid && !ram_req_valid,
                  "MMIO address must select only MMIO");
            check(mmio_req_write && (mmio_req_addr == address)
                    && (mmio_req_wdata == data),
                  "complete MMIO payload must be forwarded");
        end
        else begin
            check(ram_req_valid && !mmio_req_valid,
                  "RAM address must select only RAM");
            check(ram_req_write && (ram_req_addr == address)
                    && (ram_req_wdata == data),
                  "complete RAM payload must be forwarded");
        end

        @(posedge clk);
        #1;
        cpu_req_valid = 1'b0;
        ram_req_ready = 1'b0;
        mmio_req_ready = 1'b0;
    endtask

    task automatic check_unmapped_without_clock(input logic [31:0] address);
        @(negedge clk);
        cpu_req_valid = 1'b1;
        cpu_req_write = 1'b0;
        cpu_req_addr = address;
        cpu_req_wdata = 32'hdeaf_beef;
        ram_req_ready = 1'b1;
        mmio_req_ready = 1'b1;
        #1;
        check(!cpu_req_ready && !ram_req_valid && !mmio_req_valid,
              "unmapped address must remain non-forwarding");

        // Remove the request before the rising-edge invalid-access checker.
        cpu_req_valid = 1'b0;
        ram_req_ready = 1'b0;
        mmio_req_ready = 1'b0;
    endtask

    task automatic test_selected_backpressure;
        @(negedge clk);
        cpu_req_valid = 1'b1;
        cpu_req_write = 1'b1;
        cpu_req_addr = RAM_BASE + 32'h0000_0008;
        cpu_req_wdata = 32'h1111_2222;
        ram_req_ready = 1'b0;
        mmio_req_ready = 1'b1;
        #1;
        check(ram_req_valid && !mmio_req_valid && !cpu_req_ready,
              "RAM stall must affect only the selected RAM request");

        repeat (2) begin
            @(posedge clk);
            #1;
            check(ram_req_valid && !cpu_req_ready,
                  "stalled RAM request must remain asserted");
        end

        @(negedge clk);
        ram_req_ready = 1'b1;
        #1;
        check(cpu_req_ready, "RAM ready must release the CPU stall");
        @(posedge clk);
        #1;
        cpu_req_valid = 1'b0;
        ram_req_ready = 1'b0;

        @(negedge clk);
        cpu_req_valid = 1'b1;
        cpu_req_write = 1'b1;
        cpu_req_addr = PIM_MMIO_BASE + 32'h0000_0030;
        cpu_req_wdata = 32'h3333_4444;
        ram_req_ready = 1'b1;
        mmio_req_ready = 1'b0;
        #1;
        check(mmio_req_valid && !ram_req_valid && !cpu_req_ready,
              "MMIO stall must affect only the selected MMIO request");

        @(posedge clk);
        @(negedge clk);
        mmio_req_ready = 1'b1;
        #1;
        check(cpu_req_ready, "MMIO ready must release the CPU stall");
        @(posedge clk);
        #1;
        cpu_req_valid = 1'b0;
        ram_req_ready = 1'b0;
        mmio_req_ready = 1'b0;
    endtask

    task automatic test_start_then_busy;
        // Accept the START store while registered busy is still low.
        @(negedge clk);
        cpu_req_valid = 1'b1;
        cpu_req_write = 1'b1;
        cpu_req_addr = PIM_MMIO_BASE + 32'h0000_0004;
        cpu_req_wdata = 32'h0000_0001;
        ram_req_ready = 1'b0;
        mmio_req_ready = 1'b1;
        #1;

        check(cpu_req_ready && mmio_req_valid && !ram_req_valid,
            "START store must be able to retire before busy rises");

        // The MMIO slave raises registered busy after accepting START.
        @(posedge clk);
        #1;
        pim_busy = 1'b1;
        mmio_req_ready = 1'b0;

        // Present a RAM write while busy. It must remain blocked.
        @(negedge clk);
        cpu_req_write = 1'b1;
        cpu_req_addr = RAM_BASE;
        cpu_req_wdata = 32'h5678_abcd;
        ram_req_ready = 1'b1;
        #1;

        check(!cpu_req_ready && !ram_req_valid && !mmio_req_valid,
            "registered busy must block the following CPU request");

        // Keep the same request asserted and clear busy.
        @(posedge clk);
        @(negedge clk);
        pim_busy = 1'b0;
        #1;

        check(cpu_req_ready && ram_req_valid && !mmio_req_valid,
            "traffic must resume after busy clears");

        // Complete the RAM write without creating pending read ownership.
        @(posedge clk);
        #1;
        cpu_req_valid = 1'b0;
        ram_req_ready = 1'b0;
    endtask

    task automatic test_ram_read_ownership;
        @(negedge clk);
        cpu_req_valid = 1'b1;
        cpu_req_write = 1'b0;
        cpu_req_addr = RAM_BASE + 32'h0000_0010;
        ram_req_ready = 1'b1;
        #1;
        check(cpu_req_ready && ram_req_valid,
              "RAM read must be accepted");

        @(posedge clk);
        #1;
        check(dut.read_pending, "accepted RAM read must become pending");

        // Present a second request while the first response is outstanding.
        cpu_req_addr = PIM_MMIO_BASE;
        ram_req_ready = 1'b0;
        mmio_req_ready = 1'b1;
        #1;
        check(!cpu_req_ready && !ram_req_valid && !mmio_req_valid,
              "pending read must block a second CPU request");

        repeat (2) @(posedge clk);

        // A response from the unowned source must be ignored.
        @(negedge clk);
        mmio_rsp_valid = 1'b1;
        mmio_rsp_rdata = 32'hbad0_0001;
        #1;
        check(!cpu_rsp_valid, "unowned MMIO response must be ignored");
        @(posedge clk);
        #1;
        mmio_rsp_valid = 1'b0;

        // Busy blocks requests, not the response already owned by the CPU.
        @(negedge clk);
        pim_busy = 1'b1;
        ram_rsp_valid = 1'b1;
        ram_rsp_rdata = 32'hcafe_1234;
        #1;
        check(cpu_rsp_valid && (cpu_rsp_rdata == 32'hcafe_1234),
              "pending RAM response must pass through while PIM is busy");

        @(posedge clk);
        #1;
        check(!dut.read_pending, "RAM response must clear pending state");
        ram_rsp_valid = 1'b0;
        cpu_req_valid = 1'b0;
        mmio_req_ready = 1'b0;
        pim_busy = 1'b0;
    endtask

    task automatic test_mmio_read_and_write_state;
        @(negedge clk);
        cpu_req_valid = 1'b1;
        cpu_req_write = 1'b0;
        cpu_req_addr = PIM_MMIO_BASE + 32'h0000_0014;
        mmio_req_ready = 1'b1;
        #1;
        check(cpu_req_ready && mmio_req_valid,
              "MMIO read must be accepted");

        @(posedge clk);
        #1;
        check(dut.read_pending, "accepted MMIO read must become pending");
        mmio_req_ready = 1'b0;

        @(negedge clk);
        ram_rsp_valid = 1'b1;
        ram_rsp_rdata = 32'hbad0_0002;
        #1;
        check(!cpu_rsp_valid, "unowned RAM response must be ignored");
        @(posedge clk);
        #1;
        ram_rsp_valid = 1'b0;

        repeat (2) begin
            @(posedge clk);
            #1;
            check(!cpu_rsp_valid && dut.read_pending,
                  "MMIO read must remain pending across response delay");
        end

        @(negedge clk);
        mmio_rsp_valid = 1'b1;
        mmio_rsp_rdata = 32'h1234_5678;
        #1;
        check(cpu_rsp_valid && (cpu_rsp_rdata == 32'h1234_5678),
              "owned MMIO response must reach the CPU");
        @(posedge clk);
        #1;
        mmio_rsp_valid = 1'b0;
        cpu_req_valid = 1'b0;
        check(!dut.read_pending, "MMIO response must clear pending state");

        source_before_write = dut.response_source;
        check_write_route(RAM_BASE + 32'h0000_000c, 1'b0);
        check(!dut.read_pending, "write must not create pending state");
        check(dut.response_source == source_before_write,
              "write must not overwrite response ownership");

        // With no pending read, even a late response from the prior source is ignored.
        @(negedge clk);
        mmio_rsp_valid = 1'b1;
        mmio_rsp_rdata = 32'hfeed_face;
        #1;
        check(!cpu_rsp_valid, "response with no pending read must be ignored");
        @(posedge clk);
        #1;
        mmio_rsp_valid = 1'b0;
    endtask

    task automatic test_reset_discards_pending;
        @(negedge clk);
        cpu_req_valid = 1'b1;
        cpu_req_write = 1'b0;
        cpu_req_addr = RAM_BASE + 32'h0000_0018;
        ram_req_ready = 1'b1;
        @(posedge clk);
        #1;
        check(dut.read_pending, "read must be pending before reset");

        @(negedge clk);
        reset = 1'b1;
        ram_rsp_valid = 1'b1;
        ram_rsp_rdata = 32'hffff_0000;
        #1;
        check(!cpu_rsp_valid && !cpu_req_ready
                && !ram_req_valid && !mmio_req_valid,
              "reset must suppress a pending response and all requests");
        check(!dut.read_pending, "asynchronous reset must clear ownership");

        @(posedge clk);
        @(negedge clk);
        reset = 1'b0;
        cpu_req_valid = 1'b0;
        ram_req_ready = 1'b0;
        #1;
        check(!cpu_rsp_valid,
              "late pre-reset response must remain ignored after reset");
        ram_rsp_valid = 1'b0;
    endtask

    initial begin
        initialize_inputs();

        if ($value$plusargs("TEST=%s", selected_test)
                && (selected_test == "unmapped")) begin
            apply_reset();
            @(negedge clk);
            cpu_req_valid = 1'b1;
            cpu_req_write = 1'b0;
            cpu_req_addr = RAM_BASE + (RAM_WORDS * 4);
            ram_req_ready = 1'b1;
            mmio_req_ready = 1'b1;

            // The DUT must terminate at the next rising edge.
            @(posedge clk);
            #2;
            $fatal(1, "unmapped request did not terminate simulation");
        end

        apply_reset();

        // Boundary and target-ownership checks.
        check_write_route(RAM_BASE, 1'b0);
        check_write_route(RAM_BASE + ((RAM_WORDS - 1) * 4), 1'b0);
        check_write_route(RAM_BASE + 32'h0000_0002, 1'b0);
        check_unmapped_without_clock(RAM_BASE + (RAM_WORDS * 4));

        check_write_route(PIM_MMIO_BASE, 1'b1);
        check_write_route(PIM_MMIO_BASE + PIM_MMIO_BYTES - 4, 1'b1);
        check_write_route(PIM_MMIO_BASE + 32'h0000_0380, 1'b1);
        check_write_route(PIM_MMIO_BASE + 32'h0000_0002, 1'b1);
        check_unmapped_without_clock(PIM_MMIO_BASE + PIM_MMIO_BYTES);

        test_selected_backpressure();
        test_start_then_busy();
        test_ram_read_ownership();
        test_mmio_read_and_write_state();
        test_reset_discards_pending();

        $display("PASS: cpu_address_router_tb");
        $finish;
    end

endmodule
