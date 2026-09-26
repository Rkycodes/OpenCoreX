module pim_mac_tb;
    logic clk = 1'b0;
    always #5 clk <= ~clk;

    logic reset = 1'b1;
    logic start = 1'b0;
    logic [31:0] operand_a = '0;
    logic [31:0] operand_b = '0;
    logic [31:0] accumulator_in = '0;
    logic busy;
    logic done;
    logic [31:0] result;
    int cases_run = 0;

    pim_mac dut (
        .clk, .reset, .start, .operand_a, .operand_b, .accumulator_in,
        .busy, .done, .result
    );

    task automatic check(input bit condition, input string label);
        if (!condition)
            $fatal(1, "pim_mac_tb: %s", label);
    endtask

    task automatic run_case(
        input string label,
        input logic [31:0] a,
        input logic [31:0] b,
        input logic [31:0] accumulator,
        input logic [31:0] expected
    );
        logic [31:0] previous_result;
        @(negedge clk);
        previous_result = result;
        operand_a = a;
        operand_b = b;
        accumulator_in = accumulator;
        start = 1'b1;
        #1;
        check(!busy && !done && result == previous_result,
            {label, ": outputs changed before start edge"});
        @(posedge clk);
        #1;
        check(busy && !done && result == previous_result,
            {label, ": accepted start timing"});
        @(negedge clk);
        start = 1'b0;
        operand_a = 32'h1357_9bdf;
        operand_b = 32'h2468_ace0;
        accumulator_in = 32'hfeed_beef;
        #1;
        check(busy && !done && result == previous_result,
            {label, ": inputs affected pending operation"});
        @(posedge clk);
        #1;
        check(!busy && done && result == expected,
            {label, ": completion result or timing"});
        @(posedge clk);
        #1;
        check(!busy && !done && result == expected,
            {label, ": done pulse width or result hold"});
        cases_run++;
    endtask

    initial begin
        #1;
        check(!busy && !done && result == 0, "asynchronous reset");
        @(negedge clk);
        reset = 1'b0;

        run_case("positive", 32'd7, 32'd6, 32'd9, 32'd51);
        run_case("negative product", -32'd7, 32'd6, 32'd3, 32'hffff_ffd9);
        run_case("two negative operands", -32'd7, -32'd6, 32'd9, 32'd51);
        run_case("zero operand", 32'd0, 32'h8000_0000,
            32'hdead_beef, 32'hdead_beef);
        run_case("INT32_MIN times one", 32'h8000_0000, 32'd1,
            32'd0, 32'h8000_0000);
        run_case("INT32_MIN times minus one", 32'h8000_0000,
            32'hffff_ffff, 32'd0, 32'h8000_0000);
        run_case("INT32_MIN squared", 32'h8000_0000,
            32'h8000_0000, 32'd5, 32'd5);
        run_case("multiply overflow", 32'h7fff_ffff, 32'd2,
            32'd0, 32'hffff_fffe);
        run_case("addition wrap", 32'hffff_ffff, 32'd1,
            32'd2, 32'd1);
        run_case("mixed wrap", 32'h7fff_ffff, 32'd2,
            32'd3, 32'd1);

        // The next start can be accepted on the first edge after done.
        @(negedge clk);
        operand_a = 32'd2;
        operand_b = 32'd3;
        accumulator_in = 32'd4;
        start = 1'b1;
        @(posedge clk);
        #1;
        check(busy && !done, "back-to-back first start");
        @(negedge clk);
        operand_a = 32'd100;
        operand_b = 32'd100;
        accumulator_in = 32'd100;
        // start remains high while busy; this edge must finish the first op.
        @(posedge clk);
        #1;
        check(!busy && done && result == 32'd10,
            "busy start ignored and first operation completed");
        @(negedge clk);
        operand_a = 32'd5;
        operand_b = 32'd6;
        accumulator_in = 32'd7;
        @(posedge clk);
        #1;
        check(busy && !done && result == 32'd10,
            "next idle edge accepts new operation");
        @(negedge clk);
        start = 1'b0;
        operand_a = '0;
        operand_b = '0;
        accumulator_in = '0;
        @(posedge clk);
        #1;
        check(!busy && done && result == 32'd37,
            "back-to-back second result");
        @(posedge clk);
        #1;
        check(!busy && !done && result == 32'd37,
            "back-to-back done pulse width");

        @(negedge clk);
        operand_a = 32'd11;
        operand_b = 32'd13;
        accumulator_in = 32'd17;
        start = 1'b1;
        @(posedge clk);
        #1;
        check(busy && !done, "reset test start");
        @(negedge clk);
        start = 1'b0;
        reset = 1'b1;
        #1;
        check(!busy && !done && result == 0,
            "asynchronous reset aborts operation");
        @(negedge clk);
        reset = 1'b0;
        @(posedge clk);
        #1;
        check(!busy && !done && result == 0,
            "aborted operation does not complete");
        run_case("after reset", -32'd2, 32'd3, 32'd5,
            32'hffff_ffff);

        $display("PASS: pim_mac_tb (%0d directed cases plus back-to-back and reset)",
            cases_run);
        $finish;
    end
endmodule
