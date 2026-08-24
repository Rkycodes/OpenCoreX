module datapath_tb;
    //Clock and Reset
    logic clk;
    logic reset;

    //controller to datapath signals
    logic PCWrite;
    logic PCWriteCond;
    logic IRWrite;
    logic OldPCWrite;
    logic PCPlus4Write;
    logic AWrite;
    logic BWrite;
    logic ALUOutWrite;
    logic MDRWrite;
    logic RegWrite;
    logic MemAddrSource;
    logic [1:0] ALUSrcA;
    logic [1:0] ALUSrcB;
    logic [1:0] ALUOp;
    logic PCSource;
    logic [1:0] WriteBackSelect;

    //external mem to datapath input
    logic [31:0] mem_read_data;

    //datapath outputs used by the controller and external memory
    logic [6:0] opcode;
    logic [2:0] funct3;
    logic [6:0] funct7;
    logic [31:0] mem_addr;
    logic [31:0] mem_write_data;

    integer tests_run;
    integer tests_passed;

    logic [31:0] instruction;

    datapath dut (
        .clk(clk),
        .reset(reset),
        .PCWrite(PCWrite),
        .PCWriteCond(PCWriteCond),
        .IRWrite(IRWrite),
        .OldPCWrite(OldPCWrite),
        .PCPlus4Write(PCPlus4Write),
        .AWrite(AWrite),
        .BWrite(BWrite),
        .ALUOutWrite(ALUOutWrite),
        .MDRWrite(MDRWrite),
        .RegWrite(RegWrite),
        .MemAddrSource(MemAddrSource),
        .ALUSrcA(ALUSrcA),
        .ALUSrcB(ALUSrcB),
        .ALUOp(ALUOp),
        .PCSource(PCSource),
        .WriteBackSelect(WriteBackSelect),
        .mem_read_data(mem_read_data),
        .opcode(opcode),
        .funct3(funct3),
        .funct7(funct7),
        .mem_addr(mem_addr),
        .mem_write_data(mem_write_data)
    );

    //clock period generation
    initial begin 
        clk = 1'b0;
        forever #5 clk = ~clk;
    end

    //R-type instruction from architectural fields, exercise IR bit functions
    function automatic logic [31:0] encode_r_type (
        input logic [6:0] funct7_value,
        input logic [4:0] rs2,
        input logic [4:0] rs1,
        input logic [2:0] funct3_value,
        input logic [4:0] rd
    );
        begin
            encode_r_type = {
                funct7_value,
                rs2,
                rs1,
                funct3_value,
                rd,
                7'b0110011
            };
        end
    endfunction

    // Build an I-type instruction, ADDI is used when a test only needs to
    // select an rs1 or rd register through the instruction register
    function automatic logic [31:0] encode_addi (
        input logic [11:0] immediate_value,
        input logic [4:0]  rs1,
        input logic [4:0]  rd
    );
        begin
            encode_addi = {
                immediate_value,
                rs1,
                3'b000,
                rd,
                7'b0010011
            };
        end
    endfunction

    // Build a BEQ instruction The immediate input already includes the
    // required low zero bit and is rearranged into the RISC-V B-type fields
    function automatic logic [31:0] encode_beq (
        input logic [4:0]  rs1,
        input logic [4:0]  rs2,
        input logic [12:0] immediate_value
    );
        begin
            //branch targets are two byte aligned, so bit zero must be zero
            if (immediate_value[0] !== 1'b0) begin
                $fatal(
                    1,
                    "BEQ test immediate must be two-byte aligned: immediate=%0d",
                    $signed(immediate_value)
                );
            end
            encode_beq = {
                immediate_value[12],
                immediate_value[10:5],
                rs2,
                rs1,
                3'b000,
                immediate_value[4:1],
                immediate_value[11],
                7'b1100011
            };
        end
    endfunction

    // Return every control input to a non-writing value. Tests
    // call this before enabling only the operation being checked.
    task automatic clear_controls;
        begin
            PCWrite         = 1'b0;
            PCWriteCond     = 1'b0;
            IRWrite         = 1'b0;
            OldPCWrite      = 1'b0;
            PCPlus4Write    = 1'b0;
            AWrite          = 1'b0;
            BWrite          = 1'b0;
            ALUOutWrite     = 1'b0;
            MDRWrite        = 1'b0;
            RegWrite        = 1'b0;
            MemAddrSource   = 1'b0;
            ALUSrcA         = 2'b00;
            ALUSrcB         = 2'b00;
            ALUOp           = 2'b00;
            PCSource        = 1'b0;
            WriteBackSelect = 2'b00;
            mem_read_data   = 32'b0;
        end
    endtask

    // Check a 32-bit value with case inequality so an X or Z always fails
    task automatic check_32 (
        input logic [31:0] actual,
        input logic [31:0] expected,
        input string test_name
    );
        begin
            tests_run++;

            if (actual !== expected) begin
                $fatal(
                    1,
                    "FAIL: %s | actual=%08h expected=%08h",
                    test_name,
                    actual,
                    expected
                );
            end

            tests_passed++;
            $display("PASS: %s | value=%08h", test_name, actual);
        end
    endtask

    // Check a single-bit value, including detection of X or Z
    task automatic check_1 (
        input logic actual,
        input logic expected,
        input string test_name
    );
        begin
            tests_run++;

            if (actual !== expected) begin
                $fatal(
                    1,
                    "FAIL: %s | actual=%b expected=%b",
                    test_name,
                    actual,
                    expected
                );
            end

            tests_passed++;
            $display("PASS: %s | value=%b", test_name, actual);
        end
    endtask

    // Capture a supplied instruction through the external-memory input The
    // stimulus is changed at a falling edge and sampled at the next rising edge to avoid interfering with the sequential logic
    task automatic capture_instruction (
        input logic [31:0] instruction_value
    );
        begin
            @(negedge clk);
            clear_controls();
            mem_read_data = instruction_value;
            IRWrite       = 1'b1;

            @(posedge clk);
            #1;

            @(negedge clk);
            clear_controls();
        end
    endtask

    // Initialize one architectural register through the real datapath rather
    // capture rd in IR, capture data in MDR, then select MDR for writeback
    task automatic write_register_from_mdr (
        input logic [4:0]  destination_register,
        input logic [31:0] data
    );
        begin
            capture_instruction(
                encode_addi(12'b0, 5'd0, destination_register)
            );

            @(negedge clk);
            clear_controls();
            mem_read_data = data;
            MDRWrite      = 1'b1;

            @(posedge clk);
            #1;
            check_32(dut.MDR, data, "MDR captures external memory data");

            @(negedge clk);
            clear_controls();
            WriteBackSelect = 2'b01;
            RegWrite        = 1'b1;

            @(posedge clk);
            #1;

            @(negedge clk);
            clear_controls();
        end
    endtask

    // Capture the two asynchronous register-file read ports into A and B on
    // the same rising edge, matching the controller's DECODE behavior.
    task automatic capture_operands;
        begin
            @(negedge clk);
            clear_controls();
            AWrite = 1'b1;
            BWrite = 1'b1;

            @(posedge clk);
            #1;

            @(negedge clk);
            clear_controls();
        end
    endtask

    initial begin
        // Waveform generation for debugging failed tests
        $dumpfile("datapath_tb.vcd");
        $dumpvars(0, datapath_tb);

        tests_run    = 0;
        tests_passed = 0;

        reset = 1'b1;
        clear_controls();
        #1;

        // Reset must asynchronously clear all eight datapath registers
        check_32(dut.PC,      32'b0, "reset clears PC");
        check_32(dut.OldPC,   32'b0, "reset clears OldPC");
        check_32(dut.PCPlus4, 32'b0, "reset clears PCPlus4");
        check_32(dut.IR,      32'b0, "reset clears IR");
        check_32(dut.A,       32'b0, "reset clears A");
        check_32(dut.B,       32'b0, "reset clears B");
        check_32(dut.ALUOut,  32'b0, "reset clears ALUOut");
        check_32(dut.MDR,     32'b0, "reset clears MDR");

        // FETCH: PC + 4 is calculated combinationally. At the rising edge,
        // PC receives the result while OldPC receives the pre-edge PC value
        @(negedge clk);
        reset            = 1'b0;
        clear_controls();
        ALUSrcA          = 2'b00; // PC
        ALUSrcB          = 2'b01; // constant 4
        ALUOp            = 2'b00; // ADD
        PCSource         = 1'b0;  // ALUResult
        PCWrite          = 1'b1;
        OldPCWrite       = 1'b1;
        PCPlus4Write     = 1'b1;
        #1;

        check_32(dut.ALUOperandA, 32'd0, "FETCH selects PC as ALU operand A");
        check_32(dut.ALUOperandB, 32'd4, "FETCH selects constant four as ALU operand B");
        check_32(dut.ALUResult,   32'd4, "FETCH ALU calculates PC plus four");
        check_32(dut.NextPC,      32'd4, "PCSource selects ALUResult");

        @(posedge clk);
        #1;

        check_32(dut.PC,      32'd4, "FETCH updates PC");
        check_32(dut.OldPC,   32'd0, "FETCH preserves pre-update PC in OldPC");
        check_32(dut.PCPlus4, 32'd4, "FETCH captures PC plus four");

        // With every write enable low, the state must hold across an edge
        @(negedge clk);
        clear_controls();
        mem_read_data = 32'hFFFF_FFFF;

        @(posedge clk);
        #1;

        check_32(dut.PC,      32'd4, "disabled PC write preserves PC");
        check_32(dut.OldPC,   32'd0, "disabled OldPC write preserves OldPC");
        check_32(dut.PCPlus4, 32'd4, "disabled PCPlus4 write preserves PCPlus4");

        // Capture a known R-type instruction and verify the public instruction
        // fields and the ALU-decoder connections derived from IR
        instruction = encode_r_type(
            7'b0000000,
            5'd6,
            5'd5,
            3'b000,
            5'd7
        );
        capture_instruction(instruction);

        check_32(dut.IR, instruction, "IR captures external memory data");
        check_32({25'b0, opcode}, 32'h0000_0033, "opcode is sourced from IR[6:0]");
        check_32({29'b0, funct3}, 32'b0, "funct3 is sourced from IR[14:12]");
        check_32({25'b0, funct7}, 32'b0, "funct7 is sourced from IR[31:25]");

        ALUOp = 2'b10;
        #1;
        check_32({29'b0, dut.ALUControl}, 32'b0, "R-type ADD decodes to ALU ADD");
        check_1(dut.ALUDecodeValid, 1'b1, "valid R-type ADD decode is reported");

        // Seed x5 and x6 through the MDR writeback path, This simultaneously
        // verifies MDR capture, WriteBackSelect=01, and register-file wiring
        write_register_from_mdr(5'd5, 32'd7);
        write_register_from_mdr(5'd6, 32'd7);

        // DECODE for BEQ x5,x6,+16: capture both operands while the ALU uses
        // OldPC and the generated immediate to store the branch target
        instruction = encode_beq(5'd5, 5'd6, 13'd16);
        capture_instruction(instruction);

        @(negedge clk);
        clear_controls();
        AWrite      = 1'b1;
        BWrite      = 1'b1;
        ALUOutWrite = 1'b1;
        ALUSrcA     = 2'b01; // OldPC
        ALUSrcB     = 2'b10; // Immediate
        ALUOp       = 2'b00; // ADD
        #1;

        check_32(dut.Immediate, 32'd16, "BEQ immediate is generated from IR");
        check_32(dut.ALUResult, 32'd16, "DECODE calculates OldPC plus branch immediate");

        @(posedge clk);
        #1;

        check_32(dut.A,      32'd7,  "A captures rs1 value");
        check_32(dut.B,      32'd7,  "B captures rs2 value");
        check_32(dut.ALUOut, 32'd16, "ALUOut captures branch target");
        check_32(mem_write_data, 32'd7, "store-data output is sourced from B");

        // BRANCH, taken: subtract A-B. Equality raises Zero, PCWriteCond then
        //enables PC, and PCSource selects the saved target in ALUOut
        @(negedge clk);
        clear_controls();
        ALUSrcA     = 2'b10; // A
        ALUSrcB     = 2'b00; // B
        ALUOp       = 2'b01; // SUB
        PCSource    = 1'b1;  // ALUOut
        PCWriteCond = 1'b1;
        #1;

        check_32(dut.ALUResult, 32'b0, "equal branch operands subtract to zero");
        check_1(dut.Zero,     1'b1, "equal branch operands assert Zero");
        check_1(dut.PCEnable, 1'b1, "taken branch enables PC");
        check_32(dut.NextPC, 32'd16, "taken branch selects saved target");

        @(posedge clk);
        #1;
        check_32(dut.PC, 32'd16, "taken branch updates PC to target");

        // Change x6 and repeat with a +32 target. A-B is now nonzero, so the
        //conditional write must leave PC at 16 even though NextPC is 32.
        write_register_from_mdr(5'd6, 32'd9);
        instruction = encode_beq(5'd5, 5'd6, 13'd32);
        capture_instruction(instruction);

        @(negedge clk);
        clear_controls();
        AWrite      = 1'b1;
        BWrite      = 1'b1;
        ALUOutWrite = 1'b1;
        ALUSrcA     = 2'b01;
        ALUSrcB     = 2'b10;
        ALUOp       = 2'b00;

        @(posedge clk);
        #1;
        check_32(dut.A,      32'd7,  "unequal branch captures rs1");
        check_32(dut.B,      32'd9,  "unequal branch captures rs2");
        check_32(dut.ALUOut, 32'd32, "unequal branch saves alternate target");

        @(negedge clk);
        clear_controls();
        ALUSrcA     = 2'b10;
        ALUSrcB     = 2'b00;
        ALUOp       = 2'b01;
        PCSource    = 1'b1;
        PCWriteCond = 1'b1;
        #1;

        check_1(dut.Zero,     1'b0, "unequal branch operands clear Zero");
        check_1(dut.PCEnable, 1'b0, "untaken branch disables PC");
        check_32(dut.NextPC, 32'd32, "untaken branch target remains combinationally available");

        @(posedge clk);
        #1;
        check_32(dut.PC, 32'd16, "untaken branch preserves PC");

        // The external-memory address mux must distinguish instruction fetch
        // addresses from saved load/store effective addresses.
        MemAddrSource = 1'b0;
        #1;
        check_32(mem_addr, 32'd16, "memory address mux selects PC");

        MemAddrSource = 1'b1;
        #1;
        check_32(mem_addr, 32'd32, "memory address mux selects ALUOut");
        check_32(mem_write_data, 32'd9, "store-data output remains B");

        // R-type ADD x7,x5,x6: capture operands, execute into ALUOut, then use
        //WriteBackSelect=00 to write the saved result into rd
        instruction = encode_r_type(
            7'b0000000,
            5'd6,
            5'd5,
            3'b000,
            5'd7
        );
        capture_instruction(instruction);
        capture_operands();

        @(negedge clk);
        clear_controls();
        ALUSrcA     = 2'b10;
        ALUSrcB     = 2'b00;
        ALUOp       = 2'b10;
        ALUOutWrite = 1'b1;
        #1;
        check_32(dut.ALUResult, 32'd16, "R-type ADD calculates A plus B");

        @(posedge clk);
        #1;
        check_32(dut.ALUOut, 32'd16, "R-type result is saved in ALUOut");

        @(negedge clk);
        clear_controls();
        WriteBackSelect = 2'b00;
        RegWrite        = 1'b1;

        @(posedge clk);
        #1;

        //Read x7 through rs1 to verify the register-file writeback connection
        capture_instruction(encode_addi(12'b0, 5'd7, 5'd0));
        check_32(dut.ReadData1, 32'd16, "ALUOut writeback stores result in rd");

        //Write the saved fetch return address into x8 through the PCPlus4
        //writeback selection used by JAL
        capture_instruction(encode_addi(12'b0, 5'd0, 5'd8));

        @(negedge clk);
        clear_controls();
        WriteBackSelect = 2'b10;
        RegWrite        = 1'b1;

        @(posedge clk);
        #1;

        capture_instruction(encode_addi(12'b0, 5'd8, 5'd0));
        check_32(dut.ReadData1, 32'd4, "PCPlus4 writeback stores link value in rd");

        //Reserved WriteBackSelect=11 is intentionally defined as zero. Seed
        //x9 with a nonzero value, select 11, and prove that zero is written
        write_register_from_mdr(5'd9, 32'hCAFE_BABE);
        capture_instruction(encode_addi(12'b0, 5'd0, 5'd9));

        @(negedge clk);
        clear_controls();
        WriteBackSelect = 2'b11;
        RegWrite        = 1'b1;
        #1;
        check_32(dut.WriteData, 32'b0, "reserved writeback selection produces zero");

        @(posedge clk);
        #1;

        capture_instruction(encode_addi(12'b0, 5'd9, 5'd0));
        check_32(dut.ReadData1, 32'b0, "reserved writeback selection writes known zero");

        //Reserved operand-mux selections also produce known zero values, This
        //prevents X propagation if the controller ever emits encoding 11
        ALUSrcA = 2'b11;
        ALUSrcB = 2'b11;
        ALUOp   = 2'b00;
        #1;

        check_32(dut.ALUOperandA, 32'b0, "reserved ALUSrcA selection produces zero");
        check_32(dut.ALUOperandB, 32'b0, "reserved ALUSrcB selection produces zero");
        check_32(dut.ALUResult,   32'b0, "reserved operand selections produce known ALU result");

        ALUOp = 2'b11;
        #1;
        check_1(dut.ALUDecodeValid, 1'b0, "reserved ALUOp is reported invalid");

        //Assert reset away from a rising edge This proves reset is genuinely
        //asynchronous and clears the datapath without waiting for the clock
        @(negedge clk);
        clear_controls();
        #2;
        reset = 1'b1;
        #1;

        check_32(dut.PC,      32'b0, "asynchronous reset recovery clears PC");
        check_32(dut.OldPC,   32'b0, "asynchronous reset recovery clears OldPC");
        check_32(dut.PCPlus4, 32'b0, "asynchronous reset recovery clears PCPlus4");
        check_32(dut.IR,      32'b0, "asynchronous reset recovery clears IR");
        check_32(dut.A,       32'b0, "asynchronous reset recovery clears A");
        check_32(dut.B,       32'b0, "asynchronous reset recovery clears B");
        check_32(dut.ALUOut,  32'b0, "asynchronous reset recovery clears ALUOut");
        check_32(dut.MDR,     32'b0, "asynchronous reset recovery clears MDR");

        // The datapath reset intentionally does not reset the register file
        // After reset is released, x5 must still contain the previously written 7
        @(negedge clk);
        reset = 1'b0;
        clear_controls();
        capture_instruction(encode_addi(12'b0, 5'd5, 5'd0));
        check_32(dut.ReadData1, 32'd7, "datapath reset does not erase register file");

        $display(
            "All datapath tests passed: %0d/%0d checks passed.",
            tests_passed,
            tests_run
        );
        $finish;
    end

endmodule
