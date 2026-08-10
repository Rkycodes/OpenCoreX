module memory_error_tb;

    logic clk;
    logic read_enable;
    logic write_enable;
    logic [31:0] address;
    logic [31:0] write_data;
    logic [31:0] read_data;

    integer test_case;

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

    initial begin
        //start idle
        read_enable = 1'b0;
        write_enable = 1'b0;
        address = 32'b0;
        write_data = 32'h1234_5678;
        test_case = 0;

        //pick which illegal access to test
        if(!$value$plusargs("TEST=%d", test_case)) begin
            $fatal(
                1,
                "Specify +TEST=1, +TEST=2, or +TEST=3"
            );
        end

        @(negedge clk);

        case(test_case)
            //read and write at the same time
            1: begin
                $display(
                    "Expected failure: simultaneous read and write"
                );

                address = 32'd0;
                read_enable = 1'b1;
                write_enable = 1'b1;
            end

            //address is not word aligned
            2: begin
                $display(
                    "Expected failure: misaligned address"
                );

                address = 32'd2;
                read_enable = 1'b1;
                write_enable = 1'b0;
            end

            //first address past the end of memory
            3: begin
                $display(
                    "Expected failure: out-of-range address"
                );

                address = 32'd4096;
                read_enable = 1'b1;
                write_enable = 1'b0;
            end

            default: begin
                $fatal(
                    1,
                    "Invalid TEST value %0d; use 1, 2, or 3",
                    test_case
                );
            end
        endcase

        //memory should stop simulation here
        @(posedge clk);
        #1;

        //getting here means the check failed
        $fatal(
            1,
            "FAIL: memory accepted illegal access | read_data=%08h",
            read_data
        );
    end

endmodule
