module opencorex_core (
    input logic clk,
    input logic reset,
    input logic [31:0] mem_read_data,
    output logic [31:0] mem_addr,
    output logic [31:0] mem_write_data,
    output logic mem_read,
    output logic mem_write,
    output logic error
);

    //Controller to datapath WE
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

    //controller to datapath selects
    logic MemAddrSource;
    logic [1:0] ALUSrcA;
    logic [1:0] ALUSrcB;
    logic [1:0] ALUOp;
    logic PCSource;
    logic [1:0] WriteBackSelect;

    //Datapath to controller instruction fields
    logic [6:0] opcode;
    logic [2:0] funct3;
    logic [6:0] funct7;

    controller controller_inst (
        .clk(clk),
        .reset(reset),
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

        .MemRead(mem_read),
        .MemWrite(mem_write),

        .MemAddrSource(MemAddrSource),
        .ALUSrcA(ALUSrcA),
        .ALUSrcB(ALUSrcB),
        .ALUOp(ALUOp),
        .PCSource(PCSource),
        .WriteBackSelect(WriteBackSelect),

        .error(error)
    );

    datapath datapath_inst (
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
    
endmodule
