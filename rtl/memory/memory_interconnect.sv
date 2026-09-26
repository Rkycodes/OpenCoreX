module memory_interconnect (
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

    // PIM request channel
    input  logic        pim_req_valid,
    output logic        pim_req_ready,
    input  logic        pim_req_write,
    input  logic [31:0] pim_req_addr,
    input  logic [31:0] pim_req_wdata,

    // PIM read-response channel
    output logic        pim_rsp_valid,
    output logic [31:0] pim_rsp_rdata,

    // Selected downstream memory request
    output logic        mem_req_valid,
    input  logic        mem_req_ready,
    output logic        mem_req_write,
    output logic [31:0] mem_req_addr,
    output logic [31:0] mem_req_wdata,

    // Downstream memory read response
    input  logic        mem_rsp_valid,
    input  logic [31:0] mem_rsp_rdata
);

    typedef enum logic {
        OWNER_CPU,
        OWNER_PIM
    } owner_t;

    // Requester that most recently completed a request handshake.
    // During contention, the other requester receives priority.
    owner_t last_grant;

    // A selected request must remain selected while downstream memory
    // applies backpressure.
    logic   grant_locked;
    owner_t locked_owner;

    // Owner of the most recently accepted read. This is independent of the
    // requester currently using the downstream request channel.
    owner_t response_owner;

    // Current combinational arbitration result.
    logic   grant_valid;
    owner_t grant_owner;

    // A request completes only when downstream valid and ready are both high.
    logic request_fire;
    logic accepted_read;

    assign request_fire = mem_req_valid && mem_req_ready;
    assign accepted_read = request_fire && !mem_req_write;

    // Select a requester. A locked, stalled request has priority over a new
    // arbitration decision. Otherwise, uncontended requests proceed directly
    // and simultaneous requests use round-robin history.
    always_comb begin
        grant_valid = 1'b0;
        grant_owner = OWNER_CPU;

        if (!reset) begin
            if (grant_locked) begin
                grant_valid = 1'b1;
                grant_owner = locked_owner;
            end
            else begin
                unique case ({cpu_req_valid, pim_req_valid})
                    2'b10: begin
                        grant_valid = 1'b1;
                        grant_owner = OWNER_CPU;
                    end

                    2'b01: begin
                        grant_valid = 1'b1;
                        grant_owner = OWNER_PIM;
                    end

                    2'b11: begin
                        grant_valid = 1'b1;

                        if (last_grant == OWNER_CPU)
                            grant_owner = OWNER_PIM;
                        else
                            grant_owner = OWNER_CPU;
                    end

                    default: begin
                        grant_valid = 1'b0;
                        grant_owner = OWNER_CPU;
                    end
                endcase
            end
        end
    end

    // Route only the selected request downstream. Safe defaults prevent
    // unintended transactions during reset, idle cycles, or invalid grants.
    always_comb begin
        cpu_req_ready = 1'b0;
        pim_req_ready = 1'b0;

        mem_req_valid = 1'b0;
        mem_req_write = 1'b0;
        mem_req_addr  = 32'b0;
        mem_req_wdata = 32'b0;

        cpu_rsp_valid = 1'b0;
        cpu_rsp_rdata = 32'b0;
        pim_rsp_valid = 1'b0;
        pim_rsp_rdata = 32'b0;

        if (!reset && grant_valid) begin
            case (grant_owner)
                OWNER_CPU: begin
                    mem_req_valid = cpu_req_valid;
                    mem_req_write = cpu_req_write;
                    mem_req_addr  = cpu_req_addr;
                    mem_req_wdata = cpu_req_wdata;

                    cpu_req_ready = mem_req_ready;
                end

                OWNER_PIM: begin
                    mem_req_valid = pim_req_valid;
                    mem_req_write = pim_req_write;
                    mem_req_addr  = pim_req_addr;
                    mem_req_wdata = pim_req_wdata;

                    pim_req_ready = mem_req_ready;
                end

                default: begin
                    // Retain safe defaults for an unknown owner value.
                end
            endcase
        end

        // Route a returning read response according to the owner recorded
        // when that read was accepted. The current request grant may belong
        // to a different requester.
        if (!reset && mem_rsp_valid) begin
            case (response_owner)
                OWNER_CPU: begin
                    cpu_rsp_valid = 1'b1;
                    cpu_rsp_rdata = mem_rsp_rdata;
                end

                OWNER_PIM: begin
                    pim_rsp_valid = 1'b1;
                    pim_rsp_rdata = mem_rsp_rdata;
                end

                default: begin
                    // Retain safe response defaults for an unknown owner.
                end
            endcase
        end
    end

    // Update fairness history only after an accepted request. If a selected
    // request is not accepted, lock its ownership until it handshakes.
    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
            // Initializing last_grant to PIM gives CPU the first contested
            // grant after reset.
            last_grant  <= OWNER_PIM;
            grant_locked <= 1'b0;
            locked_owner <= OWNER_CPU;
            response_owner <= OWNER_CPU;
        end
        else begin
            if (request_fire) begin
                last_grant   <= grant_owner;
                grant_locked <= 1'b0;
            end
            else if (grant_valid && !mem_req_ready && !grant_locked) begin
                grant_locked <= 1'b1;
                locked_owner <= grant_owner;
            end


            // Only accepted reads create future response ownership. Writes
            // leave this register unchanged because they produce no response.
            if (accepted_read) begin
                response_owner <= grant_owner;
            end
        end
    end

endmodule
