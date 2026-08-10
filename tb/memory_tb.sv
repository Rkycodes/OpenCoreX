module memory_tb;

    logic clk;
    logic read_enable;
    logic write_enable;
    logic [31:0] address;
    logic [31:0] write_data;
    logic [31:0] read_data;

    memory dut (
        .clk(clk),
        .read_enable(read_enable),
        .write_enable(write_enable),
        .address(address),
        .write_data(write_data),
        .read_data(read_data)
    );

    //clock generator
    initial begin
        clk = 1'b0;
        forever #5 clk = ~clk;
    end

    task automatic check_value (
        input logic [31:0] actual,
        input logic [31:0] expected,
        input string test_name
    );
        begin
            //stop if value differs
            if(actual !== expected) begin
                $fatal(
                    1,
                    "FAIL: %s | actual=%08h expected=%08h",
                    test_name,
                    actual,
                    expected
                );
            end

            $display(
                "PASS: %s | value=%08h",
                test_name,
                actual
            );
        end
    endtask

    task automatic write_word (
        input logic [31:0] byte_address,
        input logic [31:0] data
    );
        begin
            //apply write inputs away from rising edge
            @(negedge clk);
            address      = byte_address;
            write_data   = data;
            read_enable  = 1'b0;
            write_enable = 1'b1;

            //write happens here
            @(posedge clk);
            #1;

            //turn writing back off
            @(negedge clk);
            write_enable = 1'b0;
        end
    endtask

    task automatic read_word (
        input logic [31:0] byte_address,
        input logic [31:0] expected,
        input string test_name
    );
        begin
            //apply read inputs away from rising edge
            @(negedge clk);
            address      = byte_address;
            read_enable  = 1'b1;
            write_enable = 1'b0;

            //read happens here
            @(posedge clk);
            #1;

            check_value(read_data, expected, test_name);

            //turn reading back off
            @(negedge clk);
            read_enable = 1'b0;
        end
    endtask

    initial begin
        //waveform generation
        $dumpfile("memory_tb.vcd");
        $dumpvars(0, memory_tb);

        //start idle
        read_enable  = 1'b0;
        write_enable = 1'b0;
        address      = 32'b0;
        write_data   = 32'b0;

        //let memory sit idle for two cycles
        repeat (2) begin
            @(posedge clk);
            #1;
        end

        //basic write to word 1
        //word 1 uses byte address 4
        write_word(32'd4, 32'hFFFF_FFFF);

        check_value(
            dut.mem[1],
            32'hFFFF_FFFF,
            "byte address 4 writes mem[1]"
        );

        //put a known value beside the next test word
        write_word(32'd12, 32'hA5A5_A5A5);

        check_value(
            dut.mem[3],
            32'hA5A5_A5A5,
            "sentinel written to mem[3]"
        );

        //byte address 8 should write word 2
        write_word(32'd8, 32'h1234_5678);

        check_value(
            dut.mem[2],
            32'h1234_5678,
            "byte address 8 writes mem[2]"
        );

        //word 3 should not be touched
        check_value(
            dut.mem[3],
            32'hA5A5_A5A5,
            "writing mem[2] does not modify mem[3]"
        );

        //basic synchronous read
        read_word(
            32'd4,
            32'hFFFF_FFFF,
            "synchronous read from word 1"
        );

        //read_data should not change before rising edge
        @(negedge clk);
        address      = 32'd8;
        read_enable  = 1'b1;
        write_enable = 1'b0;
        #1;

        check_value(
            read_data,
            32'hFFFF_FFFF,
            "read_data unchanged before rising edge"
        );

        //new read should show up after rising edge
        @(posedge clk);
        #1;

        check_value(
            read_data,
            32'h1234_5678,
            "read_data changes on rising edge"
        );

        @(negedge clk);
        read_enable = 1'b0;

        //changing inputs while idle should do nothing
        address    = 32'd12;
        write_data = 32'hDEAD_BEEF;

        repeat (2) begin
            @(posedge clk);
            #1;
        end

        check_value(
            read_data,
            32'h1234_5678,
            "read_data retained while idle"
        );

        check_value(
            dut.mem[1],
            32'hFFFF_FFFF,
            "mem[1] retained while idle"
        );

        check_value(
            dut.mem[3],
            32'hA5A5_A5A5,
            "disabled write does not modify mem[3]"
        );

        //check first memory word
        write_word(32'd0, 32'h1111_1111);

        check_value(
            dut.mem[0],
            32'h1111_1111,
            "first memory word write"
        );

        read_word(
            32'd0,
            32'h1111_1111,
            "first memory word read"
        );

        //check last memory word
        //word 1023 uses byte address 4092
        write_word(32'd4092, 32'h2222_2222);

        check_value(
            dut.mem[1023],
            32'h2222_2222,
            "last memory word write"
        );

        read_word(
            32'd4092,
            32'h2222_2222,
            "last memory word read"
        );

        //overwrite word 1 with a new value
        @(negedge clk);
        address      = 32'd4;
        write_data   = 32'hDEAD_BEEF;
        read_enable  = 1'b0;
        write_enable = 1'b1;
        #1;

        //old value should remain before rising edge
        check_value(
            dut.mem[1],
            32'hFFFF_FFFF,
            "overwrite does not occur before rising edge"
        );

        //new value should appear after rising edge
        @(posedge clk);
        #1;

        check_value(
            dut.mem[1],
            32'hDEAD_BEEF,
            "overwrite occurs on rising edge"
        );

        @(negedge clk);
        write_enable = 1'b0;

        read_word(
            32'd4,
            32'hDEAD_BEEF,
            "overwritten word reads new value"
        );

        $display("All normal memory tests passed.");
        $finish;
    end
endmodule