module datapath (

    //inputs
    input logic clk,
    input logic reset,
    input logic PCWrite,
    input logic PCWriteCond,
    input logic IRWrite,
    input logic OldPCWrite,
    input logic PCPlus4Write,
    input logic AWrite,
    input logic BWrite,
    input logic ALUOutWrite,
    input logic MDRWrite,
    input logic RegWrite,
    input logic MemAddrSource,
    input logic [1:0] ALUSrcA,
    input logic [1:0] ALUSrcB,
    input logic [1:0] ALUOp,
    input logic PCSource,
    input logic [1:0] WriteBackSelect,
    input logic [31:0] mem_read_data,

    //outputs
    output logic [6:0] opcode,
    output logic [2:0] funct3,
    output logic [6:0] funct7,
    output logic [31:0] mem_addr,
    output logic [31:0] mem_write_data

    
);
    //8, 32 bit combinational signals
    logic [31:0] ReadData1, ReadData2, Immediate, ALUOperandA, ALUOperandB, ALUResult, NextPC, WriteData;


    //8, 32 bit registers
    logic [31:0] PC, OldPC, PCPlus4, IR, A, B, ALUOut, MDR;

    //1, 3 bit signal
    logic [2:0] ALUControl;

    //3, 1 bit signal
    logic Zero, PCEnable;

    /* verilator lint_off UNUSEDSIGNAL */
    logic ALUDecodeValid;
    /* verilator lint_on UNUSEDSIGNAL */

    assign opcode = IR[6:0];
    assign funct3 = IR[14:12];
    assign funct7 = IR[31:25];
    assign mem_write_data = B;
    assign PCEnable = PCWrite | (PCWriteCond & Zero);

    immediate_generator immediate_generator_inst (
        .instruction(IR),
        .immediate(Immediate)
    );

    register_file register_file_inst (
        .clk(clk),
        .read_addr_1(IR[19:15]), //rs1
        .read_addr_2(IR[24:20]), //rs2
        .write_addr(IR[11:7]), //rd
        .write_data(WriteData),
        .write_enable(RegWrite),
        .read_data_1(ReadData1),
        .read_data_2(ReadData2)
    );

    alu_decoder alu_decoder_inst (
        .ALUOp(ALUOp),
        .funct3(funct3),
        .funct7(funct7),
        .ALUControl(ALUControl),
        .ALUDecodeValid(ALUDecodeValid)
    );

    alu alu_inst (
        .operand_a(ALUOperandA),
        .operand_b(ALUOperandB),
        .ALUControl(ALUControl),
        .result(ALUResult),
        .Zero(Zero)
    );

    //two, one bit muxes

    assign mem_addr = MemAddrSource ? ALUOut : PC;
    assign NextPC = PCSource ? ALUOut : ALUResult;

    always_comb begin
        ALUOperandA = 32'b0;
        ALUOperandB = 32'b0;
        WriteData = 32'b0;

        case (ALUSrcA)
            2'b00: ALUOperandA = PC;
            2'b01: ALUOperandA = OldPC;
            2'b10: ALUOperandA = A;
            default: begin
                //retain safe zero default.
            end
        endcase

        case(ALUSrcB)
            2'b00: ALUOperandB = B;
            2'b01: ALUOperandB = 32'd4;
            2'b10: ALUOperandB = Immediate;
            default: begin
                //retain zero default
            end
        endcase

        case(WriteBackSelect)
            2'b00: WriteData = ALUOut;
            2'b01: WriteData = MDR;
            2'b10: WriteData = PCPlus4;
            default: begin
                //retain zero default
            end
        endcase
    end

    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
            //set all eight datapath registers to zero
            {PC, OldPC, PCPlus4, IR, A, B, ALUOut, MDR} <= '0;
            
        end
        else begin
            //eight independent write-enable checks
            if (PCEnable)      PC <= NextPC;
            if (OldPCWrite)    OldPC <= PC;
            if (PCPlus4Write)  PCPlus4 <= ALUResult;
            if (IRWrite)       IR <= mem_read_data;
            if (AWrite)        A <= ReadData1;
            if (BWrite)        B <= ReadData2;
            if (ALUOutWrite)   ALUOut <= ALUResult;
            if (MDRWrite)      MDR <= mem_read_data;
        end
    end
endmodule





