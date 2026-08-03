module alu_tb;

    logic [31:0] operand_a;
    logic [31:0] operand_b;
    logic [2:0]  ALUControl;

    logic [31:0] result;
    logic Zero;

    integer tests_run;
    integer tests_passed;

    alu dut (
        //port connections
        .operand_a(operand_a),
        .operand_b(operand_b),
        .ALUControl(ALUControl),
        .result(result),
        .Zero(Zero)
    );

    initial begin
        //waveform
        $dumpfile("alu_tb.vcd");
        $dumpvars(0, alu_tb);
        
        //tests run + tests passed
        tests_run = 0;
        tests_passed = 0;

        //tests

        //ADD Test
        operand_a  = 32'd5;
        operand_b  = 32'd3;
        ALUControl = 3'b000;
        #1;

        tests_run++;

        if((result !== 32'd8) || (Zero !== 1'b0)) begin
            $error("ADD failed: result=%0d, Zero=%b", result, Zero);
        end else begin
            tests_passed++;
        end

        //ADD Wrap Around Test
        operand_a  = 32'hFFFF_FFFF;
        operand_b  = 32'd1;
        ALUControl = 3'b000;
        #1;

        tests_run++;

        if((result !== 32'h0000_0000) || (Zero !== 1'b1)) begin
            $error("ADD wrap failed: result=%0d, Zero=%b", result, Zero);
        end else begin
            tests_passed++;
        end

        //SUB Test (positive non zero result)
        operand_a  = 32'd5;
        operand_b  = 32'd3;
        ALUControl = 3'b001;
        #1;
        
        tests_run++;

        if((result !== 32'd2) || (Zero !== 1'b0)) begin
            $error("SUB failed: result=%0d, Zero=%b", result, Zero);
        end else begin
            tests_passed++;
        end

        //SUB Test (zero result)

        operand_a  = 32'd5;
        operand_b  = 32'd5;
        ALUControl = 3'b001;
        #1;
        
        tests_run++;

        if((result !== 32'd0) || (Zero !== 1'b1)) begin
            $error("SUB (zero result) failed: result=%0d, Zero=%b", result, Zero);
        end else begin
            tests_passed++;
        end

        //SUB Test (negative result)
        operand_a  = 32'd3;
        operand_b  = 32'd5;
        ALUControl = 3'b001;
        #1;

        tests_run++;

        if ((result !== 32'hFFFF_FFFE) || (Zero !== 1'b0)) begin
            $error("Negative SUB failed: result=%0d, Zero=%b", $signed(result), Zero);
        end else begin
            tests_passed++;
        end

        //AND Test
        operand_a  = 32'b1100; 
        operand_b  = 32'b1010; 
        ALUControl = 3'b010; 
        #1;
        tests_run++;

        if ((result !== 32'b1000) || (Zero !== 1'b0)) begin 
            $error("AND failed: result=%0d, Zero=%b", result, Zero); 
        end else begin
            tests_passed++;
        end

        //OR Test
        operand_a  = 32'b1100; 
        operand_b  = 32'b1010; 
        ALUControl = 3'b011; 
        #1;
        tests_run++;

        if ((result !== 32'b1110) || (Zero !== 1'b0)) begin 
            $error("OR failed: result=%0d, Zero=%b", result, Zero); 
        end else begin
            tests_passed++;
        end

        //XOR Test
        operand_a  = 32'b1100;
        operand_b  = 32'b1010;
        ALUControl = 3'b100;
        #1;

        tests_run++;

        if ((result !== 32'b0110) || (Zero !== 1'b0)) begin
            $error("XOR failed: result=%0d, Zero=%b", result, Zero);
        end else begin
            tests_passed++;
        end

        //RESERVED ALUControl encoding tests: 101 thru 111
        for (integer encoding = 5; encoding <=7; encoding++) begin
            operand_a = 32'd5;
            operand_b = 32'd3;
            ALUControl = encoding[2:0];
            #1;

            tests_run++;

            if((result !== 32'd0) || (Zero !== 1'b1)) begin
                $error("Reserved encoding %03b failed: result =%0d, Zero=%b",
                ALUControl, result, Zero);
            end else begin
                tests_passed++;
            end
        end

        $display("%0d/%0d tests passed!", tests_passed, tests_run);
        $finish;
    end
endmodule
