module pim_vector_buffer_tb;
    logic clk = 1'b0;
    always #5 clk <= ~clk;

    logic reset = 1'b1;
    logic begin_vector = 1'b0;
    logic [31:0] new_vector_base = '0;
    logic [31:0] new_vector_length = '0;
    logic invalidate = 1'b0;
    logic [3:0] query_index = '0;
    logic query_valid;
    logic read_enable = 1'b0;
    logic [3:0] read_index = '0;
    logic [31:0] read_data;
    logic write_enable = 1'b0;
    logic [3:0] write_index = '0;
    logic [31:0] write_data = '0;
    logic [4:0] valid_count;
    logic vector_full;
    logic [31:0] resident_vector_base;
    logic [31:0] resident_vector_length;

    logic one_begin = 1'b0;
    logic one_invalidate = 1'b0;
    logic one_query_index = 1'b0;
    logic one_query_valid;
    logic one_read = 1'b0;
    logic one_read_index = 1'b0;
    logic [31:0] one_read_data;
    logic one_write = 1'b0;
    logic one_write_index = 1'b0;
    logic [31:0] one_write_data = '0;
    logic [0:0] one_count;
    logic one_full;
    logic [31:0] one_base;
    logic [31:0] one_length;

    pim_vector_buffer dut (
        .clk, .reset, .begin_vector, .new_vector_base, .new_vector_length,
        .invalidate, .query_index, .query_valid, .read_enable, .read_index,
        .read_data, .write_enable, .write_index, .write_data, .valid_count,
        .vector_full, .resident_vector_base, .resident_vector_length
    );

    pim_vector_buffer #(.BUFFER_WORDS(1)) one_dut (
        .clk, .reset, .begin_vector(one_begin),
        .new_vector_base(32'h0000_2000), .new_vector_length(32'd1),
        .invalidate(one_invalidate), .query_index(one_query_index),
        .query_valid(one_query_valid), .read_enable(one_read),
        .read_index(one_read_index), .read_data(one_read_data),
        .write_enable(one_write), .write_index(one_write_index),
        .write_data(one_write_data), .valid_count(one_count),
        .vector_full(one_full), .resident_vector_base(one_base),
        .resident_vector_length(one_length)
    );

    task automatic check(
        input bit condition,
        input string label
    );
        if (!condition)
            $fatal(1, "pim_vector_buffer_tb: %s", label);
    endtask

    task automatic start_vector(input logic [31:0] base, input logic [31:0] length);
        @(negedge clk);
        new_vector_base = base;
        new_vector_length = length;
        begin_vector = 1'b1;
        @(posedge clk);
        #1;
        check(resident_vector_base == base && resident_vector_length == length
            && valid_count == 0 && !vector_full, "begin metadata");
        @(negedge clk);
        begin_vector = 1'b0;
    endtask

    task automatic write_word(input logic [3:0] index, input logic [31:0] data);
        @(negedge clk);
        write_index = index;
        write_data = data;
        write_enable = 1'b1;
        @(posedge clk);
        #1;
        @(negedge clk);
        write_enable = 1'b0;
    endtask

    task automatic read_word(input logic [3:0] index, input logic [31:0] expected);
        @(negedge clk);
        held_data = read_data;
        read_index = index;
        read_enable = 1'b1;
        #1;
        check(read_data == held_data, "read data stays registered before edge");
        @(posedge clk);
        #1;
        check(read_data == expected, "synchronous read value");
        @(negedge clk);
        read_enable = 1'b0;
    endtask

    string illegal_case;
    logic [31:0] held_data;
    initial begin
        #1;
        check(!query_valid && !vector_full && valid_count == 0
            && resident_vector_base == 0 && resident_vector_length == 0
            && read_data == 0, "asynchronous reset");
        check(!one_query_valid && !one_full && one_count == 0,
            "single-entry asynchronous reset");
        @(negedge clk);
        reset = 1'b0;

        if ($value$plusargs("TEST=%s", illegal_case)) begin
            new_vector_length = 32'd2;
            new_vector_base = 32'h1000;
            begin_vector = 1'b1;
            @(posedge clk);
            #1;
            @(negedge clk);
            begin_vector = 1'b0;
            if (illegal_case == "read_write") begin
                read_enable = 1'b1;
                write_enable = 1'b1;
            end
            else if (illegal_case == "begin_read") begin
                begin_vector = 1'b1;
                read_enable = 1'b1;
            end
            else if (illegal_case == "begin_write") begin
                begin_vector = 1'b1;
                write_enable = 1'b1;
            end
            else if (illegal_case == "invalidate_read") begin
                invalidate = 1'b1;
                read_enable = 1'b1;
            end
            else if (illegal_case == "invalidate_write") begin
                invalidate = 1'b1;
                write_enable = 1'b1;
            end
            else if (illegal_case == "begin_invalidate") begin
                begin_vector = 1'b1;
                invalidate = 1'b1;
            end
            else if (illegal_case == "read_oob") begin
                read_enable = 1'b1;
                read_index = 4'd2;
            end
            else if (illegal_case == "write_oob") begin
                write_enable = 1'b1;
                write_index = 4'd2;
            end
            else if (illegal_case == "bad_length") begin
                begin_vector = 1'b1;
                new_vector_length = 32'h0001_0001;
            end
            else $fatal(1, "unknown TEST=%s", illegal_case);
            @(posedge clk);
            #1;
            $fatal(1, "illegal TEST=%s unexpectedly succeeded", illegal_case);
        end

        start_vector(32'h0000_1000, 32'd3);
        query_index = 4'd0;
        #1;
        check(!query_valid, "fresh entry invalid");
        read_word(4'd0, 32'b0);
        write_word(4'd2, 32'h2222_2222);
        check(valid_count == 1 && !vector_full, "out-of-order first write");
        query_index = 4'd2;
        #1;
        check(query_valid, "query becomes valid on write edge");
        read_word(4'd2, 32'h2222_2222);
        held_data = read_data;
        write_word(4'd2, 32'hffff_0002);
        check(valid_count == 1 && read_data == held_data, "duplicate write and held read");
        read_word(4'd2, 32'hffff_0002);
        write_word(4'd0, 32'h0000_0001);
        check(valid_count == 2 && !vector_full, "partial short vector");
        @(negedge clk);
        write_index = 4'd1;
        write_data = 32'h0000_0002;
        write_enable = 1'b1;
        #1;
        check(!vector_full && valid_count == 2, "full stays low before final edge");
        @(posedge clk);
        #1;
        check(vector_full && valid_count == 3, "full on final edge");
        @(negedge clk);
        write_enable = 1'b0;
        query_index = 4'd3;
        #1;
        check(!query_valid, "outside short vector invalid");

        @(negedge clk);
        invalidate = 1'b1;
        @(posedge clk);
        #1;
        check(!vector_full && valid_count == 0 && resident_vector_base == 0
            && resident_vector_length == 0 && !query_valid && read_data == 0,
            "invalidate clears metadata and read result");
        check(dut.words[2] == 32'hffff_0002, "invalidation retains physical word");
        @(negedge clk);
        invalidate = 1'b0;

        start_vector(32'h0000_3000, 32'd16);
        for (int i = 15; i >= 0; i--) begin
            write_word(4'(i), 32'habc0_0000 + 32'(i));
            check(valid_count == 5'(16-i), "complete fill count");
            check(vector_full == (i == 0), "complete fill edge");
        end
        read_word(4'd15, 32'habc0_000f);
        start_vector(32'h0000_4000, 32'd2);
        query_index = 4'd15;
        #1;
        check(!query_valid && read_data == 0, "replacement clears validity");
        check(dut.words[15] == 32'habc0_000f, "replacement retains physical word");
        read_word(4'd0, 32'b0);
        write_word(4'd1, 32'h55aa_55aa);
        check(valid_count == 1 && !vector_full, "replacement partial fill");

        @(negedge clk);
        one_begin = 1'b1;
        @(posedge clk);
        #1;
        check(one_base == 32'h2000 && one_length == 1
            && one_count == 0 && !one_full, "one-entry begin");
        @(negedge clk);
        one_begin = 1'b0;
        one_write_data = 32'h1234_5678;
        one_write = 1'b1;
        @(posedge clk);
        #1;
        check(one_count == 1 && one_full && one_query_valid,
            "one-entry final write");
        @(negedge clk);
        one_write = 1'b0;
        one_read = 1'b1;
        @(posedge clk);
        #1;
        check(one_read_data == 32'h1234_5678, "one-entry read");
        @(negedge clk);
        one_read = 1'b0;
        one_invalidate = 1'b1;
        @(posedge clk);
        #1;
        check(one_count == 0 && !one_full && !one_query_valid
            && one_base == 0 && one_length == 0 && one_read_data == 0,
            "one-entry invalidation");
        check(one_dut.words[0] == 32'h1234_5678,
            "one-entry physical data retained");
        @(negedge clk);
        one_invalidate = 1'b0;

        reset = 1'b1;
        #1;
        check(valid_count == 0 && !vector_full && !query_valid
            && resident_vector_base == 0 && resident_vector_length == 0
            && read_data == 0, "reset clears populated metadata");
        check(dut.words[1] == 32'h55aa_55aa, "reset retains physical word");
        $display("PASS: pim_vector_buffer_tb");
        $finish;
    end
endmodule
