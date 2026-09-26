module synchronous_memory_adapter (
    input  logic        clk,
    input  logic        reset,

    // Request channel from the memory interconnect
    input  logic        req_valid,
    output logic        req_ready,
    input  logic        req_write,
    input  logic [31:0] req_addr,
    input  logic [31:0] req_wdata,

    // Read-response channel back to the memory interconnect
    output logic        rsp_valid,
    output logic [31:0] rsp_rdata,

    // Existing synchronous-memory interface
    output logic        memory_read_enable,
    output logic        memory_write_enable,
    output logic [31:0] memory_address,
    output logic [31:0] memory_write_data,
    input  logic [31:0] memory_read_data
);

    logic request_fire;
    logic accepted_read;
    logic accepted_write;

    // The current memory implementation can accept one operation on every
    // active clock edge. Reset is the only condition that blocks requests.
    assign req_ready = !reset;

    // A request affects memory only when both sides agree to the transfer.
    assign request_fire = req_valid && req_ready;
    assign accepted_read = request_fire && !req_write;
    assign accepted_write = request_fire && req_write;

    // Convert each accepted request into exactly one existing-memory enable.
    assign memory_read_enable = accepted_read;
    assign memory_write_enable = accepted_write;

    // Address and write data remain combinational. They matter to memory only
    // when the corresponding enable is asserted.
    assign memory_address = req_addr;
    assign memory_write_data = req_wdata;

    // The existing memory registers read_data on the same edge that accepts
    // memory_read_enable. After that edge, both rsp_valid and the new data are
    // visible during the response cycle.
    assign rsp_rdata = memory_read_data;

    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
            rsp_valid <= 1'b0;
        end
        else begin
            // Writes and idle cycles produce no response. Back-to-back reads
            // may keep rsp_valid asserted across consecutive response cycles.
            rsp_valid <= accepted_read;
        end
    end

endmodule
