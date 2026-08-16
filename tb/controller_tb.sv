module controller_tb;

    //inputs
    logic reset;
    logic clk;
    logic [6:0] opcode;
    logic [2:0] funct3;
    logic [6:0] funct7;

    //Write enables
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

    //mem controls
    logic MemRead;
    logic MemWrite;

    //MUX and ALU controls
    logic MemAddrSource;
    logic [1:0] ALUSrcA;
    logic [1:0] ALUSrcB;
    logic [1:0] ALUOp;
    logic PCSource;
    logic [1:0] WriteBackSelect;

    //status
    logic error;

    //packed copy of all controller outputs for verification
    logic [22:0] actual_controls;

    assign actual_controls = {
        PCWrite,
        PCWriteCond,
        IRWrite,
        OldPCWrite,
        PCPlus4Write,
        AWrite,
        BWrite,
        ALUOutWrite,
        MDRWrite,
        RegWrite,
        MemRead,
        MemWrite,
        error,
        MemAddrSource,
        ALUSrcA,
        ALUSrcB,
        ALUOp,
        PCSource,
        WriteBackSelect
    };

    localparam logic [22:0] FETCH_CONTROLS = {
        1'b1,  //PCWrite
        1'b0,  //PCWriteCond
        1'b0,  //IRWrite
        1'b1,  //OldPCWrite
        1'b1,  //PCPlus4Write
        1'b0,  //AWrite
        1'b0,  //BWrite
        1'b0,  //ALUOutWrite
        1'b0,  //MDRWrite
        1'b0,  //RegWrite
        1'b1,  //MemRead
        1'b0,  //MemWrite
        1'b0,  //error
        1'b0,  //MemAddrSource
        2'b00, //ALUSrcA
        2'b01, //ALUSrcB
        2'b00, //ALUOp
        1'b0,  //PCSource
        2'b00  //WriteBackSelect
    };

    localparam logic [22:0] FETCH_CAPTURE_CONTROLS =
        23'b001_00000_00000_00000_00000;

    localparam logic [22:0] DECODE_LEGAL_CONTROLS = {
        10'b0000011000,//AWrite and BWrite
        4'b0000,//MemRead, MemWrite, error, MemAddrSource
        2'b00,//ALUSrcA
        2'b00,//ALUSrcB
        2'b00,//ALUOp
        1'b0,//PCSource
        2'b00//WriteBackSelect
    };

    localparam logic [22:0] R_EXEC_CONTROLS = {
        10'b0000000100, //ALUOutWrite
        4'b0000,
        2'b10,//ALUSrcA = A
        2'b00, //ALUSrcB = B
        2'b10,//ALUOp = FUNC
        1'b0,
        2'b00
    };

    localparam logic [22:0] ALU_WRITEBACK_CONTROLS = {
        10'b0000000001, //RegWrite
        4'b0000,
        2'b00,
        2'b00,
        2'b00,
        1'b0,
        2'b00//ALUOut selected by default
    };

    localparam logic [22:0] I_EXEC_CONTROLS = {
        10'b0000000100, //ALUOutWrite
        4'b0000,
        2'b10,//ALUSrcA = A
        2'b10,//ALUSrcB = immediate
        2'b00,//ALUOp = ADD
        1'b0,
        2'b00
    };

    localparam logic [22:0] MEM_ADDR_CONTROLS =
        I_EXEC_CONTROLS;

    localparam logic [22:0] MEM_READ_CONTROLS = {
    10'b0000000000,
    4'b1001, //MemRead and MemAddrSource
    2'b00,
    2'b00,
    2'b00,
    1'b0,
    2'b00
};

    localparam logic [22:0] MEM_READ_CAPTURE_CONTROLS = {
        10'b0000000010, //MDRWrite
        4'b0000,
        2'b00,
        2'b00,
        2'b00,
        1'b0,
        2'b00
    };

    localparam logic [22:0] MEM_WRITEBACK_CONTROLS = {
        10'b0000000001, //RegWrite
        4'b0000,
        2'b00,
        2'b00,
        2'b00,
        1'b0,
        2'b01           //MDR
    };

    localparam logic [22:0] MEM_WRITE_CONTROLS = {
        10'b0000000000,
        4'b0101, //MemWrite and MemAddrSource
        2'b00,
        2'b00,
        2'b00,
        1'b0,
        2'b00
    };

    localparam logic [22:0] BRANCH_TARGET_CONTROLS = {
        10'b0000000100, //ALUOutWrite
        4'b0000,
        2'b01,          //ALUSrcA = OldPC
        2'b10,          //ALUSrcB = immediate
        2'b00,          //ALUOp = ADD
        1'b0,
        2'b00
    };

    localparam logic [22:0] BRANCH_COMPARE_CONTROLS = {
        10'b0100000000, //PCWriteCond
        4'b0000,
        2'b10,          //ALUSrcA = A
        2'b00,          //ALUSrcB = B
        2'b01,          //ALUOp = SUB
        1'b1,           //PCSource = ALUOut
        2'b00
    };

    localparam logic [22:0] JUMP_TARGET_CONTROLS =
        BRANCH_TARGET_CONTROLS;

    localparam logic [22:0] JUMP_COMPLETE_CONTROLS = {
        10'b1000000001, //PCWrite and RegWrite
        4'b0000,
        2'b00,
        2'b00,
        2'b00,
        1'b1,           //PCSource = ALUOut
        2'b10           //write back PCPlus4
    };

    localparam logic [22:0] DECODE_ILLEGAL_CONTROLS = 23'b0;

    localparam logic [22:0] ERROR_CONTROLS = {
        10'b0000000000, //all write enables
        4'b0010,       //MemRead, MemWrite, error, MemAddrSource
        2'b00,         //ALUSrcA
        2'b00,         //ALUSrcB
        2'b00,         //ALUOp
        1'b0,          //PCSource
        2'b00          //WriteBackSelect
    };

    controller dut(
        .reset(reset),
        .clk(clk),
        .opcode(opcode),
        .funct3(funct3),
        .funct7(funct7),
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
        .MemRead(MemRead),
        .MemWrite(MemWrite),
        .MemAddrSource(MemAddrSource),
        .ALUSrcA(ALUSrcA),
        .ALUSrcB(ALUSrcB),
        .ALUOp(ALUOp),
        .PCSource(PCSource),
        .WriteBackSelect(WriteBackSelect),
        .error(error)
    );
    

    //clock generation
    initial begin
        clk = 1'b0;
        forever #5 clk = ~clk;
    end

    task automatic check_controls (
        input logic [22:0] expected_controls,
        input string       test_name
    );
        begin
            //allow combinational outputs to settle
            #1;

            if (actual_controls !== expected_controls) begin
                $fatal(
                    1,
                    "FAIL: %s | actual=%023b expected=%023b",
                    test_name,
                    actual_controls,
                    expected_controls
                );
            end

            $display(
                "PASS: %s | controls=%023b",
                test_name,
                actual_controls
            );
        end
    endtask

    task automatic reset_dut;
        begin
            //assert reset away from rising edge
            @(negedge clk);
            reset = 1'b1;

            //asynchronous reset immediately enters FETCH
            check_controls(
                FETCH_CONTROLS,
                "asynchronous reset enters FETCH"
            );

            //reset holds FETCH through a rising edge
            @(posedge clk);
            check_controls(
                FETCH_CONTROLS,
                "reset holds controller in FETCH"
            );

            //release reset away from rising edge
            @(negedge clk);
            reset = 1'b0;
        end
    endtask

    task automatic test_rtype (
        input logic [2:0] test_funct3,
        input logic [6:0] test_funct7,
        input string      test_name
    ); 
        begin
            reset_dut();

            //apply R-type encoding after reset release
            opcode = 7'b0110011;
            funct3 = test_funct3;
            funct7 = test_funct7;

            @(posedge clk);
            check_controls(
                FETCH_CAPTURE_CONTROLS,
                $sformatf("%s FETCH_CAPTURE", test_name)
            );

            @(posedge clk);
            check_controls(
                DECODE_LEGAL_CONTROLS,
                $sformatf("%s DECODE", test_name)
            );

            @(posedge clk);
            check_controls(
                R_EXEC_CONTROLS,
                $sformatf("%s R_EXEC", test_name)
            );

            @(posedge clk);
            check_controls(
                ALU_WRITEBACK_CONTROLS,
                $sformatf("%s ALU_WRITEBACK", test_name)
            );

            @(posedge clk);
            check_controls(
                FETCH_CONTROLS,
                $sformatf("%s returns to FETCH", test_name)
            );
        end
    endtask

    task automatic test_addi;
        begin
            reset_dut();

            //apply legal ADDI encoding
            opcode = 7'b0010011;
            funct3 = 3'b000;
            funct7 = 7'b0000000;

            @(posedge clk);
            check_controls(
                FETCH_CAPTURE_CONTROLS,
                "ADDI FETCH_CAPTURE"
            );

            @(posedge clk);
            check_controls(
                DECODE_LEGAL_CONTROLS,
                "ADDI DECODE"
            );

            @(posedge clk);
            check_controls(
                I_EXEC_CONTROLS,
                "ADDI I_EXEC"
            );

            @(posedge clk);
            check_controls(
                ALU_WRITEBACK_CONTROLS,
                "ADDI ALU_WRITEBACK"
            );

            @(posedge clk);
            check_controls(
                FETCH_CONTROLS,
                "ADDI returns to FETCH"
            );
        end
    endtask

    task automatic test_lw;
        begin
            reset_dut();

            opcode = 7'b0000011;
            funct3 = 3'b010;
            funct7 = 7'b1010101; //immediate bits; must be ignored

            @(posedge clk);
            check_controls(FETCH_CAPTURE_CONTROLS, "LW FETCH_CAPTURE");

            @(posedge clk);
            check_controls(DECODE_LEGAL_CONTROLS, "LW DECODE");

            @(posedge clk);
            check_controls(MEM_ADDR_CONTROLS, "LW MEM_ADDR");

            @(posedge clk);
            check_controls(MEM_READ_CONTROLS, "LW MEM_READ");

            @(posedge clk);
            check_controls(
                MEM_READ_CAPTURE_CONTROLS,
                "LW MEM_READ_CAPTURE"
            );

            @(posedge clk);
            check_controls(
                MEM_WRITEBACK_CONTROLS,
                "LW MEM_WRITEBACK"
            );

            @(posedge clk);
            check_controls(FETCH_CONTROLS, "LW returns to FETCH");
        end
    endtask

    task automatic test_sw;
        begin
            reset_dut();

            opcode = 7'b0100011;
            funct3 = 3'b010;
            funct7 = 7'b1010101; //immediate bits; must be ignored

            @(posedge clk);
            check_controls(FETCH_CAPTURE_CONTROLS, "SW FETCH_CAPTURE");

            @(posedge clk);
            check_controls(DECODE_LEGAL_CONTROLS, "SW DECODE");

            @(posedge clk);
            check_controls(MEM_ADDR_CONTROLS, "SW MEM_ADDR");

            @(posedge clk);
            check_controls(MEM_WRITE_CONTROLS, "SW MEM_WRITE");

            @(posedge clk);
            check_controls(FETCH_CONTROLS, "SW returns to FETCH");
        end
    endtask

    task automatic test_beq;
        begin
            reset_dut();

            opcode = 7'b1100011;
            funct3 = 3'b000;
            funct7 = 7'b1010101; //immediate bits; must be ignored

            @(posedge clk);
            check_controls(FETCH_CAPTURE_CONTROLS, "BEQ FETCH_CAPTURE");

            @(posedge clk);
            check_controls(DECODE_LEGAL_CONTROLS, "BEQ DECODE");

            @(posedge clk);
            check_controls(
                BRANCH_TARGET_CONTROLS,
                "BEQ BRANCH_TARGET"
            );

            @(posedge clk);
            check_controls(
                BRANCH_COMPARE_CONTROLS,
                "BEQ BRANCH_COMPARE"
            );

            @(posedge clk);
            check_controls(FETCH_CONTROLS, "BEQ returns to FETCH");
        end
    endtask

    task automatic test_jal;
        begin
            reset_dut();

            opcode = 7'b1101111;
            funct3 = 3'b101;     //immediate bits; must be ignored
            funct7 = 7'b1010101; //immediate bits; must be ignored

            @(posedge clk);
            check_controls(FETCH_CAPTURE_CONTROLS, "JAL FETCH_CAPTURE");

            @(posedge clk);
            check_controls(DECODE_LEGAL_CONTROLS, "JAL DECODE");

            @(posedge clk);
            check_controls(
                JUMP_TARGET_CONTROLS,
                "JAL JUMP_TARGET"
            );

            @(posedge clk);
            check_controls(
                JUMP_COMPLETE_CONTROLS,
                "JAL JUMP_COMPLETE"
            );

            @(posedge clk);
            check_controls(FETCH_CONTROLS, "JAL returns to FETCH");
        end
    endtask

    task automatic reset_dut_quiet;
        begin
            @(negedge clk);
            reset = 1'b1;

            #1;
            if (actual_controls !== FETCH_CONTROLS)
                $fatal(
                    1,
                    "FAIL: asynchronous reset | actual=%023b expected=%023b",
                    actual_controls,
                    FETCH_CONTROLS
                );

            @(posedge clk);
            #1;
            if (actual_controls !== FETCH_CONTROLS)
                $fatal(
                    1,
                    "FAIL: reset did not hold FETCH | actual=%023b expected=%023b",
                    actual_controls,
                    FETCH_CONTROLS
                );

            @(negedge clk);
            reset = 1'b0;
        end
    endtask

    function automatic logic is_legal_encoding (
        input logic [6:0] test_opcode,
        input logic [2:0] test_funct3,
        input logic [6:0] test_funct7
    );
        begin
            case (test_opcode)
                //R-type
                7'b0110011: begin
                    case ({test_funct3, test_funct7})
                        {3'b000, 7'b0000000}, //ADD
                        {3'b000, 7'b0100000}, //SUB
                        {3'b100, 7'b0000000}, //XOR
                        {3'b110, 7'b0000000}, //OR
                        {3'b111, 7'b0000000}: //AND
                            is_legal_encoding = 1'b1;

                        default:
                            is_legal_encoding = 1'b0;
                    endcase
                end

                //ADDI and BEQ
                7'b0010011,
                7'b1100011:
                    is_legal_encoding = (test_funct3 == 3'b000);

                //LW and SW
                7'b0000011,
                7'b0100011:
                    is_legal_encoding = (test_funct3 == 3'b010);

                //JAL
                7'b1101111:
                    is_legal_encoding = 1'b1;

                default:
                    is_legal_encoding = 1'b0;
            endcase
        end
    endfunction

    task automatic check_controls_quiet (
        input logic [22:0] expected_controls,
        input string test_stage
    );
        begin
            #1;

            if (actual_controls !== expected_controls) begin
                $fatal(
                    1,
                    {"FAIL: %s | opcode=%07b funct3=%03b funct7=%07b ",
                    "| actual=%023b expected=%023b"},
                    test_stage,
                    opcode,
                    funct3,
                    funct7,
                    actual_controls,
                    expected_controls
                );
            end
        end
    endtask

    task automatic test_all_encodings;
        integer op_i;
        integer funct3_i;
        integer funct7_i;
        integer legal_count;
        integer illegal_count;

        logic expected_legal;
        logic [22:0] expected_exec_controls;

        begin
            legal_count = 0;
            illegal_count = 0;

            //exhaustive test all 2^17 opcode, funct3, funct7 combinations

            for (op_i = 0; op_i < 128; op_i = op_i + 1) begin
                for (funct3_i = 0; funct3_i < 8; funct3_i = funct3_i + 1) begin
                    for (funct7_i = 0; funct7_i < 128; funct7_i = funct7_i + 1) begin
                        reset_dut_quiet();

                        opcode = op_i[6:0];
                        funct3 = funct3_i[2:0];
                        funct7 = funct7_i[6:0];

                        expected_legal =
                            is_legal_encoding(opcode, funct3, funct7);

                        // FETCH -> FETCH_CAPTURE
                        @(posedge clk);
                        check_controls_quiet(
                            FETCH_CAPTURE_CONTROLS,
                            "exhaustive FETCH_CAPTURE"
                        );

                        // FETCH_CAPTURE -> DECODE
                        @(posedge clk);

                        if (expected_legal) begin
                            check_controls_quiet(
                                DECODE_LEGAL_CONTROLS,
                                "legal encoding in DECODE"
                            );
                        end
                        else begin
                            check_controls_quiet(
                                DECODE_ILLEGAL_CONTROLS,
                                "illegal encoding in DECODE"
                            );
                        end

                        // DECODE -> execution state or ERROR
                        @(posedge clk);

                        if (expected_legal) begin
                            case (opcode)
                                7'b0110011:
                                    expected_exec_controls = R_EXEC_CONTROLS;

                                7'b0010011:
                                    expected_exec_controls = I_EXEC_CONTROLS;

                                7'b0000011,
                                7'b0100011:
                                    expected_exec_controls = MEM_ADDR_CONTROLS;

                                7'b1100011:
                                    expected_exec_controls =
                                        BRANCH_TARGET_CONTROLS;

                                7'b1101111:
                                    expected_exec_controls =
                                        JUMP_TARGET_CONTROLS;

                                default:
                                    $fatal(
                                        1,
                                        "Reference model marked unsupported opcode legal"
                                    );
                            endcase

                            check_controls_quiet(
                                expected_exec_controls,
                                "legal execution state"
                            );

                            legal_count = legal_count + 1;
                        end
                        else begin
                            check_controls_quiet(
                                ERROR_CONTROLS,
                                "illegal encoding enters ERROR"
                            );

                            illegal_count = illegal_count + 1;
                        end
                    end
                end
            end

            if (legal_count != 1541)
                $fatal(
                    1,
                    "Incorrect legal count: actual=%0d expected=1541",
                    legal_count
                );

            if (illegal_count != 129531)
                $fatal(
                    1,
                    "Incorrect illegal count: actual=%0d expected=129531",
                    illegal_count
                );

            $display(
                "PASS: exhaustive decode test | legal=%0d illegal=%0d total=%0d",
                legal_count,
                illegal_count,
                legal_count + illegal_count
            );
        end
    endtask

    task automatic test_error_state;
        begin
            reset_dut();

            //illegal R-type encoding
            opcode = 7'b0110011;
            funct3 = 3'b001;
            funct7 = 7'b0000000;

            @(posedge clk);
            check_controls(
                FETCH_CAPTURE_CONTROLS,
                "illegal instruction FETCH_CAPTURE"
            );

            @(posedge clk);
            check_controls(
                DECODE_ILLEGAL_CONTROLS,
                "illegal instruction DECODE"
            );

            //the controller enters ERROR after detecting the illegal encoding
            @(posedge clk);
            check_controls(
                ERROR_CONTROLS,
                "illegal instruction enters ERROR"
            );

            //change the inputs to a legal ADD encoding
            opcode = 7'b0110011;
            funct3 = 3'b000;
            funct7 = 7'b0000000;

            //legal inputs must not allow the controller to leave ERROR
            @(posedge clk);
            check_controls(
                ERROR_CONTROLS,
                "ERROR remains active with legal inputs"
            );

            //verify that ERROR remains sticky for another cycle
            @(posedge clk);
            check_controls(
                ERROR_CONTROLS,
                "ERROR remains active until reset"
            );

            //reset must recover the controller and return it to FETCH
            reset_dut();

            $display("PASS: ERROR state persistence and reset recovery");
        end
    endtask
        
    initial begin
        //waveform generation
        //prevents the exahustive test from creating extremely large vcd
        if($test$plusargs("trace")) begin
            $dumpfile("controller_tb.vcd");
            $dumpvars(0, controller_tb);
        end

        //initialize inputs
        reset  = 1'b0;
        opcode = 7'b0;
        funct3 = 3'b0;
        funct7 = 7'b0;

        //legal R-type instruction paths
        test_rtype(
            3'b000, 7'b0000000,
            "ADD"
        );

        test_rtype(
            3'b000, 7'b0100000,
            "SUB"
        );

        test_rtype(
            3'b100, 7'b0000000,
            "XOR"
        );

        test_rtype(
            3'b110, 7'b0000000,
            "OR"
        );

        test_rtype(
            3'b111, 7'b0000000,
            "AND"
        );
        test_addi();

        test_lw();
        test_sw();
        test_beq();
        test_jal();
        test_error_state();
    
        test_all_encodings();

        $display("All targeted and exhaustive controller tests passed");
        $finish;
    end
    
endmodule
