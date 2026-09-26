module opencorex_memory_subsystem (
    input  logic        clk,
    input  logic        reset,

    // External PIM request channel
    input  logic        pim_req_valid,
    output logic        pim_req_ready,
    input  logic        pim_req_write,
    input  logic [31:0] pim_req_addr,
    input  logic [31:0] pim_req_wdata,

    // External PIM read-response channel
    output logic        pim_rsp_valid,
    output logic [31:0] pim_rsp_rdata,

    // Existing external synchronous-memory interface
    output logic        memory_read_enable,
    output logic        memory_write_enable,
    output logic [31:0] memory_address,
    output logic [31:0] memory_write_data,
    input  logic [31:0] memory_read_data,

    // CPU status
    output logic        error
);

    // CPU-side request and response channels.
    logic        cpu_req_valid;
    logic        cpu_req_ready;
    logic        cpu_req_write;
    logic [31:0] cpu_req_addr;
    logic [31:0] cpu_req_wdata;
    logic        cpu_rsp_valid;
    logic [31:0] cpu_rsp_rdata;

    // Interconnect-to-adapter request and response channels.
    logic        mem_req_valid;
    logic        mem_req_ready;
    logic        mem_req_write;
    logic [31:0] mem_req_addr;
    logic [31:0] mem_req_wdata;
    logic        mem_rsp_valid;
    logic [31:0] mem_rsp_rdata;

    opencorex_core core_inst (
        .clk            (clk),
        .reset          (reset),

        .mem_req_valid  (cpu_req_valid),
        .mem_req_ready  (cpu_req_ready),
        .mem_req_write  (cpu_req_write),
        .mem_req_addr   (cpu_req_addr),
        .mem_req_wdata  (cpu_req_wdata),

        .mem_rsp_valid  (cpu_rsp_valid),
        .mem_rsp_rdata  (cpu_rsp_rdata),

        .error          (error)
    );

    memory_interconnect interconnect_inst (
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

    synchronous_memory_adapter adapter_inst (
        .clk                 (clk),
        .reset               (reset),

        .req_valid           (mem_req_valid),
        .req_ready           (mem_req_ready),
        .req_write           (mem_req_write),
        .req_addr            (mem_req_addr),
        .req_wdata           (mem_req_wdata),

        .rsp_valid           (mem_rsp_valid),
        .rsp_rdata           (mem_rsp_rdata),

        .memory_read_enable  (memory_read_enable),
        .memory_write_enable (memory_write_enable),
        .memory_address      (memory_address),
        .memory_write_data   (memory_write_data),
        .memory_read_data    (memory_read_data)
    );

endmodule
