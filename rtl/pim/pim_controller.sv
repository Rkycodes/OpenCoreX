module pim_controller #(
    parameter int unsigned BUFFER_WORDS = 16,
    parameter int unsigned INDEX_W = (BUFFER_WORDS <= 1) ? 1 : $clog2(BUFFER_WORDS)
) (
    input logic clk, reset,
    input logic cmd_start,
    input pim_pkg::pim_descriptor_t cmd_descriptor,
    input logic [31:0] cmd_word,
    output logic busy, done_set, error_set,
    output pim_pkg::pim_error_t error_code,
    output logic validator_start,
    output pim_pkg::pim_descriptor_t validator_descriptor,
    output logic [31:0] validator_command_word,
    input logic validator_busy, validator_result_valid, validator_result_ok,
    input pim_pkg::pim_error_t validator_error_code,
    output logic buffer_begin_vector,
    output logic [31:0] buffer_new_vector_base, buffer_new_vector_length,
    output logic [INDEX_W-1:0] buffer_query_index,
    input logic buffer_query_valid,
    output logic buffer_read_enable,
    output logic [INDEX_W-1:0] buffer_read_index,
    input logic [31:0] buffer_read_data,
    output logic buffer_write_enable,
    output logic [INDEX_W-1:0] buffer_write_index,
    output logic [31:0] buffer_write_data,
    output logic mac_start,
    output logic [31:0] mac_operand_a, mac_operand_b, mac_accumulator_in,
    input logic mac_busy, mac_done,
    input logic [31:0] mac_result,
    output logic mem_req_valid,
    input logic mem_req_ready,
    output logic mem_req_write,
    output logic [31:0] mem_req_addr, mem_req_wdata,
    input logic mem_rsp_valid,
    input logic [31:0] mem_rsp_rdata
);
    import pim_pkg::*;
    typedef enum logic [3:0] {
        IDLE, VALIDATE_START, VALIDATE_WAIT, INIT_VECTOR, CHECK_VECTOR,
        READ_BUFFER, CAPTURE_BUFFER, VECTOR_REQ, VECTOR_WAIT,
        WEIGHT_REQ, WEIGHT_WAIT, MAC_START, MAC_WAIT, RESULT_REQ
    } state_t;
    typedef enum logic [1:0] {NO_READ, VECTOR_READ, WEIGHT_READ} read_owner_t;

    state_t state;
    read_owner_t read_owner;
    pim_descriptor_t active_descriptor;
    logic [31:0] active_command, vector_index, output_index;
    logic [31:0] accumulator, vector_operand, weight_operand;

    assign validator_descriptor = active_descriptor;
    assign validator_command_word = active_command;
    assign validator_start = !reset && state == VALIDATE_START && !validator_busy;
    assign buffer_begin_vector = !reset && state == INIT_VECTOR;
    assign buffer_new_vector_base = active_descriptor.vector_base;
    assign buffer_new_vector_length = active_descriptor.vector_length;
    assign buffer_query_index = vector_index[INDEX_W-1:0];
    assign buffer_read_enable = !reset && state == READ_BUFFER;
    assign buffer_read_index = vector_index[INDEX_W-1:0];
    assign buffer_write_enable = !reset && state == VECTOR_WAIT
        && read_owner == VECTOR_READ && mem_rsp_valid;
    assign buffer_write_index = vector_index[INDEX_W-1:0];
    assign buffer_write_data = mem_rsp_rdata;
    assign mac_start = !reset && state == MAC_START && !mac_busy;
    assign mac_operand_a = vector_operand;
    assign mac_operand_b = weight_operand;
    assign mac_accumulator_in = accumulator;

    always_comb begin
        mem_req_valid = 1'b0;
        mem_req_write = 1'b0;
        mem_req_addr = 32'b0;
        mem_req_wdata = 32'b0;
        if (!reset) begin
            case (state)
                VECTOR_REQ: begin
                    mem_req_valid = 1'b1;
                    mem_req_addr = active_descriptor.vector_base + (vector_index << 2);
                end
                WEIGHT_REQ: begin
                    mem_req_valid = 1'b1;
                    mem_req_addr = active_descriptor.matrix_base
                        + output_index * active_descriptor.matrix_column_stride
                        + (vector_index << 2);
                end
                RESULT_REQ: begin
                    mem_req_valid = 1'b1;
                    mem_req_write = 1'b1;
                    mem_req_addr = active_descriptor.output_base + (output_index << 2);
                    mem_req_wdata = accumulator;
                end
                default: ;
            endcase
        end
    end

    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
            state <= IDLE;
            read_owner <= NO_READ;
            active_descriptor <= '0;
            active_command <= '0;
            vector_index <= '0;
            output_index <= '0;
            accumulator <= '0;
            vector_operand <= '0;
            weight_operand <= '0;
            busy <= 1'b0;
            done_set <= 1'b0;
            error_set <= 1'b0;
            error_code <= PIM_ERROR_NONE;
        end else begin
            done_set <= 1'b0;
            error_set <= 1'b0;
            case (state)
                IDLE: if (cmd_start) begin
                    active_descriptor <= cmd_descriptor;
                    active_command <= cmd_word;
                    busy <= 1'b1;
                    state <= VALIDATE_START;
                end
                VALIDATE_START: if (!validator_busy) state <= VALIDATE_WAIT;
                VALIDATE_WAIT: if (validator_result_valid) begin
                    if (validator_result_ok) begin
                        vector_index <= '0;
                        output_index <= '0;
                        accumulator <= '0;
                        state <= active_command[PIM_CMD_REUSE_VECTOR_BIT]
                            ? CHECK_VECTOR : INIT_VECTOR;
                    end else begin
                        error_code <= validator_error_code;
                        error_set <= 1'b1;
                        busy <= 1'b0;
                        state <= IDLE;
                    end
                end
                INIT_VECTOR: state <= CHECK_VECTOR;
                CHECK_VECTOR: state <= buffer_query_valid ? READ_BUFFER : VECTOR_REQ;
                READ_BUFFER: state <= CAPTURE_BUFFER;
                CAPTURE_BUFFER: begin
                    vector_operand <= buffer_read_data;
                    state <= WEIGHT_REQ;
                end
                VECTOR_REQ: if (mem_req_ready) begin
                    read_owner <= VECTOR_READ;
                    state <= VECTOR_WAIT;
                end
                VECTOR_WAIT: if (mem_rsp_valid && read_owner == VECTOR_READ) begin
                    vector_operand <= mem_rsp_rdata;
                    read_owner <= NO_READ;
                    state <= WEIGHT_REQ;
                end
                WEIGHT_REQ: if (mem_req_ready) begin
                    read_owner <= WEIGHT_READ;
                    state <= WEIGHT_WAIT;
                end
                WEIGHT_WAIT: if (mem_rsp_valid && read_owner == WEIGHT_READ) begin
                    weight_operand <= mem_rsp_rdata;
                    read_owner <= NO_READ;
                    state <= MAC_START;
                end
                MAC_START: if (!mac_busy) state <= MAC_WAIT;
                MAC_WAIT: if (mac_done) begin
                    accumulator <= mac_result;
                    if (vector_index + 32'd1 == active_descriptor.vector_length)
                        state <= RESULT_REQ;
                    else begin
                        vector_index <= vector_index + 32'd1;
                        state <= CHECK_VECTOR;
                    end
                end
                RESULT_REQ: if (mem_req_ready) begin
                    if (output_index + 32'd1 == active_descriptor.output_count) begin
                        done_set <= 1'b1;
                        busy <= 1'b0;
                        state <= IDLE;
                    end else begin
                        output_index <= output_index + 32'd1;
                        vector_index <= '0;
                        accumulator <= '0;
                        state <= CHECK_VECTOR;
                    end
                end
                default: state <= IDLE;
            endcase
        end
    end

`ifndef SYNTHESIS
    initial begin
        if (BUFFER_WORDS == 0 || (BUFFER_WORDS & (BUFFER_WORDS - 1)) != 0)
            $fatal(1, "pim_controller: BUFFER_WORDS must be a positive power of two");
        if (INDEX_W != ((BUFFER_WORDS <= 1) ? 1 : $clog2(BUFFER_WORDS)))
            $fatal(1, "pim_controller: INDEX_W does not match BUFFER_WORDS");
    end
`endif
endmodule
