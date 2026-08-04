module alu_decoder_tb;

    logic [1:0] ALUOp;
    logic [2:0] funct3;
    logic [6:0] funct7;

    logic [2:0] ALUControl;
    logic       ALUDecodeValid;

    alu_decoder dut (
        .ALUOp          (ALUOp),
        .funct3         (funct3),
        .funct7         (funct7),
        .ALUControl     (ALUControl),
        .ALUDecodeValid (ALUDecodeValid)
    );
    //drive one decoder input combo and verify both outputs
    //comparisons detect incorrect values as well X or Z outputs
    task automatic check_decode ( //avoids checking logic (local storage)
        input logic [1:0] expected_alu_op,
        input logic [2:0] expected_funct3,
        input logic [6:0] expected_funct7,
        input logic [2:0] expected_control,
        input logic       expected_valid,
        input string      test_name
    );
        begin
            //apply stimulus
            ALUOp = expected_alu_op;
            funct3 = expected_funct3;
            funct7 = expected_funct7;
            //allow settle
            #1;
        //stop if either output differs
            if ((ALUControl !== expected_control) ||
                (ALUDecodeValid !== expected_valid)) begin 
                $fatal(
                    1,
                    "FAIL: %s | ALUControl=%03b expected=%03b | valid=%0b expected=%0b",
                    test_name,
                    ALUControl,
                    expected_control,
                    ALUDecodeValid,
                    expected_valid
                );
            end

            $display(
                "PASS: %s | ALUControl=%03b valid=%0b",
                test_name,
                ALUControl,
                ALUDecodeValid
            );
        end
    endtask

    initial begin
        //record all decoder signals for waveform inspection
        $dumpfile("alu_decoder_tb.vcd");
        $dumpvars(0, alu_decoder_tb);

        // Direct operations ignore funct fields
        check_decode(
            2'b00, 3'b101, 7'b1111111,
            3'b000, 1'b1,
            "Direct ADD"
        );

        check_decode(
            2'b01, 3'b101, 7'b1111111,
            3'b001, 1'b1,
            "Direct SUB"
        );

        // Legal R-type operations
        check_decode(
            2'b10, 3'b000, 7'b0000000,
            3'b000, 1'b1,
            "R-type ADD"
        );

        check_decode(
            2'b10, 3'b000, 7'b0100000,
            3'b001, 1'b1,
            "R-type SUB"
        );

        check_decode(
            2'b10, 3'b111, 7'b0000000,
            3'b010, 1'b1,
            "R-type AND"
        );

        check_decode(
            2'b10, 3'b110, 7'b0000000,
            3'b011, 1'b1,
            "R-type OR"
        );

        check_decode(
            2'b10, 3'b100, 7'b0000000,
            3'b100, 1'b1,
            "R-type XOR"
        );

        // Verify unsupported R-type encodings retain the safe invalid outputs
        check_decode(
            2'b10, 3'b000, 7'b0000001,
            3'b000, 1'b0,
            "Invalid ADD/SUB funct7"
        );

        check_decode(
            2'b10, 3'b100, 7'b0100000,
            3'b000, 1'b0,
            "Invalid XOR funct7"
        );

        check_decode(
            2'b10, 3'b110, 7'b0100000,
            3'b000, 1'b0,
            "Invalid OR funct7"
        );

        check_decode(
            2'b10, 3'b111, 7'b0100000,
            3'b000, 1'b0,
            "Invalid AND funct7"
        );

        check_decode(
            2'b10, 3'b010, 7'b0000000,
            3'b000, 1'b0,
            "Unsupported funct3"
        );

        // Reserved ALUOp must produce safe invalid outputs
        check_decode(
            2'b11, 3'b000, 7'b0000000,
            3'b000, 1'b0,
            "Reserved ALUOp"
        );

        $display("All ALU decoder tests passed.");
        $finish;
    end

endmodule
