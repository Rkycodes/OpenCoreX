// Blocking 512-byte instruction cache. Timing contract: comparison-contract.md.
module instruction_cache #(
    parameter bit ENABLE = 1'b0
) (
    input logic clk, reset,
    input logic cpu_req_valid, cpu_req_write, cpu_req_is_fetch,
    input logic [31:0] cpu_req_addr, cpu_req_wdata,
    output logic cpu_req_ready, cpu_rsp_valid,
    output logic [31:0] cpu_rsp_rdata,
    output logic mem_req_valid, mem_req_write,
    output logic [31:0] mem_req_addr, mem_req_wdata,
    input logic mem_req_ready, mem_rsp_valid,
    input logic [31:0] mem_rsp_rdata
);
    generate if (!ENABLE) begin : bypass
        assign mem_req_valid = !reset && cpu_req_valid;
        assign mem_req_write = cpu_req_write;
        assign mem_req_addr = cpu_req_addr;
        assign mem_req_wdata = cpu_req_wdata;
        assign cpu_req_ready = !reset && mem_req_ready;
        assign cpu_rsp_valid = !reset && mem_rsp_valid;
        assign cpu_rsp_rdata = mem_rsp_rdata;
        // Classification intentionally has no effect in bypass mode.
        wire unused_fetch = cpu_req_is_fetch;
        wire unused_clock = clk;
    end else begin : cache
        typedef enum logic [2:0] {IDLE, LOOKUP, REFILL_REQ, REFILL_WAIT,
                                  RESPONSE, DATA_WAIT} state_t;
        state_t state;
        logic [31:0] words [0:31][0:3];
        logic [22:0] tags [0:31];
        logic [31:0] valid_lines;
        logic [31:0] address, response_data;
        logic [1:0] refill_word;
        wire [4:0] index = address[8:4];
        wire [22:0] tag = address[31:9];
        wire fetch = cpu_req_is_fetch && !cpu_req_write;

        always_comb begin
            cpu_req_ready = 0;
            cpu_rsp_valid = 0;
            cpu_rsp_rdata = response_data;
            mem_req_valid = 0;
            mem_req_write = 0;
            mem_req_addr = cpu_req_addr;
            mem_req_wdata = cpu_req_wdata;
            if (!reset) begin
                case (state)
                    IDLE: begin
                        if (fetch) cpu_req_ready = 1;
                        else begin
                            mem_req_valid = cpu_req_valid;
                            mem_req_write = cpu_req_write;
                            cpu_req_ready = mem_req_ready;
                        end
                    end
                    REFILL_REQ: begin
                        mem_req_valid = 1;
                        mem_req_addr = {address[31:4], refill_word, 2'b00};
                        mem_req_wdata = 0;
                    end
                    RESPONSE: cpu_rsp_valid = 1;
                    DATA_WAIT: begin
                        cpu_rsp_valid = mem_rsp_valid;
                        cpu_rsp_rdata = mem_rsp_rdata;
                    end
                    default: begin end
                endcase
            end
        end

        always_ff @(posedge clk or posedge reset) begin
            if (reset) begin
                state <= IDLE;
                valid_lines <= 0;
                address <= 0;
                response_data <= 0;
                refill_word <= 0;
            end else begin
                case (state)
                    IDLE: if (cpu_req_valid && cpu_req_ready) begin
                        if (fetch) begin
                            address <= cpu_req_addr;
                            state <= LOOKUP;
                        end else if (!cpu_req_write) state <= DATA_WAIT;
                    end
                    LOOKUP: begin
                        assert (address[1:0] == 0) else $fatal(1, "misaligned instruction fetch");
                        if (valid_lines[index] && tags[index] == tag) begin
                            response_data <= words[index][address[3:2]];
                            state <= RESPONSE;
                        end else begin
                            valid_lines[index] <= 0;
                            refill_word <= 0;
                            state <= REFILL_REQ;
                        end
                    end
                    REFILL_REQ: if (mem_req_ready) state <= REFILL_WAIT;
                    REFILL_WAIT: if (mem_rsp_valid) begin
                        words[index][refill_word] <= mem_rsp_rdata;
                        if (refill_word == address[3:2]) response_data <= mem_rsp_rdata;
                        if (refill_word == 3) begin
                            tags[index] <= tag;
                            valid_lines[index] <= 1;
                            state <= RESPONSE;
                        end else begin
                            refill_word <= refill_word + 1'b1;
                            state <= REFILL_REQ;
                        end
                    end
                    RESPONSE: state <= IDLE;
                    DATA_WAIT: if (mem_rsp_valid) state <= IDLE;
                    default: state <= IDLE;
                endcase
            end
        end
    end endgenerate
endmodule
