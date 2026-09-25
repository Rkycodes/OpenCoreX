module pim_mmio_regs_tb;
    import pim_pkg::*;

    localparam logic [31:0] BASE = 32'h4000_0000;
    logic clk;
    logic reset;
    logic req_valid;
    logic req_ready;
    logic req_write;
    logic [31:0] req_addr;
    logic [31:0] req_wdata;
    logic rsp_valid;
    logic [31:0] rsp_rdata;
    logic ctrl_busy;
    logic ctrl_done_set;
    logic ctrl_error_set;
    pim_error_t ctrl_error_code;
    logic [31:0] buffer_valid_count;
    logic buffer_vector_full;
    logic [31:0] resident_vector_base;
    logic [31:0] resident_vector_length;
    logic cmd_start;
    pim_descriptor_t cmd_descriptor;
    logic [31:0] cmd_word;
    logic buffer_invalidate;
    logic status_error;

    // A real router is included to check the START-store retirement boundary.
    logic use_router;
    logic cpu_req_valid;
    logic cpu_req_ready;
    logic cpu_req_write;
    logic [31:0] cpu_req_addr;
    logic [31:0] cpu_req_wdata;
    logic cpu_rsp_valid;
    logic [31:0] cpu_rsp_rdata;
    logic router_mmio_req_valid;
    logic router_mmio_req_write;
    logic [31:0] router_mmio_req_addr;
    logic [31:0] router_mmio_req_wdata;
    logic ram_req_valid;
    logic ram_req_write;
    logic [31:0] ram_req_addr;
    logic [31:0] ram_req_wdata;

    pim_mmio_regs #(.MMIO_BASE(BASE)) dut (
        .clk(clk), .reset(reset),
        .req_valid(req_valid), .req_ready(req_ready),
        .req_write(req_write), .req_addr(req_addr), .req_wdata(req_wdata),
        .rsp_valid(rsp_valid), .rsp_rdata(rsp_rdata),
        .ctrl_busy(ctrl_busy), .ctrl_done_set(ctrl_done_set),
        .ctrl_error_set(ctrl_error_set), .ctrl_error_code(ctrl_error_code),
        .buffer_valid_count(buffer_valid_count),
        .buffer_vector_full(buffer_vector_full),
        .resident_vector_base(resident_vector_base),
        .resident_vector_length(resident_vector_length),
        .cmd_start(cmd_start), .cmd_descriptor(cmd_descriptor),
        .cmd_word(cmd_word), .buffer_invalidate(buffer_invalidate),
        .status_error(status_error)
    );

    cpu_address_router #(.RAM_WORDS(16)) router (
        .clk(clk), .reset(reset),
        .cpu_req_valid(cpu_req_valid), .cpu_req_ready(cpu_req_ready),
        .cpu_req_write(cpu_req_write), .cpu_req_addr(cpu_req_addr),
        .cpu_req_wdata(cpu_req_wdata),
        .cpu_rsp_valid(cpu_rsp_valid), .cpu_rsp_rdata(cpu_rsp_rdata),
        .ram_req_valid(ram_req_valid), .ram_req_ready(1'b1),
        .ram_req_write(ram_req_write), .ram_req_addr(ram_req_addr),
        .ram_req_wdata(ram_req_wdata),
        .ram_rsp_valid(1'b0), .ram_rsp_rdata(32'b0),
        .mmio_req_valid(router_mmio_req_valid), .mmio_req_ready(req_ready),
        .mmio_req_write(router_mmio_req_write),
        .mmio_req_addr(router_mmio_req_addr),
        .mmio_req_wdata(router_mmio_req_wdata),
        .mmio_rsp_valid(rsp_valid), .mmio_rsp_rdata(rsp_rdata),
        .pim_busy(ctrl_busy)
    );

    always_comb begin
        req_valid = use_router ? router_mmio_req_valid : cpu_req_valid;
        req_write = use_router ? router_mmio_req_write : cpu_req_write;
        req_addr = use_router ? router_mmio_req_addr : cpu_req_addr;
        req_wdata = use_router ? router_mmio_req_wdata : cpu_req_wdata;
    end

    initial begin
        clk = 1'b0;
        forever #5 clk = ~clk;
    end

    task automatic check(input logic condition, input string message);
        if (!condition)
            $fatal(1, "CHECK FAILED: %s", message);
    endtask

    task automatic apply_reset;
        @(negedge clk);
        reset = 1'b1;
        cpu_req_valid = 1'b0;
        ctrl_busy = 1'b0;
        ctrl_done_set = 1'b0;
        ctrl_error_set = 1'b0;
        #1;
        check(!req_ready && !rsp_valid && !cmd_start && !buffer_invalidate,
              "reset suppresses protocol outputs");
        check(cmd_descriptor == '0 && !status_error,
              "reset clears configuration and error");
        @(posedge clk);
        #1;
        reset = 1'b0;
    endtask

    task automatic write_reg(input logic [11:0] offset,
                             input logic [31:0] value);
        @(negedge clk);
        cpu_req_valid = 1'b1;
        cpu_req_write = 1'b1;
        cpu_req_addr = BASE + {20'b0, offset};
        cpu_req_wdata = value;
        #1;
        check(req_ready && !rsp_valid, "write handshakes with no response");
        @(posedge clk);
        #1;
        cpu_req_valid = 1'b0;
        check(!rsp_valid, "write produces no response");
    endtask

    task automatic read_reg(input logic [11:0] offset,
                            input logic [31:0] expected);
        @(negedge clk);
        cpu_req_valid = 1'b1;
        cpu_req_write = 1'b0;
        cpu_req_addr = BASE + {20'b0, offset};
        cpu_req_wdata = 32'b0;
        #1;
        check(req_ready && !rsp_valid,
              "read has no response on request cycle");
        @(posedge clk);
        #1;
        cpu_req_valid = 1'b0;
        check(rsp_valid && rsp_rdata == expected,
              $sformatf("read %03x expected %08x got %08x", offset,
                        expected, rsp_rdata));
        check(!req_ready, "second read blocked while response pending");
        @(posedge clk);
        #1;
        check(!rsp_valid, "read response lasts exactly one cycle");
    endtask

    task automatic pulse_done;
        @(negedge clk);
        ctrl_done_set = 1'b1;
        @(posedge clk);
        #1;
        ctrl_done_set = 1'b0;
    endtask

    task automatic pulse_error(input pim_error_t code);
        @(negedge clk);
        ctrl_error_set = 1'b1;
        ctrl_error_code = code;
        @(posedge clk);
        #1;
        ctrl_error_set = 1'b0;
    endtask

    task automatic check_descriptor;
        check(cmd_descriptor.vector_base == 32'h0000_0100,
              "vector base descriptor output");
        check(cmd_descriptor.vector_length == 32'd16,
              "vector length descriptor output");
        check(cmd_descriptor.matrix_base == 32'h0000_0200,
              "matrix base descriptor output");
        check(cmd_descriptor.matrix_column_stride == 32'd64,
              "matrix stride descriptor output");
        check(cmd_descriptor.output_base == 32'h0000_1000,
              "output base descriptor output");
        check(cmd_descriptor.output_count == 32'd32,
              "output count descriptor output");
    endtask

    task automatic expect_fatal(input string selected_test);
        @(negedge clk);
        cpu_req_valid = 1'b1;
        cpu_req_write = 1'b0;
        cpu_req_wdata = 32'b0;
        cpu_req_addr = BASE + 32'h1;
        if (selected_test == "reserved")
            cpu_req_addr = BASE + 32'h50;
        else if (selected_test == "interrupt_write") begin
            cpu_req_addr = BASE + 32'h44;
            cpu_req_write = 1'b1;
        end
        else if (selected_test == "write_only_read")
            cpu_req_addr = BASE + 32'h18;
        else if (selected_test == "read_only_write") begin
            cpu_req_addr = BASE + 32'h1c;
            cpu_req_write = 1'b1;
        end
        #1;
        check(req_ready && !cmd_start && !buffer_invalidate,
              "invalid access has no side effect before fatal");
        @(posedge clk);
        #1;
        $fatal(1, "expected invalid-access fatal did not occur");
    endtask

    initial begin : run
        string selected_test;
        pim_descriptor_t saved_descriptor;
        use_router = 1'b0;
        reset = 1'b0;
        cpu_req_valid = 1'b0;
        cpu_req_write = 1'b0;
        cpu_req_addr = 32'b0;
        cpu_req_wdata = 32'b0;
        ctrl_busy = 1'b0;
        ctrl_done_set = 1'b0;
        ctrl_error_set = 1'b0;
        ctrl_error_code = PIM_ERROR_NONE;
        buffer_valid_count = 32'b0;
        buffer_vector_full = 1'b0;
        resident_vector_base = 32'b0;
        resident_vector_length = 32'b0;

        apply_reset();
        if ($value$plusargs("TEST=%s", selected_test))
            expect_fatal(selected_test);

        check(!rsp_valid && !cmd_start && !buffer_invalidate,
              "idle produces no pulses or responses");
        write_reg(PIM_REG_VECTOR_BASE, 32'h0000_0100);
        write_reg(PIM_REG_VECTOR_LENGTH, 32'd16);
        write_reg(PIM_REG_MATRIX_BASE, 32'h0000_0200);
        write_reg(PIM_REG_MATRIX_COLUMN_STRIDE, 32'd64);
        write_reg(PIM_REG_OUTPUT_BASE, 32'h0000_1000);
        write_reg(PIM_REG_OUTPUT_COUNT, 32'd32);
        check_descriptor();
        read_reg(PIM_REG_VECTOR_BASE, 32'h0000_0100);
        read_reg(PIM_REG_VECTOR_LENGTH, 32'd16);
        read_reg(PIM_REG_MATRIX_BASE, 32'h0000_0200);
        read_reg(PIM_REG_MATRIX_COLUMN_STRIDE, 32'd64);
        read_reg(PIM_REG_OUTPUT_BASE, 32'h0000_1000);
        read_reg(PIM_REG_OUTPUT_COUNT, 32'd32);
        read_reg(PIM_REG_STATUS, 32'b0);
        read_reg(PIM_REG_ERROR_CODE, 32'b0);
        read_reg(PIM_REG_CAPABILITIES, 32'h0000_0101);
        read_reg(PIM_REG_BUFFER_WORDS, 32'd16);
        read_reg(PIM_REG_MAX_OUTPUTS, 32'd32);
        read_reg(PIM_REG_MAC_LANES, 32'd1);
        read_reg(PIM_REG_INTERRUPT_ENABLE, 32'b0);
        read_reg(PIM_REG_INTERRUPT_STATUS, 32'b0);
        buffer_valid_count = 32'd8;
        buffer_vector_full = 1'b1;
        resident_vector_base = 32'h0000_0100;
        resident_vector_length = 32'd16;
        read_reg(PIM_REG_VALID_COUNT, 32'd8);
        read_reg(PIM_REG_RESIDENT_VECTOR_BASE, 32'h0000_0100);
        read_reg(PIM_REG_RESIDENT_VECTOR_LENGTH, 32'd16);
        read_reg(PIM_REG_STATUS, 32'h8);

        // START=0 with only REUSE_VECTOR is a no-op.
        write_reg(PIM_REG_COMMAND, 32'h2);
        check(!status_error && !cmd_start, "modifier alone is harmless");
        pulse_done();
        read_reg(PIM_REG_STATUS, 32'ha);

        // The router and MMIO handshake on the same START edge. Busy is
        // registered afterward; the following CPU request is blocked.
        @(negedge clk);
        use_router = 1'b1;
        cpu_req_valid = 1'b1;
        cpu_req_write = 1'b1;
        cpu_req_addr = BASE + 32'h18;
        cpu_req_wdata = 32'h3;
        #1;
        check(cpu_req_ready && cmd_start && cmd_word == 32'h3,
              "START store retires and presents raw command");
        check_descriptor();
        @(posedge clk);
        #1;
        cpu_req_valid = 1'b0;
        ctrl_busy = 1'b1;
        #1;
        check(!cmd_start && !rsp_valid,
              $sformatf("START is a single event, no response (start=%b rsp=%b)",
                        cmd_start, rsp_valid));
        @(negedge clk);
        cpu_req_valid = 1'b1;
        cpu_req_write = 1'b0;
        cpu_req_addr = 32'h0000_0000;
        #1;
        check(!cpu_req_ready && !ram_req_valid && !router_mmio_req_valid
                  && !ram_req_write && ram_req_addr == 0
                  && ram_req_wdata == 0 && !cpu_rsp_valid
                  && cpu_rsp_rdata == 0,
              "busy blocks the CPU's next request");
        cpu_req_valid = 1'b0;
        use_router = 1'b0;
        read_reg(PIM_REG_STATUS, 32'h9);
        saved_descriptor = cmd_descriptor;
        write_reg(PIM_REG_VECTOR_LENGTH, 32'd7);
        write_reg(PIM_REG_STATUS_CLEAR, 32'h6);
        write_reg(PIM_REG_BUFFER_CONTROL, 32'h1);
        check(cmd_descriptor == saved_descriptor && !buffer_invalidate,
              "busy control writes leave descriptor and buffer unchanged");
        read_reg(PIM_REG_ERROR_CODE, 32'd13);
        write_reg(PIM_REG_COMMAND, 32'h1);
        read_reg(PIM_REG_ERROR_CODE, 32'd13);
        check(status_error, "first fault survives later START while busy");
        ctrl_busy = 1'b0;
        write_reg(PIM_REG_COMMAND, 32'h1);
        check(!cmd_start, "sticky error rejects START");
        pulse_error(PIM_ERROR_INVALID_VECTOR_LENGTH);
        read_reg(PIM_REG_ERROR_CODE, 32'd13);
        read_reg(PIM_REG_STATUS, 32'hc);
        write_reg(PIM_REG_STATUS_CLEAR, 32'h2);
        read_reg(PIM_REG_STATUS, 32'hc);
        write_reg(PIM_REG_STATUS_CLEAR, 32'h4);
        read_reg(PIM_REG_ERROR_CODE, 32'b0);
        read_reg(PIM_REG_STATUS, 32'h8);

        // Exercise the MMIO-owned START=0 bit checks and their priority.
        write_reg(PIM_REG_COMMAND, 32'hc);
        read_reg(PIM_REG_ERROR_CODE, 32'd3);
        write_reg(PIM_REG_STATUS_CLEAR, 32'h4);
        write_reg(PIM_REG_COMMAND, 32'h4);
        read_reg(PIM_REG_ERROR_CODE, 32'd4);
        write_reg(PIM_REG_STATUS_CLEAR, 32'h4);
        check(cmd_descriptor == saved_descriptor,
              "rejected command actions leave descriptor unchanged");

        // Check each first-fault source from a clean state.
        ctrl_busy = 1'b1;
        write_reg(PIM_REG_COMMAND, 32'h1);
        check(!cmd_start, "busy START never launches a second command");
        read_reg(PIM_REG_ERROR_CODE, 32'd1);
        ctrl_busy = 1'b0;
        write_reg(PIM_REG_STATUS_CLEAR, 32'h4);
        pulse_error(PIM_ERROR_INVALID_VECTOR_LENGTH);
        pulse_error(PIM_ERROR_INVALID_OUTPUT_COUNT);
        read_reg(PIM_REG_ERROR_CODE, 32'd5);
        write_reg(PIM_REG_STATUS_CLEAR, 32'h4);
        pulse_done();
        read_reg(PIM_REG_STATUS, 32'ha);
        write_reg(PIM_REG_STATUS_CLEAR, 32'h2);
        read_reg(PIM_REG_STATUS, 32'h8);

        @(negedge clk);
        cpu_req_valid = 1'b1;
        cpu_req_write = 1'b1;
        cpu_req_addr = BASE + 32'h4c;
        cpu_req_wdata = 32'h1;
        #1;
        check(buffer_invalidate, "idle buffer invalidation pulse");
        @(posedge clk);
        #1;
        cpu_req_valid = 1'b0;
        #1;
        check(!buffer_invalidate && !rsp_valid,
              "invalidation has no response or repeated pulse");

        // A response captured before reset must disappear with reset.
        @(negedge clk);
        cpu_req_valid = 1'b1;
        cpu_req_write = 1'b0;
        cpu_req_addr = BASE;
        @(posedge clk);
        #1;
        cpu_req_valid = 1'b0;
        check(rsp_valid, "pre-reset read response exists");
        reset = 1'b1;
        #1;
        check(!rsp_valid && !req_ready && cmd_descriptor == '0,
              "asynchronous reset clears pending response and descriptor");
        @(posedge clk);
        #1;
        reset = 1'b0;
        read_reg(PIM_REG_STATUS, 32'h8);
        read_reg(PIM_REG_ERROR_CODE, 32'b0);
        check(!rsp_valid && !status_error, "no post-reset spurious response");
        $display("PASS: pim_mmio_regs_tb");
        $finish;
    end
endmodule
