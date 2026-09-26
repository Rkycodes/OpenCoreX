module register_file_tb;
    
    logic clk;
    logic [4:0] read_addr_1;
    logic [4:0] read_addr_2;
    logic [4:0] write_addr;
    logic [31:0] write_data;
    logic write_enable;
    logic [31:0] read_data_1;
    logic [31:0] read_data_2;

    register_file dut (
        .clk(clk),
        .read_addr_1(read_addr_1),
        .read_addr_2(read_addr_2),
        .write_addr(write_addr),
        .write_data(write_data),
        .write_enable(write_enable),
        .read_data_1(read_data_1),
        .read_data_2(read_data_2)
    );

    //clock generator
    initial begin
        clk = 1'b0;
        forever #5 clk = ~clk;
    end

    task automatic check_reads (
        input logic [4:0] address_1,
        input logic [31:0] expected_1,
        input logic [4:0] address_2,
        input logic [31:0] expected_2,
        input string test_name
    );

        begin
            //apply stims
            read_addr_1 = address_1;
            read_addr_2 = address_2;
            #1;

            //stop if either differs
            if((read_data_1 !== expected_1) ||
            (read_data_2 !== expected_2)) begin
                $fatal(
                    1,
                    "FAIL: %s | read_data_1=%08h expected_1=%08h | read_data_2=%08h expected_2=%08h",
                    test_name,
                    read_data_1,
                    expected_1,
                    read_data_2,
                    expected_2
                    );
            end
            
            $display(
                "PASS: %s | read_data_1=%08h | read_data_2=%08h",
                test_name,
                read_data_1,
                read_data_2
            );
        end
    endtask

    task automatic write_register (
        input logic [4:0] address,
        input logic [31:0] data
    );

        begin
            //apply write inputs away from rising edge
            @(negedge clk);
            write_addr = address;
            write_data = data;
            write_enable = 1'b1;

            //write is performed here
            @(posedge clk);

            //safely disable writing after active edge
            @(negedge clk);
            write_enable = 1'b0;
        end
    endtask

    initial begin
        //waveform generation
        $dumpfile("register_file_tb.vcd");
        $dumpvars(0, register_file_tb);

        // Initialize 
        read_addr_1 = 5'd0;
        read_addr_2 = 5'd0;
        write_addr = 5'd0;
        write_data = 32'b0;
        write_enable = 1'b0;

        // x0  = 0
        check_reads(
            5'd0, 32'b0,
            5'd0, 32'b0,
            "x0 initially reads zero"
        );

        // Write 2 diff regs
        write_register(5'd5,  32'h1234_5678);
        write_register(5'd10, 32'hCAFE_BABE);

        // Both async port must work at same time
        check_reads(
            5'd5,  32'h1234_5678,
            5'd10, 32'hCAFE_BABE,
            "simultaneous reads from x5 and x10"
        );

        // reverse to check that either can read
        check_reads(
            5'd10, 32'hCAFE_BABE,
            5'd5,  32'h1234_5678,
            "read ports reversed"
        );

        // write much not write before rising edge
        @(negedge clk);
        write_addr   = 5'd5;
        write_data   = 32'hDEAD_BEEF;
        write_enable = 1'b1;

        check_reads(
            5'd5,  32'h1234_5678,
            5'd10, 32'hCAFE_BABE,
            "write does not occur before rising edge"
        );

        // new val must be after rising edge
        @(posedge clk);
        #1;

        check_reads(
            5'd5,  32'hDEAD_BEEF,
            5'd10, 32'hCAFE_BABE,
            "write occurs on rising edge"
        );

        @(negedge clk);
        write_enable = 1'b0;

        //disabled write must preserve old value
        write_addr   = 5'd10;
        write_data   = 32'hFFFF_0000;
        write_enable = 1'b0;

        @(posedge clk);
        #1;

        check_reads(
            5'd10, 32'hCAFE_BABE,
            5'd5,  32'hDEAD_BEEF,
            "disabled write is ignored"
        );

        //ignore writes to x0
        write_register(5'd0, 32'hFFFF_FFFF);

        check_reads(
            5'd0, 32'b0,
            5'd0, 32'b0,
            "write to x0 is ignored"
        );

        // iterate through every writable register with a distinct value
        for (int i = 1; i < 32; i++) begin
            write_register(
                5'(i),
                32'h1234_0000 + 32'(i)
            );
        end

        // Verify every value through the public read ports
        for (int i = 1; i < 32; i++) begin
            check_reads(
                5'(i),
                32'h1234_0000 + 32'(i),
                5'(32 - i),
                32'h1234_0000 + 32'(32 - i),
                $sformatf("full register coverage x%0d and x%0d",
                          i, 32 - i)
            );
        end

        // Confirm x0 still reads zero after all writes.
        check_reads(
            5'd0, 32'b0,
            5'd0, 32'b0,
            "x0 remains immutable"
        );

        $display("All register file tests passed.");
        $finish;
    end
        
endmodule
