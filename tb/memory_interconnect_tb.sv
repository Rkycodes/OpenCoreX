module memory_interconnect_tb;

    logic clk;
    logic reset;

    logic        cpu_req_valid;
    logic        cpu_req_ready;
    logic        cpu_req_write;
    logic [31:0] cpu_req_addr;
    logic [31:0] cpu_req_wdata;
    logic        cpu_rsp_valid;
    logic [31:0] cpu_rsp_rdata;

    logic        pim_req_valid;
    logic        pim_req_ready;
    logic        pim_req_write;
    logic [31:0] pim_req_addr;
    logic [31:0] pim_req_wdata;
    logic        pim_rsp_valid;
    logic [31:0] pim_rsp_rdata;

    logic        mem_req_valid;
    logic        mem_req_ready;
    logic        mem_req_write;
    logic [31:0] mem_req_addr;
    logic [31:0] mem_req_wdata;
    logic        mem_rsp_valid;
    logic [31:0] mem_rsp_rdata;

    memory_interconnect dut (
        .clk            (clk),
        .reset          (reset),

        .cpu_req_valid  (cpu_req_valid),
        .cpu_req_ready  (cpu_req_ready),
        .cpu_req_write  (cpu_req_write),
        .cpu_req_addr   (cpu_req_addr),
        .cpu_req_wdata  (cpu_req_wdata),
        .cpu_rsp_valid  (cpu_rsp_valid),
        .cpu_rsp_rdata  (cpu_rsp_rdata),

        .pim_req_valid  (pim_req_valid),
        .pim_req_ready  (pim_req_ready),
        .pim_req_write  (pim_req_write),
        .pim_req_addr   (pim_req_addr),
        .pim_req_wdata  (pim_req_wdata),
        .pim_rsp_valid  (pim_rsp_valid),
        .pim_rsp_rdata  (pim_rsp_rdata),

        .mem_req_valid  (mem_req_valid),
        .mem_req_ready  (mem_req_ready),
        .mem_req_write  (mem_req_write),
        .mem_req_addr   (mem_req_addr),
        .mem_req_wdata  (mem_req_wdata),

        .mem_rsp_valid  (mem_rsp_valid),
        .mem_rsp_rdata  (mem_rsp_rdata)
    );

    initial begin
        clk = 1'b0;
        forever #5 clk = ~clk;
    end

    task automatic check_bit (
        input logic  actual,
        input logic  expected,
        input string test_name
    );
        begin
            if (actual !== expected) begin
                $fatal(
                    1,
                    "FAIL: %s | actual=%0b expected=%0b",
                    test_name,
                    actual,
                    expected
                );
            end

            $display("PASS: %s | value=%0b", test_name, actual);
        end
    endtask

    task automatic check_word (
        input logic [31:0] actual,
        input logic [31:0] expected,
        input string       test_name
    );
        begin
            if (actual !== expected) begin
                $fatal(
                    1,
                    "FAIL: %s | actual=%08h expected=%08h",
                    test_name,
                    actual,
                    expected
                );
            end

            $display("PASS: %s | value=%08h", test_name, actual);
        end
    endtask

    task automatic drive_idle;
        begin
            cpu_req_valid = 1'b0;
            cpu_req_write = 1'b0;
            cpu_req_addr  = 32'b0;
            cpu_req_wdata = 32'b0;

            pim_req_valid = 1'b0;
            pim_req_write = 1'b0;
            pim_req_addr  = 32'b0;
            pim_req_wdata = 32'b0;

            mem_req_ready = 1'b0;
            mem_rsp_valid = 1'b0;
            mem_rsp_rdata = 32'b0;
        end
    endtask

    task automatic apply_reset;
        begin
            reset = 1'b1;
            drive_idle();

            @(posedge clk);
            #1;

            @(negedge clk);
            reset = 1'b0;
            #1;
        end
    endtask

    initial begin
        reset = 1'b1;
        drive_idle();

        // ------------------------------------------------------------
        // Test 1: Reset blocks requests.
        // ------------------------------------------------------------
        cpu_req_valid = 1'b1;
        cpu_req_addr  = 32'h0000_0040;
        mem_req_ready = 1'b1;
        #1;

        check_bit(mem_req_valid, 1'b0, "reset blocks downstream request");
        check_bit(cpu_req_ready, 1'b0, "reset blocks CPU acceptance");
        check_bit(pim_req_ready, 1'b0, "reset blocks PIM acceptance");

        // ------------------------------------------------------------
        // Test 2: Uncontended CPU read.
        // ------------------------------------------------------------
        apply_reset();

        cpu_req_valid = 1'b1;
        cpu_req_write = 1'b0;
        cpu_req_addr  = 32'h0000_0100;
        cpu_req_wdata = 32'hDEAD_BEEF;
        mem_req_ready = 1'b1;
        #1;

        check_bit(mem_req_valid, 1'b1, "CPU request reaches memory");
        check_bit(mem_req_write, 1'b0, "CPU read operation is routed");
        check_word(mem_req_addr, 32'h0000_0100, "CPU address is routed");
        check_word(mem_req_wdata, 32'hDEAD_BEEF, "CPU payload is routed");
        check_bit(cpu_req_ready, 1'b1, "CPU receives ready");
        check_bit(pim_req_ready, 1'b0, "idle PIM does not receive ready");

        // Complete the CPU handshake, then return to idle.
        @(posedge clk);
        #1;
        @(negedge clk);
        drive_idle();

        // ------------------------------------------------------------
        // Test 3: Uncontended PIM write.
        // ------------------------------------------------------------
        pim_req_valid = 1'b1;
        pim_req_write = 1'b1;
        pim_req_addr  = 32'h0000_0940;
        pim_req_wdata = 32'h1234_5678;
        mem_req_ready = 1'b1;
        #1;

        check_bit(mem_req_valid, 1'b1, "PIM request reaches memory");
        check_bit(mem_req_write, 1'b1, "PIM write operation is routed");
        check_word(mem_req_addr, 32'h0000_0940, "PIM address is routed");
        check_word(mem_req_wdata, 32'h1234_5678, "PIM data is routed");
        check_bit(cpu_req_ready, 1'b0, "idle CPU does not receive ready");
        check_bit(pim_req_ready, 1'b1, "PIM receives ready");

        @(posedge clk);
        #1;
        @(negedge clk);
        drive_idle();

        // ------------------------------------------------------------
        // Test 4: CPU wins the first conflict after reset.
        // ------------------------------------------------------------
        apply_reset();

        cpu_req_valid = 1'b1;
        cpu_req_write = 1'b0;
        cpu_req_addr  = 32'h0000_0100;

        pim_req_valid = 1'b1;
        pim_req_write = 1'b1;
        pim_req_addr  = 32'h0000_0940;
        pim_req_wdata = 32'hCAFE_BABE;

        mem_req_ready = 1'b1;
        #1;

        check_bit(cpu_req_ready, 1'b1, "CPU wins first conflict");
        check_bit(pim_req_ready, 1'b0, "PIM waits during first conflict");
        check_word(mem_req_addr, 32'h0000_0100, "CPU conflict address selected");

        // CPU request is accepted at this edge. Both request streams remain
        // valid, so round-robin arbitration must select PIM next.
        @(posedge clk);
        #1;

        check_bit(cpu_req_ready, 1'b0, "CPU waits after winning conflict");
        check_bit(pim_req_ready, 1'b1, "PIM wins next conflict");
        check_word(mem_req_addr, 32'h0000_0940, "PIM conflict address selected");

        // PIM is accepted, so priority rotates back to CPU.
        @(posedge clk);
        #1;

        check_bit(cpu_req_ready, 1'b1, "CPU wins after PIM acceptance");
        check_bit(pim_req_ready, 1'b0, "PIM waits after its acceptance");

        @(negedge clk);
        drive_idle();

        // ------------------------------------------------------------
        // Test 5: A stalled conflict locks ownership to CPU.
        // ------------------------------------------------------------
        apply_reset();

        cpu_req_valid = 1'b1;
        cpu_req_write = 1'b0;
        cpu_req_addr  = 32'h0000_0200;

        pim_req_valid = 1'b1;
        pim_req_write = 1'b0;
        pim_req_addr  = 32'h0000_0300;

        mem_req_ready = 1'b0;
        #1;

        check_bit(mem_req_valid, 1'b1, "CPU request remains visible while stalled");
        check_bit(cpu_req_ready, 1'b0, "stalled CPU does not receive ready");
        check_bit(pim_req_ready, 1'b0, "unselected PIM does not receive ready");
        check_word(mem_req_addr, 32'h0000_0200, "CPU selected before lock edge");

        // The rising edge records CPU as the locked owner.
        @(posedge clk);
        #1;

        check_word(mem_req_addr, 32'h0000_0200, "CPU remains selected after lock");

        // Remain stalled for another complete cycle. The arbiter must not
        // rotate to PIM because no request has been accepted.
        @(posedge clk);
        #1;

        check_word(mem_req_addr, 32'h0000_0200, "CPU remains selected across stall cycles");
        check_bit(cpu_req_ready, 1'b0, "CPU remains stalled");
        check_bit(pim_req_ready, 1'b0, "PIM remains unselected during lock");

        // Make memory ready. CPU must complete before PIM can be selected.
        @(negedge clk);
        mem_req_ready = 1'b1;
        #1;

        check_bit(cpu_req_ready, 1'b1, "locked CPU receives ready");
        check_bit(pim_req_ready, 1'b0, "PIM cannot bypass locked CPU");
        check_word(mem_req_addr, 32'h0000_0200, "locked CPU address is accepted");

        // CPU handshakes here. With both streams still valid, PIM becomes the
        // next selected requester immediately after the edge.
        @(posedge clk);
        #1;

        check_bit(cpu_req_ready, 1'b0, "CPU loses priority after locked request completes");
        check_bit(pim_req_ready, 1'b1, "PIM receives next grant after CPU completion");
        check_word(mem_req_addr, 32'h0000_0300, "PIM address selected after lock releases");

        @(negedge clk);
        drive_idle();

        // ------------------------------------------------------------
        // Test 6: A CPU read response returns only to the CPU.
        // ------------------------------------------------------------
        apply_reset();

        cpu_req_valid = 1'b1;
        cpu_req_write = 1'b0;
        cpu_req_addr  = 32'h0000_0400;
        mem_req_ready = 1'b1;

        // Accept the CPU read and record CPU response ownership.
        @(posedge clk);
        #1;

        @(negedge clk);
        cpu_req_valid = 1'b0;
        mem_req_ready = 1'b0;
        mem_rsp_valid = 1'b1;
        mem_rsp_rdata = 32'h1111_AAAA;
        #1;

        check_bit(cpu_rsp_valid, 1'b1, "CPU read response is valid");
        check_word(cpu_rsp_rdata, 32'h1111_AAAA, "CPU receives read data");
        check_bit(pim_rsp_valid, 1'b0, "PIM does not receive CPU response");

        @(negedge clk);
        drive_idle();

        // ------------------------------------------------------------
        // Test 7: A PIM read response returns only to PIM.
        // ------------------------------------------------------------
        apply_reset();

        pim_req_valid = 1'b1;
        pim_req_write = 1'b0;
        pim_req_addr  = 32'h0000_0500;
        mem_req_ready = 1'b1;

        // Accept the PIM read and record PIM response ownership.
        @(posedge clk);
        #1;

        @(negedge clk);
        pim_req_valid = 1'b0;
        mem_req_ready = 1'b0;
        mem_rsp_valid = 1'b1;
        mem_rsp_rdata = 32'h2222_BBBB;
        #1;

        check_bit(cpu_rsp_valid, 1'b0, "CPU does not receive PIM response");
        check_bit(pim_rsp_valid, 1'b1, "PIM read response is valid");
        check_word(pim_rsp_rdata, 32'h2222_BBBB, "PIM receives read data");

        @(negedge clk);
        drive_idle();

        // ------------------------------------------------------------
        // Test 8: A CPU response may overlap an accepted PIM write.
        // ------------------------------------------------------------
        apply_reset();

        cpu_req_valid = 1'b1;
        cpu_req_write = 1'b0;
        cpu_req_addr  = 32'h0000_0600;
        mem_req_ready = 1'b1;

        // Accept the CPU read.
        @(posedge clk);
        #1;

        // During the next cycle, return the CPU data while presenting a new
        // PIM write on the independent request path.
        @(negedge clk);
        cpu_req_valid = 1'b0;

        pim_req_valid = 1'b1;
        pim_req_write = 1'b1;
        pim_req_addr  = 32'h0000_0700;
        pim_req_wdata = 32'hCAFE_1234;

        mem_req_ready = 1'b1;
        mem_rsp_valid = 1'b1;
        mem_rsp_rdata = 32'h3333_CCCC;
        #1;

        check_bit(cpu_rsp_valid, 1'b1, "CPU response remains owned by CPU");
        check_word(cpu_rsp_rdata, 32'h3333_CCCC, "CPU receives overlapping response");
        check_bit(pim_rsp_valid, 1'b0, "PIM write does not claim CPU response");
        check_bit(pim_req_ready, 1'b1, "PIM write may proceed during CPU response");
        check_word(mem_req_addr, 32'h0000_0700, "PIM write address is routed during response");

        // Accept the PIM write. It must not modify response ownership.
        @(posedge clk);
        #1;

        check_bit(cpu_rsp_valid, 1'b1, "PIM write leaves CPU response ownership unchanged");
        check_bit(pim_rsp_valid, 1'b0, "PIM write creates no read response ownership");

        @(negedge clk);
        drive_idle();

        // ------------------------------------------------------------
        // Test 9: Back-to-back CPU and PIM reads route in order.
        // ------------------------------------------------------------
        apply_reset();

        cpu_req_valid = 1'b1;
        cpu_req_write = 1'b0;
        cpu_req_addr  = 32'h0000_0800;
        mem_req_ready = 1'b1;

        // Accept the CPU read.
        @(posedge clk);
        #1;

        // Present the CPU response while presenting the next PIM read.
        @(negedge clk);
        cpu_req_valid = 1'b0;

        pim_req_valid = 1'b1;
        pim_req_write = 1'b0;
        pim_req_addr  = 32'h0000_0900;

        mem_rsp_valid = 1'b1;
        mem_rsp_rdata = 32'h4444_DDDD;
        #1;

        check_bit(cpu_rsp_valid, 1'b1, "first back-to-back response belongs to CPU");
        check_word(cpu_rsp_rdata, 32'h4444_DDDD, "CPU receives first back-to-back data");
        check_bit(pim_rsp_valid, 1'b0, "PIM does not receive first response");
        check_bit(pim_req_ready, 1'b1, "PIM read is accepted behind CPU read");

        // At this edge, CPU consumes its response and the PIM read is
        // accepted. After the edge, response ownership becomes PIM.
        @(posedge clk);
        #1;
        mem_rsp_rdata = 32'h5555_EEEE;
        #1;

        check_bit(cpu_rsp_valid, 1'b0, "CPU does not receive second response");
        check_bit(pim_rsp_valid, 1'b1, "second back-to-back response belongs to PIM");
        check_word(pim_rsp_rdata, 32'h5555_EEEE, "PIM receives second back-to-back data");

        @(negedge clk);
        drive_idle();

        // ------------------------------------------------------------
        // Test 10: Reset suppresses an in-flight response.
        // ------------------------------------------------------------
        apply_reset();

        cpu_req_valid = 1'b1;
        cpu_req_write = 1'b0;
        cpu_req_addr  = 32'h0000_0A00;
        mem_req_ready = 1'b1;

        @(posedge clk);
        #1;

        @(negedge clk);
        cpu_req_valid = 1'b0;
        mem_rsp_valid = 1'b1;
        mem_rsp_rdata = 32'h6666_FFFF;
        reset          = 1'b1;
        #1;

        check_bit(cpu_rsp_valid, 1'b0, "reset discards CPU response");
        check_bit(pim_rsp_valid, 1'b0, "reset discards PIM response");

        $display("All request and response memory interconnect tests passed.");
        $finish;
    end

endmodule
