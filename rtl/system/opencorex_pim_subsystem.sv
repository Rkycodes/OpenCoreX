module opencorex_pim_subsystem #(
    parameter int unsigned RAM_WORDS = 1024,
    parameter logic [31:0] MMIO_BASE = 32'h4000_0000,
    parameter int unsigned BUFFER_WORDS = 16,
    parameter int unsigned MAX_OUTPUTS = 32,
    parameter int unsigned MAC_LANES = 1
) (
    input logic clk,
    input logic reset,
    output logic memory_read_enable,
    output logic memory_write_enable,
    output logic [31:0] memory_address,
    output logic [31:0] memory_write_data,
    input logic [31:0] memory_read_data,
    output logic error
);
    logic cpu_req_valid, cpu_req_ready, cpu_req_write;
    logic [31:0] cpu_req_addr, cpu_req_wdata;
    logic cpu_rsp_valid;
    logic [31:0] cpu_rsp_rdata;

    logic ram_req_valid, ram_req_ready, ram_req_write;
    logic [31:0] ram_req_addr, ram_req_wdata;
    logic ram_rsp_valid;
    logic [31:0] ram_rsp_rdata;

    logic mmio_req_valid, mmio_req_ready, mmio_req_write;
    logic [31:0] mmio_req_addr, mmio_req_wdata;
    logic mmio_rsp_valid;
    logic [31:0] mmio_rsp_rdata;

    logic pim_busy, pim_req_valid, pim_req_ready, pim_req_write;
    logic [31:0] pim_req_addr, pim_req_wdata;
    logic pim_rsp_valid;
    logic [31:0] pim_rsp_rdata;

    logic mem_req_valid, mem_req_ready, mem_req_write;
    logic [31:0] mem_req_addr, mem_req_wdata;
    logic mem_rsp_valid;
    logic [31:0] mem_rsp_rdata;

    opencorex_core core_inst (
        .clk, .reset,
        .mem_req_valid(cpu_req_valid), .mem_req_ready(cpu_req_ready),
        .mem_req_write(cpu_req_write), .mem_req_addr(cpu_req_addr),
        .mem_req_wdata(cpu_req_wdata), .mem_rsp_valid(cpu_rsp_valid),
        .mem_rsp_rdata(cpu_rsp_rdata), .error
    );

    cpu_address_router #(
        .RAM_WORDS(RAM_WORDS), .PIM_MMIO_BASE(MMIO_BASE)
    ) router_inst (
        .clk, .reset, .cpu_req_valid, .cpu_req_ready, .cpu_req_write,
        .cpu_req_addr, .cpu_req_wdata, .cpu_rsp_valid, .cpu_rsp_rdata,
        .ram_req_valid, .ram_req_ready, .ram_req_write, .ram_req_addr,
        .ram_req_wdata, .ram_rsp_valid, .ram_rsp_rdata,
        .mmio_req_valid, .mmio_req_ready, .mmio_req_write,
        .mmio_req_addr, .mmio_req_wdata, .mmio_rsp_valid,
        .mmio_rsp_rdata, .pim_busy
    );

    pim_accelerator #(
        .MMIO_BASE(MMIO_BASE), .RAM_WORDS(RAM_WORDS),
        .BUFFER_WORDS(BUFFER_WORDS), .MAX_OUTPUTS(MAX_OUTPUTS),
        .MAC_LANES(MAC_LANES)
    ) accelerator_inst (
        .clk, .reset, .mmio_req_valid, .mmio_req_ready,
        .mmio_req_write, .mmio_req_addr, .mmio_req_wdata,
        .mmio_rsp_valid, .mmio_rsp_rdata, .pim_busy,
        .mem_req_valid(pim_req_valid), .mem_req_ready(pim_req_ready),
        .mem_req_write(pim_req_write), .mem_req_addr(pim_req_addr),
        .mem_req_wdata(pim_req_wdata), .mem_rsp_valid(pim_rsp_valid),
        .mem_rsp_rdata(pim_rsp_rdata)
    );

    memory_interconnect interconnect_inst (
        .clk, .reset, .cpu_req_valid(ram_req_valid),
        .cpu_req_ready(ram_req_ready), .cpu_req_write(ram_req_write),
        .cpu_req_addr(ram_req_addr), .cpu_req_wdata(ram_req_wdata),
        .cpu_rsp_valid(ram_rsp_valid), .cpu_rsp_rdata(ram_rsp_rdata),
        .pim_req_valid, .pim_req_ready, .pim_req_write,
        .pim_req_addr, .pim_req_wdata, .pim_rsp_valid,
        .pim_rsp_rdata, .mem_req_valid, .mem_req_ready,
        .mem_req_write, .mem_req_addr, .mem_req_wdata,
        .mem_rsp_valid, .mem_rsp_rdata
    );

    synchronous_memory_adapter adapter_inst (
        .clk, .reset, .req_valid(mem_req_valid), .req_ready(mem_req_ready),
        .req_write(mem_req_write), .req_addr(mem_req_addr),
        .req_wdata(mem_req_wdata), .rsp_valid(mem_rsp_valid),
        .rsp_rdata(mem_rsp_rdata), .memory_read_enable,
        .memory_write_enable, .memory_address, .memory_write_data,
        .memory_read_data
    );
endmodule
