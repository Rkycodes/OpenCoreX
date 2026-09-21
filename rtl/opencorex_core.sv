module opencorex_core (
    input  logic        clk,
    input  logic        reset,

    // CPU memory request channel
    output logic        mem_req_valid,
    input  logic        mem_req_ready,
    output logic        mem_req_write,
    output logic [31:0] mem_req_addr,
    output logic [31:0] mem_req_wdata,

    // CPU memory read-response channel
    input  logic        mem_rsp_valid,
    input  logic [31:0] mem_rsp_rdata,

    output logic        error
);

    // Controller-to-datapath write enables.
    logic PCWrite;
    logic PCWriteCond;
    logic BranchInvert;
    logic IRWrite;
    logic OldPCWrite;
    logic PCPlus4Write;
    logic AWrite;
    logic BWrite;
    logic ALUOutWrite;
    logic MDRWrite;
    logic RegWrite;

    // Internal operation-type controls.
    logic MemRead;
    logic MemWrite;

    // Controller-to-datapath selects.
    logic       MemAddrSource;
    logic [1:0] ALUSrcA;
    logic [1:0] ALUSrcB;
    logic [1:0] ALUOp;
    logic       PCSource;
    logic [1:0] WriteBackSelect;

    // Datapath-to-controller instruction fields.
    logic [6:0] opcode;
    logic [2:0] funct3;
    logic [6:0] funct7;

    // The controller never asserts MemRead and MemWrite together. These
    // internal controls form one unified request channel at the core boundary.
    assign mem_req_valid = !reset && (MemRead || MemWrite);
    assign mem_req_write = MemWrite;

    controller controller_inst (
        .clk             (clk),
        .reset           (reset),
        .opcode          (opcode),
        .funct3          (funct3),
        .funct7          (funct7),

        .MemReqReady     (mem_req_ready),
        .MemRspValid     (mem_rsp_valid),

        .PCWrite         (PCWrite),
        .PCWriteCond     (PCWriteCond),
        .BranchInvert    (BranchInvert),
        .IRWrite         (IRWrite),
        .OldPCWrite      (OldPCWrite),
        .PCPlus4Write    (PCPlus4Write),
        .AWrite          (AWrite),
        .BWrite          (BWrite),
        .ALUOutWrite     (ALUOutWrite),
        .MDRWrite        (MDRWrite),
        .RegWrite        (RegWrite),

        .MemRead         (MemRead),
        .MemWrite        (MemWrite),

        .MemAddrSource   (MemAddrSource),
        .ALUSrcA         (ALUSrcA),
        .ALUSrcB         (ALUSrcB),
        .ALUOp           (ALUOp),
        .PCSource        (PCSource),
        .WriteBackSelect (WriteBackSelect),

        .error           (error)
    );

    // The datapath itself does not need protocol knowledge. Its existing
    // memory-data input receives data only when the controller asserts the
    // appropriately response-gated IRWrite or MDRWrite enable.
    datapath datapath_inst (
        .clk             (clk),
        .reset           (reset),

        .PCWrite         (PCWrite),
        .PCWriteCond     (PCWriteCond),
        .BranchInvert    (BranchInvert),
        .IRWrite         (IRWrite),
        .OldPCWrite      (OldPCWrite),
        .PCPlus4Write    (PCPlus4Write),
        .AWrite          (AWrite),
        .BWrite          (BWrite),
        .ALUOutWrite     (ALUOutWrite),
        .MDRWrite        (MDRWrite),
        .RegWrite        (RegWrite),

        .MemAddrSource   (MemAddrSource),
        .ALUSrcA         (ALUSrcA),
        .ALUSrcB         (ALUSrcB),
        .ALUOp           (ALUOp),
        .PCSource        (PCSource),
        .WriteBackSelect (WriteBackSelect),

        .mem_read_data   (mem_rsp_rdata),

        .opcode          (opcode),
        .funct3          (funct3),
        .funct7          (funct7),

        .mem_addr        (mem_req_addr),
        .mem_write_data  (mem_req_wdata)
    );

endmodule
