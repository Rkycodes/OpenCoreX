module immediate_generator_tb;
    logic [31:0] instruction;
    logic [31:0] immediate;

    immediate_generator dut (
        .immediate(immediate),
        .instruction(instruction)
    );

    task automatic check_immediate (
        input logic [31:0] instruction_value,
        input logic [31:0] expected_immediate,
        input string test_name
    );
        begin
        // apply stimulus, DUT drives immediate
        instruction = instruction_value;

        //allow for combinational settle
        #1;

        //stop if  output differs
        if((immediate !== expected_immediate)) begin
            $fatal(
                1,
                "Fail: %s | immediate = %032b expected = %032b",
                test_name,
                immediate,
                expected_immediate
            );
        end

        $display(
            "PASS: %s | immediate=%032b",
            test_name,
            immediate
        );
        end
    endtask

    initial begin
        //record all signals for waveform inspection
        $dumpfile("immediate_generator_tb.vcd");
        $dumpvars(0, immediate_generator_tb);

        //check immediates!
        check_immediate(
            {12'd5, 5'd0, 3'b000, 5'd0, 7'b0010011},
            32'd5,
            "ADDI positive immediate"
        );

        check_immediate(
            {12'hFFB, 5'd0, 3'b000, 5'd0, 7'b0010011},
            32'hFFFF_FFFB,
            "ADDI negative immediate"
        );
        // maximum = 2^(n-1) -1 
        check_immediate(
            {12'h7FF, 5'd0, 3'b000, 5'd0, 7'b0010011},
            32'd2047,
            "ADDI maximum immediate"
        );
        //-2^(n-1) = -2048
        check_immediate(
            {12'h800, 5'd0, 3'b000, 5'd0, 7'b0010011},
            32'hFFFF_F800,
            "ADDI minimum immediate"
        );

        // LW: verify the second I-type opcode.
        check_immediate(
            {12'd12, 5'd0, 3'b010, 5'd0, 7'b0000011},
            32'd12,
            "LW positive offset"
        );

        check_immediate(
            {12'hFF0, 5'd0, 3'b010, 5'd0, 7'b0000011},
            32'hFFFF_FFF0,
            "LW negative offset"
        );

        // SW: S-type immediate.
        // Instruction order:
        // imm[11:5], rs2, rs1, funct3, imm[4:0], opcode
        check_immediate(
            {7'd0, 5'd0, 5'd0, 3'b010, 5'd20, 7'b0100011},
            32'd20,
            "SW positive offset"
        );

        check_immediate(
            {7'b1111111, 5'd0, 5'd0, 3'b010, 5'b01100, 7'b0100011},
            32'hFFFF_FFEC,
            "SW negative offset"
        );
        // maximum = 2^(n-1) -1 
        check_immediate(
            {7'b0111111, 5'd0, 5'd0, 3'b010, 5'b11111, 7'b0100011},
            32'd2047,
            "SW maximum immediate"
        );
        //-2^(n-1) = -2048
        check_immediate(
            {7'b1000000, 5'd0, 5'd0, 3'b010, 5'b00000, 7'b0100011},
            32'hFFFF_F800,
            "SW minimum immediate"
        );

        // BEQ: B-type immediate.
        // Instruction order:
        // imm[12], imm[10:5], rs2, rs1, funct3,
        // imm[4:1], imm[11], opcode
        check_immediate(
            {1'b0, 6'b000000, 5'd0, 5'd0, 3'b000,
            4'b1000, 1'b0, 7'b1100011},
            32'd16,
            "BEQ forward offset"
        );

        check_immediate(
            {1'b1, 6'b111111, 5'd0, 5'd0, 3'b000,
            4'b1000, 1'b1, 7'b1100011},
            32'hFFFF_FFF0,
            "BEQ backward offset"
        );
        //largest possible offset is 4094 because can only represent
        //even offsets due to 1b'1 in immediate LSB
        check_immediate(
            {1'b0, 6'b111111, 5'd0, 5'd0, 3'b000,
            4'b1111, 1'b1, 7'b1100011},
            32'd4094,
            "BEQ maximum offset"
        );
        // -2^(n-1) = -4096
        check_immediate(
            {1'b1, 6'b000000, 5'd0, 5'd0, 3'b000,
            4'b0000, 1'b0, 7'b1100011},
            32'hFFFF_F000,
            "BEQ minimum offset"
        );

        // JAL: J-type immediate.
        // Instruction order:
        // imm[20], imm[10:1], imm[11], imm[19:12], rd, opcode
        check_immediate(
            {1'b0, 10'd16, 1'b0, 8'd0, 5'd0, 7'b1101111},
            32'd32,
            "JAL forward offset"
        );

        check_immediate(
            {1'b1, 10'h3F0, 1'b1, 8'hFF, 5'd0, 7'b1101111},
            32'hFFFF_FFE0,
            "JAL backward offset"
        );
        //2^(n-1) -1 = 1,048,575 but can only represent even numbers so
        // 1,048,574
        check_immediate(
            {1'b0, 10'h3FF, 1'b1, 8'hFF, 5'd0, 7'b1101111},
            32'h000F_FFFE,
            "JAL maximum offset"
        );
        //-2(n-1) = -1,048,576
        check_immediate(
            {1'b1, 10'h000, 1'b0, 8'h00, 5'd0, 7'b1101111},
            32'hFFF0_0000,
            "JAL minimum offset"
        );

        // R-type has no immediate and is unsupported by this module.
        check_immediate(
            {25'd0, 7'b0110011},
            32'b0,
            "Unsupported R-type opcode"
        );

        $display("All immediate generator tests passed.");
        $finish;
    end
endmodule
