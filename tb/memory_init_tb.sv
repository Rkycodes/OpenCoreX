module memory_init_tb;

    logic clk;
    logic read_enable;
    logic write_enable;
    logic [31:0] address;
    logic [31:0] write_data;
    logic [31:0] read_data;

    memory #(
        .WORDS(1024),
        .INIT_FILE("tb/memory_init.hex")
    ) dut (
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

    task automatic read_word (
        input logic [31:0] byte_address,
        input logic [31:0] expected,
        input string test_name
    );
        begin
            //apply read inputs away from rising edge
            @(negedge clk);
            address = byte_address;
            read_enable = 1'b1;

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
        $dumpfile("memory_init_tb.vcd");
        $dumpvars(0, memory_init_tb);

        //start idle
        read_enable = 1'b0;
        write_enable = 1'b0;
        address = 32'b0;
        write_data = 32'b0;

        //give readmemh time to finish
        #1;

        //check values loaded directly into memory
        check_value(
            dut.mem[0],
            32'h524B_5943,
            "hex file initializes mem[0] with RKYC"
        );

        check_value(
            dut.mem[1],
            32'h4F44_4553,
            "hex file initializes mem[1] with ODES"
        );

        check_value(
            dut.mem[2],
            32'hCAFE_F00D,
            "hex file initializes mem[2]"
        );

        //check initialized data through normal read port
        read_word(
            32'd0,
            32'h524B_5943,
            "initialized word 0 reads RKYC"
        );

        read_word(
            32'd4,
            32'h4F44_4553,
            "initialized word 1 reads ODES"
        );

        read_word(
            32'd8,
            32'hCAFE_F00D,
            "initialized word 2 reads correctly"
        );

        $display("All memory initialization tests passed.");
        $finish;
    end

endmodule
