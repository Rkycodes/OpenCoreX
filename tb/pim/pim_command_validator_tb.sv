module pim_command_validator_tb;
    import pim_pkg::*;

    logic clk = 1'b0;
    always #5 clk <= ~clk;

    logic reset;
    logic start;
    pim_descriptor_t descriptor;
    logic [31:0] command_word;
    logic buffer_vector_full;
    logic [31:0] resident_vector_base;
    logic [31:0] resident_vector_length;
    logic busy;
    logic result_valid;
    logic result_ok;
    pim_error_t result_error_code;

    logic small_start;
    pim_descriptor_t small_descriptor;
    logic small_busy;
    logic small_result_valid;
    logic small_result_ok;
    pim_error_t small_result_error_code;

    logic high_start;
    pim_descriptor_t high_descriptor;
    logic high_busy;
    logic high_result_valid;
    logic high_result_ok;
    pim_error_t high_result_error_code;

    int cases_run = 0;

    pim_command_validator #(
        .RAM_WORDS(1024), .BUFFER_WORDS(16), .MAX_OUTPUTS(32)
    ) dut (
        .clk, .reset, .start, .descriptor, .command_word,
        .buffer_vector_full, .resident_vector_base, .resident_vector_length,
        .busy, .result_valid, .result_ok, .result_error_code
    );

    pim_command_validator #(
        .RAM_WORDS(1024), .BUFFER_WORDS(1), .MAX_OUTPUTS(1)
    ) small_dut (
        .clk, .reset, .start(small_start), .descriptor(small_descriptor),
        .command_word(32'h0000_0001), .buffer_vector_full(1'b0),
        .resident_vector_base(32'b0), .resident_vector_length(32'b0),
        .busy(small_busy), .result_valid(small_result_valid),
        .result_ok(small_result_ok), .result_error_code(small_result_error_code)
    );

    pim_command_validator #(
        .RAM_BASE(32'hffff_f000), .RAM_WORDS(1024),
        .BUFFER_WORDS(16), .MAX_OUTPUTS(32)
    ) high_dut (
        .clk, .reset, .start(high_start), .descriptor(high_descriptor),
        .command_word(32'h0000_0001), .buffer_vector_full(1'b0),
        .resident_vector_base(32'b0), .resident_vector_length(32'b0),
        .busy(high_busy), .result_valid(high_result_valid),
        .result_ok(high_result_ok), .result_error_code(high_result_error_code)
    );

    function automatic pim_descriptor_t canonical();
        pim_descriptor_t d;
        d.vector_base = 32'h0000_0100;
        d.vector_length = 32'd16;
        d.matrix_base = 32'h0000_0140;
        d.matrix_column_stride = 32'd64;
        d.output_base = 32'h0000_0940;
        d.output_count = 32'd32;
        return d;
    endfunction

    function automatic pim_descriptor_t high_canonical();
        pim_descriptor_t d;
        d.vector_base = 32'hffff_f000;
        d.vector_length = 32'd16;
        d.matrix_base = 32'hffff_f040;
        d.matrix_column_stride = 32'd64;
        d.output_base = 32'hffff_fffc;
        d.output_count = 32'd1;
        return d;
    endfunction

    task automatic run_case(
        input string label,
        input pim_descriptor_t d,
        input logic [31:0] word,
        input logic full,
        input logic [31:0] resident_base,
        input logic [31:0] resident_length,
        input pim_error_t expected,
        input int latency
    );
        @(negedge clk);
        descriptor = d;
        command_word = word;
        buffer_vector_full = full;
        resident_vector_base = resident_base;
        resident_vector_length = resident_length;
        start = 1'b1;
        @(posedge clk);
        #1;
        if (!busy || result_valid)
            $fatal(1, "%s: launch edge timing", label);
        @(negedge clk);
        start = 1'b0;
        for (int check_index = 1; check_index <= latency; check_index++) begin
            @(posedge clk);
            #1;
            if (check_index < latency) begin
                if (!busy || result_valid)
                    $fatal(1, "%s: premature result on check %0d", label, check_index);
            end
            else begin
                if (busy || !result_valid || result_ok != (expected == PIM_ERROR_NONE)
                        || result_error_code != expected)
                    $fatal(1, "%s: bad result on check %0d: valid=%b ok=%b code=%0d",
                        label, check_index, result_valid, result_ok, result_error_code);
            end
        end
        @(posedge clk);
        #1;
        if (busy || result_valid)
            $fatal(1, "%s: result pulse lasted longer than one cycle", label);
        cases_run++;
    endtask

    task automatic run_default(
        input string label,
        input pim_descriptor_t d,
        input pim_error_t expected,
        input int latency
    );
        run_case(label, d, 32'h0000_0001, 1'b0, 32'b0, 32'b0,
            expected, latency);
    endtask

    task automatic run_small(
        input string label,
        input pim_descriptor_t d,
        input pim_error_t expected,
        input int latency
    );
        @(negedge clk);
        small_descriptor = d;
        small_start = 1'b1;
        @(posedge clk);
        #1;
        if (!small_busy || small_result_valid)
            $fatal(1, "%s: small launch timing", label);
        @(negedge clk);
        small_start = 1'b0;
        for (int check_index = 1; check_index <= latency; check_index++) begin
            @(posedge clk);
            #1;
            if (check_index < latency) begin
                if (!small_busy || small_result_valid)
                    $fatal(1, "%s: small premature result", label);
            end
            else if (small_busy || !small_result_valid
                    || small_result_ok != (expected == PIM_ERROR_NONE)
                    || small_result_error_code != expected)
                $fatal(1, "%s: small result code %0d", label, small_result_error_code);
        end
        @(posedge clk);
        #1;
        if (small_busy || small_result_valid)
            $fatal(1, "%s: small result pulse width", label);
        cases_run++;
    endtask

    task automatic run_high(
        input string label,
        input pim_descriptor_t d,
        input pim_error_t expected,
        input int latency
    );
        @(negedge clk);
        high_descriptor = d;
        high_start = 1'b1;
        @(posedge clk);
        #1;
        if (!high_busy || high_result_valid)
            $fatal(1, "%s: high launch timing", label);
        @(negedge clk);
        high_start = 1'b0;
        for (int check_index = 1; check_index <= latency; check_index++) begin
            @(posedge clk);
            #1;
            if (check_index < latency) begin
                if (!high_busy || high_result_valid)
                    $fatal(1, "%s: high premature result", label);
            end
            else if (high_busy || !high_result_valid
                    || high_result_ok != (expected == PIM_ERROR_NONE)
                    || high_result_error_code != expected)
                $fatal(1, "%s: high result code %0d", label, high_result_error_code);
        end
        @(posedge clk);
        #1;
        if (high_busy || high_result_valid)
            $fatal(1, "%s: high result pulse width", label);
        cases_run++;
    endtask

    task automatic reset_during_check(input int completed_checks);
        @(negedge clk);
        descriptor = canonical();
        command_word = 32'h0000_0001;
        start = 1'b1;
        @(posedge clk);
        #1;
        if (!busy) $fatal(1, "reset setup: not busy");
        @(negedge clk);
        start = 1'b0;
        for (int i = 0; i < completed_checks; i++) begin
            @(posedge clk);
            #1;
            if (!busy || result_valid)
                $fatal(1, "reset setup: premature result");
        end
        @(negedge clk);
        #1;
        reset = 1'b1;
        #1;
        if (busy || result_valid)
            $fatal(1, "asynchronous reset did not abandon validation");
        @(negedge clk);
        reset = 1'b0;
        repeat (12) begin
            @(posedge clk);
            #1;
            if (busy || result_valid)
                $fatal(1, "aborted command produced a result");
        end
        cases_run++;
    endtask

    initial begin : test_sequence
        pim_descriptor_t d;
        reset = 1'b1;
        start = 1'b0;
        small_start = 1'b0;
        high_start = 1'b0;
        descriptor = '0;
        small_descriptor = '0;
        high_descriptor = '0;
        command_word = 32'b0;
        buffer_vector_full = 1'b0;
        resident_vector_base = 32'b0;
        resident_vector_length = 32'b0;
        repeat (2) @(posedge clk);
        @(negedge clk);
        reset = 1'b0;

        if ($test$plusargs("TEST=start_busy")) begin
            descriptor = canonical();
            command_word = 32'h0000_0001;
            start = 1'b1;
            @(posedge clk);
            @(negedge clk);
            // This is an internal controller/validator protocol failure.
            start = 1'b1;
            @(posedge clk);
            #1;
            $fatal(1, "second start did not fail");
        end

        run_default("canonical 16x32", canonical(), PIM_ERROR_NONE, 10);
        d = canonical(); d.vector_length = 1;
        run_default("minimum vector length", d, PIM_ERROR_NONE, 10);
        d = canonical(); d.output_count = 1;
        run_default("minimum output count", d, PIM_ERROR_NONE, 10);

        run_case("reserved bit", canonical(), 32'h0000_0009, 1'b0,
            0, 0, PIM_ERROR_RESERVED_COMMAND_BIT, 1);
        run_case("nonblocking", canonical(), 32'h0000_0005, 1'b0,
            0, 0, PIM_ERROR_UNSUPPORTED_MODE, 2);
        d = canonical(); d.vector_length = 0;
        run_default("zero vector length", d, PIM_ERROR_INVALID_VECTOR_LENGTH, 3);
        d = canonical(); d.vector_length = 17;
        run_default("vector too long", d, PIM_ERROR_INVALID_VECTOR_LENGTH, 3);
        d = canonical(); d.output_count = 0;
        run_default("zero output count", d, PIM_ERROR_INVALID_OUTPUT_COUNT, 4);
        d = canonical(); d.output_count = 33;
        run_default("too many outputs", d, PIM_ERROR_INVALID_OUTPUT_COUNT, 4);

        d = canonical(); d.vector_base = 32'h101;
        run_default("misaligned vector", d, PIM_ERROR_MISALIGNED_ADDRESS, 5);
        d = canonical(); d.matrix_base = 32'h142;
        run_default("misaligned matrix", d, PIM_ERROR_MISALIGNED_ADDRESS, 5);
        d = canonical(); d.output_base = 32'h943;
        run_default("misaligned output", d, PIM_ERROR_MISALIGNED_ADDRESS, 5);
        d = canonical(); d.matrix_column_stride = 65;
        run_default("misaligned stride", d, PIM_ERROR_INVALID_COLUMN_STRIDE, 6);
        d = canonical(); d.matrix_column_stride = 60;
        run_default("stride below minimum", d, PIM_ERROR_INVALID_COLUMN_STRIDE, 6);
        d = canonical(); d.matrix_column_stride = 68; d.output_base = 32'ha00;
        run_default("larger legal stride", d, PIM_ERROR_NONE, 10);

        d = canonical(); d.vector_base = 32'hffff_ffc4;
        run_default("vector arithmetic overflow", d, PIM_ERROR_ADDRESS_OVERFLOW, 7);
        d = canonical(); d.matrix_base = 32'hffff_ffc0; d.output_count = 2;
        run_default("matrix arithmetic overflow", d, PIM_ERROR_ADDRESS_OVERFLOW, 7);
        d = canonical(); d.output_base = 32'hffff_fff0;
        run_default("output arithmetic overflow", d, PIM_ERROR_ADDRESS_OVERFLOW, 7);
        d = canonical(); d.vector_base = 32'h1000;
        run_default("vector outside RAM", d, PIM_ERROR_ADDRESS_OUTSIDE_RAM, 8);
        d = canonical(); d.matrix_base = 32'hf00;
        run_default("matrix span outside RAM", d, PIM_ERROR_ADDRESS_OUTSIDE_RAM, 8);
        d = canonical(); d.output_base = 32'hffc; d.output_count = 2;
        run_default("output outside RAM", d, PIM_ERROR_ADDRESS_OUTSIDE_RAM, 8);
        d = canonical(); d.output_base = 32'hffc; d.output_count = 1;
        run_default("output endpoint exactly RAM end", d, PIM_ERROR_NONE, 10);
        d = canonical(); d.vector_base = 32'hfc0; d.output_count = 1;
        run_default("vector endpoint exactly RAM end", d, PIM_ERROR_NONE, 10);
        d = canonical(); d.matrix_base = 32'hfc0; d.output_count = 1;
        run_default("matrix endpoint exactly RAM end", d, PIM_ERROR_NONE, 10);

        d = canonical(); d.output_base = 32'h100; d.output_count = 1;
        run_default("output overlaps vector", d, PIM_ERROR_INPUT_OUTPUT_OVERLAP, 9);
        d = canonical(); d.output_base = 32'h140; d.output_count = 1;
        run_default("output overlaps matrix", d, PIM_ERROR_INPUT_OUTPUT_OVERLAP, 9);
        d = canonical(); d.matrix_base = 32'h200; d.matrix_column_stride = 128;
        d.output_count = 2; d.output_base = 32'h260;
        run_default("output in matrix stride padding", d,
            PIM_ERROR_INPUT_OUTPUT_OVERLAP, 9);
        d = canonical(); d.matrix_base = 32'h200; d.output_base = 32'h140;
        d.output_count = 1;
        run_default("output starts at vector end", d, PIM_ERROR_NONE, 10);
        d = canonical(); d.matrix_base = 32'h200; d.output_base = 32'h1fc;
        d.output_count = 1;
        run_default("output ends at matrix start", d, PIM_ERROR_NONE, 10);
        d = canonical(); d.matrix_base = 32'h200; d.vector_base = 32'h200;
        d.output_base = 32'h300; d.output_count = 1;
        run_default("read-only inputs overlap", d, PIM_ERROR_NONE, 10);

        run_case("reuse success", canonical(), 32'h0000_0003, 1'b1,
            32'h100, 16, PIM_ERROR_NONE, 10);
        run_case("reuse incomplete", canonical(), 32'h0000_0003, 1'b0,
            32'h100, 16, PIM_ERROR_VECTOR_REUSE_MISMATCH, 10);
        run_case("reuse base mismatch", canonical(), 32'h0000_0003, 1'b1,
            32'h104, 16, PIM_ERROR_VECTOR_REUSE_MISMATCH, 10);
        run_case("reuse length mismatch", canonical(), 32'h0000_0003, 1'b1,
            32'h100, 15, PIM_ERROR_VECTOR_REUSE_MISMATCH, 10);
        run_case("non-reuse ignores metadata", canonical(), 32'h0000_0001,
            1'b0, 32'hdead_beef, 0, PIM_ERROR_NONE, 10);

        d = canonical(); d.vector_length = 0; d.output_count = 0;
        run_case("reserved dominates all", d, 32'h8000_0005, 1'b0,
            0, 0, PIM_ERROR_RESERVED_COMMAND_BIT, 1);
        run_case("mode dominates length", d, 32'h0000_0005, 1'b0,
            0, 0, PIM_ERROR_UNSUPPORTED_MODE, 2);
        run_default("length dominates count", d, PIM_ERROR_INVALID_VECTOR_LENGTH, 3);
        d = canonical(); d.output_count = 0; d.vector_base = 32'h101;
        run_default("count dominates alignment", d, PIM_ERROR_INVALID_OUTPUT_COUNT, 4);
        d = canonical(); d.vector_base = 32'h101; d.matrix_column_stride = 60;
        run_default("alignment dominates stride", d, PIM_ERROR_MISALIGNED_ADDRESS, 5);
        d = canonical(); d.matrix_column_stride = 60; d.output_base = 32'hffff_fff0;
        run_default("stride dominates overflow", d, PIM_ERROR_INVALID_COLUMN_STRIDE, 6);
        d = canonical(); d.vector_base = 32'hffff_ffc4;
        run_default("overflow dominates RAM bounds", d, PIM_ERROR_ADDRESS_OVERFLOW, 7);
        d = canonical(); d.vector_base = 32'h1000; d.output_base = 32'h1000;
        run_default("RAM bounds dominates overlap", d, PIM_ERROR_ADDRESS_OUTSIDE_RAM, 8);
        d = canonical(); d.output_base = 32'h100; d.output_count = 1;
        run_case("overlap dominates reuse", d, 32'h0000_0003, 1'b0,
            0, 0, PIM_ERROR_INPUT_OUTPUT_OVERLAP, 9);

        d = canonical(); d.vector_length = 1; d.matrix_column_stride = 4;
        d.output_count = 1; d.matrix_base = 32'h200; d.output_base = 32'h300;
        run_small("one-entry valid", d, PIM_ERROR_NONE, 10);
        d.vector_length = 2;
        run_small("one-entry vector limit", d, PIM_ERROR_INVALID_VECTOR_LENGTH, 3);
        d.vector_length = 1; d.output_count = 2;
        run_small("one-entry output limit", d, PIM_ERROR_INVALID_OUTPUT_COUNT, 4);

        run_high("output endpoint at 2^32", high_canonical(), PIM_ERROR_NONE, 10);
        d = high_canonical(); d.vector_base = 32'hffff_ffc0;
        d.output_base = 32'hffff_f100;
        run_high("vector endpoint at 2^32", d, PIM_ERROR_NONE, 10);
        d = high_canonical(); d.matrix_base = 32'hffff_ffc0;
        d.output_base = 32'hffff_f100;
        run_high("matrix endpoint at 2^32", d, PIM_ERROR_NONE, 10);
        d = high_canonical(); d.output_base = 32'hffff_fffc; d.output_count = 2;
        run_high("endpoint beyond 2^32", d, PIM_ERROR_ADDRESS_OVERFLOW, 7);
        d = high_canonical(); d.vector_base = 32'hffff_efc0;
        run_high("below RAM base", d, PIM_ERROR_ADDRESS_OUTSIDE_RAM, 8);
        d = high_canonical(); d.vector_base = 32'hffff_ff00;
        d.matrix_base = 32'hffff_ff00; d.output_base = 32'hffff_ff40;
        run_high("high exact-touch non-overlap", d, PIM_ERROR_NONE, 10);

        reset_during_check(0);
        reset_during_check(4);
        reset_during_check(8);

        // Launch the next command on the edge immediately after a result.
        @(negedge clk);
        descriptor = canonical();
        command_word = 32'h0000_0001;
        start = 1'b1;
        @(posedge clk);
        #1;
        if (!busy || result_valid) $fatal(1, "back-to-back first launch");
        @(negedge clk);
        start = 1'b0;
        repeat (10) @(posedge clk);
        #1;
        if (busy || !result_valid || !result_ok)
            $fatal(1, "back-to-back first result");
        @(negedge clk);
        descriptor = canonical();
        descriptor.vector_length = 0;
        start = 1'b1;
        @(posedge clk);
        #1;
        if (!busy || result_valid)
            $fatal(1, "back-to-back second launch");
        @(negedge clk);
        start = 1'b0;
        repeat (3) @(posedge clk);
        #1;
        if (busy || !result_valid || result_ok
                || result_error_code != PIM_ERROR_INVALID_VECTOR_LENGTH)
            $fatal(1, "back-to-back second result");
        @(posedge clk);
        #1;
        if (result_valid) $fatal(1, "back-to-back result pulse width");
        cases_run++;

        $display("PASS: pim_command_validator_tb (%0d cases)", cases_run);
        $finish;
    end
endmodule
