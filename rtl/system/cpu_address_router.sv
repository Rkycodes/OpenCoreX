module cpu_address_router #(
    parameter logic [31:0] RAM_BASE = 32'h0000_0000,
    parameter int unsigned RAM_WORDS,
    parameter logic [31:0] PIM_MMIO_BASE = 32'h4000_0000,
    parameter int unsigned PIM_MMIO_BYTES = 4096
) (
    input  logic        clk,
    input  logic        reset,

    // CPU request channel
    input  logic        cpu_req_valid,
    output logic        cpu_req_ready,
    input  logic        cpu_req_write,
    input  logic [31:0] cpu_req_addr,
    input  logic [31:0] cpu_req_wdata,

    // CPU read-response channel
    output logic        cpu_rsp_valid,
    output logic [31:0] cpu_rsp_rdata,

    // RAM request channel
    output logic        ram_req_valid,
    input  logic        ram_req_ready,
    output logic        ram_req_write,
    output logic [31:0] ram_req_addr,
    output logic [31:0] ram_req_wdata,

    // RAM read-response channel
    input  logic        ram_rsp_valid,
    input  logic [31:0] ram_rsp_rdata,

    // PIM MMIO request channel
    output logic        mmio_req_valid,
    input  logic        mmio_req_ready,
    output logic        mmio_req_write,
    output logic [31:0] mmio_req_addr,
    output logic [31:0] mmio_req_wdata,

    // PIM MMIO read-response channel
    input  logic        mmio_rsp_valid,
    input  logic [31:0] mmio_rsp_rdata,

    // Registered PIM execution state. Busy blocks only new CPU requests.
    input  logic        pim_busy
);

    // Use 64-bit arithmetic so base-plus-size calculations cannot wrap at
    // the 32-bit architectural address boundary.
    localparam logic [63:0] RAM_BASE_EXT = {32'b0, RAM_BASE};
    localparam logic [63:0] RAM_BYTES_EXT = 64'(RAM_WORDS) * 64'd4;
    localparam logic [63:0] RAM_END_EXT = RAM_BASE_EXT + RAM_BYTES_EXT;
    localparam logic [63:0] MMIO_BASE_EXT = {32'b0, PIM_MMIO_BASE};
    localparam logic [63:0] MMIO_BYTES_EXT = 64'(PIM_MMIO_BYTES);
    localparam logic [63:0] MMIO_END_EXT = MMIO_BASE_EXT + MMIO_BYTES_EXT;

    logic [63:0] cpu_addr_ext;
    logic        ram_hit;
    logic        mmio_hit;

    typedef enum logic {
        RESPONSE_RAM,
        RESPONSE_MMIO
    } response_source_t;

    logic             read_pending;
    response_source_t response_source;

    logic request_fire;
    logic accepted_read;
    logic selected_rsp_valid;
    logic [31:0] selected_rsp_rdata;

    assign cpu_addr_ext = {32'b0, cpu_req_addr};
    assign ram_hit =
        ((cpu_addr_ext - RAM_BASE_EXT) < RAM_BYTES_EXT);

    assign mmio_hit =
        ((cpu_addr_ext - MMIO_BASE_EXT) < MMIO_BYTES_EXT);

    assign request_fire = cpu_req_valid && cpu_req_ready;
    assign accepted_read = request_fire && !cpu_req_write;

    // Route a new request only when the CPU is eligible to issue one. Address
    // alignment and register-offset legality remain the target's responsibility.
    always_comb begin
        cpu_req_ready = 1'b0;

        ram_req_valid = 1'b0;
        ram_req_write = 1'b0;
        ram_req_addr  = 32'b0;
        ram_req_wdata = 32'b0;

        mmio_req_valid = 1'b0;
        mmio_req_write = 1'b0;
        mmio_req_addr  = 32'b0;
        mmio_req_wdata = 32'b0;

        if (!reset && !pim_busy && !read_pending && cpu_req_valid) begin
            if (ram_hit) begin
                ram_req_valid = 1'b1;
                ram_req_write = cpu_req_write;
                ram_req_addr  = cpu_req_addr;
                ram_req_wdata = cpu_req_wdata;

                cpu_req_ready = ram_req_ready;
            end
            else if (mmio_hit) begin
                mmio_req_valid = 1'b1;
                mmio_req_write = cpu_req_write;
                mmio_req_addr  = cpu_req_addr;
                mmio_req_wdata = cpu_req_wdata;

                cpu_req_ready = mmio_req_ready;
            end
        end
    end

    // A delayed read response is selected only by the source captured when
    // that read was accepted. Current address decode and pim_busy are ignored.
    always_comb begin
        selected_rsp_valid = 1'b0;
        selected_rsp_rdata = 32'b0;
        cpu_rsp_valid = 1'b0;
        cpu_rsp_rdata = 32'b0;

        if (!reset && read_pending) begin
            unique case (response_source)
                RESPONSE_RAM: begin
                    selected_rsp_valid = ram_rsp_valid;
                    selected_rsp_rdata = ram_rsp_rdata;
                end

                RESPONSE_MMIO: begin
                    selected_rsp_valid = mmio_rsp_valid;
                    selected_rsp_rdata = mmio_rsp_rdata;
                end

                default: begin
                    // Retain safe defaults for an unknown source value.
                end
            endcase

            cpu_rsp_valid = selected_rsp_valid;
            cpu_rsp_rdata = selected_rsp_rdata;
        end
    end

    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
            read_pending   <= 1'b0;
            response_source <= RESPONSE_RAM;
        end
        else begin
            if (accepted_read) begin
                read_pending <= 1'b1;

                if (ram_hit)
                    response_source <= RESPONSE_RAM;
                else
                    response_source <= RESPONSE_MMIO;
            end
            else if (read_pending && selected_rsp_valid) begin
                read_pending <= 1'b0;
            end
        end
    end

`ifndef SYNTHESIS
    initial begin
        if (RAM_WORDS == 0)
            $fatal(1, "cpu_address_router: RAM_WORDS must be nonzero");

        if (PIM_MMIO_BYTES == 0)
            $fatal(1, "cpu_address_router: PIM_MMIO_BYTES must be nonzero");

        if ((RAM_BASE_EXT < MMIO_END_EXT)
                && (MMIO_BASE_EXT < RAM_END_EXT))
            $fatal(1, "cpu_address_router: RAM and MMIO windows overlap");
    end

    // Invalid CPU accesses have no architectural response in version 1, so
    // fail immediately in simulation while leaving synthesized routing inert.
    always @(posedge clk or posedge reset) begin
        if (reset) begin
            // Suppress access checking during asynchronous reset.
        end
        else if (!pim_busy && !read_pending && cpu_req_valid
                && !ram_hit && !mmio_hit) begin
            $fatal(1, "ILLEGAL: unmapped CPU address %08x",
                cpu_req_addr);
        end
    end
    
    logic        ram_stalled;
    logic        ram_stalled_write;
    logic [31:0] ram_stalled_addr;
    logic [31:0] ram_stalled_wdata;
    logic        mmio_stalled;
    logic        mmio_stalled_write;
    logic [31:0] mmio_stalled_addr;
    logic [31:0] mmio_stalled_wdata;

    // Protocol assertions are procedural so they run in the default Verilator
    // regression without requiring a separate assertion flag.
    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
            ram_stalled        <= 1'b0;
            ram_stalled_write  <= 1'b0;
            ram_stalled_addr   <= 32'b0;
            ram_stalled_wdata  <= 32'b0;
            mmio_stalled       <= 1'b0;
            mmio_stalled_write <= 1'b0;
            mmio_stalled_addr  <= 32'b0;
            mmio_stalled_wdata <= 32'b0;
        end
        else begin
            assert (!(ram_req_valid && mmio_req_valid))
                else $fatal(1, "cpu_address_router: multiple destinations selected");

            if (pim_busy || read_pending) begin
                assert (!cpu_req_ready && !ram_req_valid && !mmio_req_valid)
                    else $fatal(1, "cpu_address_router: request accepted while blocked");
            end

            if (ram_stalled) begin
                assert (ram_req_valid
                        && (ram_req_write == ram_stalled_write)
                        && (ram_req_addr == ram_stalled_addr)
                        && (ram_req_wdata == ram_stalled_wdata))
                    else $fatal(1, "cpu_address_router: stalled RAM payload changed");
            end

            if (mmio_stalled) begin
                assert (mmio_req_valid
                        && (mmio_req_write == mmio_stalled_write)
                        && (mmio_req_addr == mmio_stalled_addr)
                        && (mmio_req_wdata == mmio_stalled_wdata))
                    else $fatal(1, "cpu_address_router: stalled MMIO payload changed");
            end

            if (cpu_rsp_valid) begin
                assert (read_pending && selected_rsp_valid)
                    else $fatal(1, "cpu_address_router: response without ownership");

                if (response_source == RESPONSE_RAM)
                    assert (ram_rsp_valid && (cpu_rsp_rdata == ram_rsp_rdata))
                        else $fatal(1, "cpu_address_router: RAM response misrouted");
                else
                    assert (mmio_rsp_valid && (cpu_rsp_rdata == mmio_rsp_rdata))
                        else $fatal(1, "cpu_address_router: MMIO response misrouted");
            end

            ram_stalled       <= ram_req_valid && !ram_req_ready;
            ram_stalled_write <= ram_req_write;
            ram_stalled_addr  <= ram_req_addr;
            ram_stalled_wdata <= ram_req_wdata;

            mmio_stalled       <= mmio_req_valid && !mmio_req_ready;
            mmio_stalled_write <= mmio_req_write;
            mmio_stalled_addr  <= mmio_req_addr;
            mmio_stalled_wdata <= mmio_req_wdata;
        end
    end
`endif

endmodule
