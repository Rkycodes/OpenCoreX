module pim_vector_buffer #(
    parameter int unsigned BUFFER_WORDS = 16,
    parameter int unsigned INDEX_W = (BUFFER_WORDS <= 1) ? 1 : $clog2(BUFFER_WORDS),
    parameter int unsigned COUNT_W = $clog2(BUFFER_WORDS + 1)
) (
    input  logic                 clk,
    input  logic                 reset,
    input  logic                 begin_vector,
    input  logic [31:0]          new_vector_base,
    input  logic [31:0]          new_vector_length,
    input  logic                 invalidate,
    input  logic [INDEX_W-1:0]   query_index,
    output logic                 query_valid,
    input  logic                 read_enable,
    input  logic [INDEX_W-1:0]   read_index,
    output logic [31:0]          read_data,
    input  logic                 write_enable,
    input  logic [INDEX_W-1:0]   write_index,
    input  logic [31:0]          write_data,
    output logic [COUNT_W-1:0]   valid_count,
    output logic                 vector_full,
    output logic [31:0]          resident_vector_base,
    output logic [31:0]          resident_vector_length
);
    logic [31:0] words [0:BUFFER_WORDS-1];
    logic [BUFFER_WORDS-1:0] entry_valid;

    assign query_valid = !reset
        && (32'(query_index) < resident_vector_length)
        && (32'(query_index) < 32'(BUFFER_WORDS))
        && entry_valid[query_index];
    assign vector_full = (resident_vector_length != 32'b0)
        && (32'(valid_count) == resident_vector_length);

    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
            entry_valid <= '0;
            valid_count <= '0;
            resident_vector_base <= '0;
            resident_vector_length <= '0;
            read_data <= '0;
        end
        else begin
`ifndef SYNTHESIS
            if (read_enable && write_enable)
                $fatal(1, "pim_vector_buffer: simultaneous read and write");
            if ((begin_vector || invalidate) && (read_enable || write_enable))
                $fatal(1, "pim_vector_buffer: metadata operation with data port use");
            if (begin_vector && invalidate)
                $fatal(1, "pim_vector_buffer: simultaneous begin_vector and invalidate");
            if (begin_vector && (new_vector_length == 0
                    || new_vector_length > 32'(BUFFER_WORDS)))
                $fatal(1, "pim_vector_buffer: invalid vector length");
            if (read_enable && (32'(read_index) >= resident_vector_length
                    || 32'(read_index) >= 32'(BUFFER_WORDS)))
                $fatal(1, "pim_vector_buffer: read index outside active vector");
            if (write_enable && (32'(write_index) >= resident_vector_length
                    || 32'(write_index) >= 32'(BUFFER_WORDS)))
                $fatal(1, "pim_vector_buffer: write index outside active vector");
`endif
            if (begin_vector) begin
                resident_vector_base <= new_vector_base;
                resident_vector_length <= new_vector_length;
                entry_valid <= '0;
                valid_count <= '0;
                read_data <= '0;
            end
            else if (invalidate) begin
                resident_vector_base <= '0;
                resident_vector_length <= '0;
                entry_valid <= '0;
                valid_count <= '0;
                read_data <= '0;
            end
            else if (write_enable) begin
                words[write_index] <= write_data;
                if (!entry_valid[write_index]) begin
                    entry_valid[write_index] <= 1'b1;
                    valid_count <= valid_count + 1'b1;
                end
            end
            else if (read_enable) begin
                read_data <= entry_valid[read_index] ? words[read_index] : 32'b0;
            end
        end
    end

`ifndef SYNTHESIS
    initial begin
        if (BUFFER_WORDS == 0 || (BUFFER_WORDS & (BUFFER_WORDS - 1)) != 0)
            $fatal(1, "pim_vector_buffer: BUFFER_WORDS must be a positive power of two");
        if (INDEX_W != ((BUFFER_WORDS <= 1) ? 1 : $clog2(BUFFER_WORDS)))
            $fatal(1, "pim_vector_buffer: INDEX_W does not match BUFFER_WORDS");
        if (COUNT_W != $clog2(BUFFER_WORDS + 1))
            $fatal(1, "pim_vector_buffer: COUNT_W does not match BUFFER_WORDS");
    end
`endif
endmodule
