module pim_command_validator #(
    parameter logic [31:0] RAM_BASE = 32'h0000_0000,
    parameter int unsigned RAM_WORDS = 1024,
    parameter int unsigned BUFFER_WORDS = 16,
    parameter int unsigned MAX_OUTPUTS = 32
) (
    input  logic                     clk,
    input  logic                     reset,
    input  logic                     start,
    input  pim_pkg::pim_descriptor_t descriptor,
    input  logic [31:0]              command_word,
    input  logic                     buffer_vector_full,
    input  logic [31:0]              resident_vector_base,
    input  logic [31:0]              resident_vector_length,
    output logic                     busy,
    output logic                     result_valid,
    output logic                     result_ok,
    output pim_pkg::pim_error_t      result_error_code
);
    import pim_pkg::*;

    typedef enum logic [3:0] {
        ST_IDLE, ST_RESERVED, ST_MODE, ST_VECTOR_LENGTH, ST_OUTPUT_COUNT,
        ST_ALIGNMENT, ST_STRIDE, ST_OVERFLOW, ST_RAM_BOUNDS, ST_OVERLAP,
        ST_REUSE
    } state_t;

    state_t state_q;
    state_t state_d;
    logic check_failed;
    pim_error_t check_error;
    logic [63:0] vector_end;
    logic [63:0] matrix_end;
    logic [63:0] output_end;
    logic [63:0] ram_end;
    logic [63:0] minimum_stride;

    localparam logic [63:0] ADDRESS_SPACE_END = 64'h0000_0001_0000_0000;

    assign busy = (state_q != ST_IDLE);

        logic vector_below_ram;
    logic matrix_below_ram;
    logic output_below_ram;

    generate
        if (RAM_BASE == 32'b0) begin : g_zero_ram_base
            assign vector_below_ram = 1'b0;
            assign matrix_below_ram = 1'b0;
            assign output_below_ram = 1'b0;
        end
        else begin : g_nonzero_ram_base
            assign vector_below_ram = descriptor.vector_base < RAM_BASE;
            assign matrix_below_ram = descriptor.matrix_base < RAM_BASE;
            assign output_below_ram = descriptor.output_base < RAM_BASE;
        end
    endgenerate

    // The future controller holds these active inputs stable until validation
    // completes. All range endpoints are exclusive and remain widened.
    always_comb begin
        minimum_stride = 64'd4 * {32'b0, descriptor.vector_length};
        vector_end = {32'b0, descriptor.vector_base} + minimum_stride;
        matrix_end = {32'b0, descriptor.matrix_base}
            + (({32'b0, descriptor.output_count} - 64'd1)
                * {32'b0, descriptor.matrix_column_stride})
            + minimum_stride;
        output_end = {32'b0, descriptor.output_base}
            + (64'd4 * {32'b0, descriptor.output_count});
        ram_end = {32'b0, RAM_BASE} + (64'd4 * 64'(RAM_WORDS));
    end

    always_comb begin
        state_d = state_q;
        check_failed = 1'b0;
        check_error = PIM_ERROR_NONE;
        unique case (state_q)
            ST_IDLE: begin
                if (start)
                    state_d = ST_RESERVED;
            end
            ST_RESERVED: begin
                state_d = ST_MODE;
                if (|command_word[31:3]) begin
                    check_failed = 1'b1;
                    check_error = PIM_ERROR_RESERVED_COMMAND_BIT;
                end
            end
            ST_MODE: begin
                state_d = ST_VECTOR_LENGTH;
                if (command_word[PIM_CMD_NONBLOCKING_BIT]) begin
                    check_failed = 1'b1;
                    check_error = PIM_ERROR_UNSUPPORTED_MODE;
                end
            end
            ST_VECTOR_LENGTH: begin
                state_d = ST_OUTPUT_COUNT;
                if (descriptor.vector_length == 0
                        || {32'b0, descriptor.vector_length} > 64'(BUFFER_WORDS)) begin
                    check_failed = 1'b1;
                    check_error = PIM_ERROR_INVALID_VECTOR_LENGTH;
                end
            end
            ST_OUTPUT_COUNT: begin
                state_d = ST_ALIGNMENT;
                if (descriptor.output_count == 0
                        || {32'b0, descriptor.output_count} > 64'(MAX_OUTPUTS)) begin
                    check_failed = 1'b1;
                    check_error = PIM_ERROR_INVALID_OUTPUT_COUNT;
                end
            end
            ST_ALIGNMENT: begin
                state_d = ST_STRIDE;
                if (|descriptor.vector_base[1:0]
                        || |descriptor.matrix_base[1:0]
                        || |descriptor.output_base[1:0]) begin
                    check_failed = 1'b1;
                    check_error = PIM_ERROR_MISALIGNED_ADDRESS;
                end
            end
            ST_STRIDE: begin
                state_d = ST_OVERFLOW;
                if (|descriptor.matrix_column_stride[1:0]
                        || {32'b0, descriptor.matrix_column_stride} < minimum_stride) begin
                    check_failed = 1'b1;
                    check_error = PIM_ERROR_INVALID_COLUMN_STRIDE;
                end
            end
            ST_OVERFLOW: begin
                state_d = ST_RAM_BOUNDS;
                if (vector_end > ADDRESS_SPACE_END
                        || matrix_end > ADDRESS_SPACE_END
                        || output_end > ADDRESS_SPACE_END) begin
                    check_failed = 1'b1;
                    check_error = PIM_ERROR_ADDRESS_OVERFLOW;
                end
            end
            ST_RAM_BOUNDS: begin
                state_d = ST_OVERLAP;
                if (vector_below_ram
                        || vector_end > ram_end
                        || matrix_below_ram
                        || matrix_end > ram_end
                        || output_below_ram
                        || output_end > ram_end) begin
                    check_failed = 1'b1;
                    check_error = PIM_ERROR_ADDRESS_OUTSIDE_RAM;
                end
            end
            ST_OVERLAP: begin
                state_d = ST_REUSE;
                if (({32'b0, descriptor.output_base} < vector_end
                            && {32'b0, descriptor.vector_base} < output_end)
                        || ({32'b0, descriptor.output_base} < matrix_end
                            && {32'b0, descriptor.matrix_base} < output_end)) begin
                    check_failed = 1'b1;
                    check_error = PIM_ERROR_INPUT_OUTPUT_OVERLAP;
                end
            end
            ST_REUSE: begin
                state_d = ST_IDLE;
                if (command_word[PIM_CMD_REUSE_VECTOR_BIT]
                        && (!buffer_vector_full
                            || resident_vector_base != descriptor.vector_base
                            || resident_vector_length != descriptor.vector_length)) begin
                    check_failed = 1'b1;
                    check_error = PIM_ERROR_VECTOR_REUSE_MISMATCH;
                end
            end
            default: state_d = ST_IDLE;
        endcase
        if (check_failed)
            state_d = ST_IDLE;
    end

    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
            state_q <= ST_IDLE;
            result_valid <= 1'b0;
            result_ok <= 1'b0;
            result_error_code <= PIM_ERROR_NONE;
        end
        else begin
`ifndef SYNTHESIS
            if (start && state_q != ST_IDLE)
                $fatal(1, "pim_command_validator: start while busy");
`endif
            state_q <= state_d;
            result_valid <= (state_q != ST_IDLE) && (check_failed || state_q == ST_REUSE);
            if (state_q != ST_IDLE && (check_failed || state_q == ST_REUSE)) begin
                result_ok <= !check_failed;
                result_error_code <= check_error;
            end
        end
    end

`ifndef SYNTHESIS
    initial begin
        if (RAM_BASE[1:0] != 2'b0)
            $fatal(1, "pim_command_validator: RAM_BASE must be word aligned");
        if (RAM_WORDS == 0
                || ({32'b0, RAM_BASE} + 64'd4 * 64'(RAM_WORDS)) > ADDRESS_SPACE_END)
            $fatal(1, "pim_command_validator: invalid RAM capacity");
        if (BUFFER_WORDS == 0 || (BUFFER_WORDS & (BUFFER_WORDS - 1)) != 0)
            $fatal(1, "pim_command_validator: BUFFER_WORDS must be a nonzero power of two");
        if (MAX_OUTPUTS == 0)
            $fatal(1, "pim_command_validator: MAX_OUTPUTS must be nonzero");
    end
`endif
endmodule
