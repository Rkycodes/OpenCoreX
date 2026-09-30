// Test-only adapter. See docs/evaluation/memory-response-policy.md.
module latency_memory_responder (
    input logic clk, reset,
    input int read_delay, fetch_delay,
    input logic is_fetch,
    input logic req_valid,
    output logic req_ready,
    input logic req_write,
    input logic [31:0] req_addr, req_wdata,
    output logic rsp_valid,
    output logic [31:0] rsp_rdata,
    output logic memory_read_enable, memory_write_enable,
    output logic [31:0] memory_address, memory_write_data,
    input logic [31:0] memory_read_data
);
    int remaining;
    assign req_ready = !reset && remaining == 0 && !rsp_valid;
    assign memory_read_enable = req_valid && req_ready && !req_write;
    assign memory_write_enable = req_valid && req_ready && req_write;
    assign memory_address = req_addr;
    assign memory_write_data = req_wdata;
    assign rsp_rdata = memory_read_data;

    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
            remaining <= 0;
            rsp_valid <= 0;
        end else begin
            rsp_valid <= 0;
            if (read_delay < 1 || fetch_delay < 1)
                $fatal(1, "latency must be positive");
            if (remaining > 0) begin
                remaining <= remaining - 1;
                if (remaining == 1) rsp_valid <= 1;
            end
            if (memory_read_enable) begin
                remaining <= (is_fetch ? fetch_delay : read_delay) - 1;
                if ((is_fetch ? fetch_delay : read_delay) == 1)
                    rsp_valid <= 1;
            end
        end
    end
endmodule
