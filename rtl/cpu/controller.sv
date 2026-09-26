module controller (
    // Inputs
    input  logic       reset,
    input  logic       clk,
    input  logic [6:0] opcode,
    input  logic [2:0] funct3,
    input  logic [6:0] funct7,

    // Memory-channel status
    input  logic       MemReqReady,
    input  logic       MemRspValid,

    // Write enables
    output logic       PCWrite,
    output logic       PCWriteCond,
    output logic       BranchInvert,
    output logic       IRWrite,
    output logic       OldPCWrite,
    output logic       PCPlus4Write,
    output logic       AWrite,
    output logic       BWrite,
    output logic       ALUOutWrite,
    output logic       MDRWrite,
    output logic       RegWrite,

    // Internal memory-operation controls
    output logic       MemRead,
    output logic       MemWrite,

    // Mux and ALU controls
    output logic       MemAddrSource,
    output logic [1:0] ALUSrcA,
    output logic [1:0] ALUSrcB,
    output logic [1:0] ALUOp,
    output logic       PCSource,
    output logic [1:0] WriteBackSelect,

    // Status
    output logic       error
);

    typedef enum logic [3:0] {
        FETCH,
        FETCH_CAPTURE,
        DECODE,
        R_EXEC,
        I_EXEC,
        ALU_WRITEBACK,
        MEM_ADDR,
        MEM_READ,
        MEM_READ_CAPTURE,
        MEM_WRITEBACK,
        MEM_WRITE,
        BRANCH_TARGET,
        BRANCH_COMPARE,
        JUMP_TARGET,
        JUMP_COMPLETE,
        ERROR
    } state_t;

    state_t current_state;
    state_t next_state;

    always_ff @(posedge clk or posedge reset) begin
        if (reset)
            current_state <= FETCH;
        else
            current_state <= next_state;
    end

    // A request state advances only after valid/ready acceptance. A response
    // state advances only when the corresponding read response is valid.
    always_comb begin
        next_state = current_state;

        case (current_state)
            FETCH: begin
                if (MemReqReady)
                    next_state = FETCH_CAPTURE;
            end

            FETCH_CAPTURE: begin
                if (MemRspValid)
                    next_state = DECODE;
            end

            R_EXEC: next_state = ALU_WRITEBACK;
            I_EXEC: next_state = ALU_WRITEBACK;
            ALU_WRITEBACK: next_state = FETCH;

            MEM_READ: begin
                if (MemReqReady)
                    next_state = MEM_READ_CAPTURE;
            end

            MEM_READ_CAPTURE: begin
                if (MemRspValid)
                    next_state = MEM_WRITEBACK;
            end

            MEM_WRITEBACK: next_state = FETCH;

            MEM_WRITE: begin
                if (MemReqReady)
                    next_state = FETCH;
            end

            BRANCH_TARGET: next_state = BRANCH_COMPARE;
            BRANCH_COMPARE: next_state = FETCH;
            JUMP_TARGET: next_state = JUMP_COMPLETE;
            JUMP_COMPLETE: next_state = FETCH;
            ERROR: next_state = ERROR;

            DECODE: begin
                case (opcode)
                    7'b0110011: begin
                        case ({funct3, funct7})
                            {3'b000, 7'b0000000}, // ADD
                            {3'b000, 7'b0100000}, // SUB
                            {3'b100, 7'b0000000}, // XOR
                            {3'b110, 7'b0000000}, // OR
                            {3'b111, 7'b0000000}, // AND
                            {3'b000, 7'b0000001}: // MUL
                                next_state = R_EXEC;

                            default:
                                next_state = ERROR;
                        endcase
                    end

                    7'b0010011: begin
                        if (funct3 == 3'b000) // ADDI
                            next_state = I_EXEC;
                        else
                            next_state = ERROR;
                    end

                    7'b0000011: begin
                        if (funct3 == 3'b010) // LW
                            next_state = MEM_ADDR;
                        else
                            next_state = ERROR;
                    end

                    7'b0100011: begin
                        if (funct3 == 3'b010) // SW
                            next_state = MEM_ADDR;
                        else
                            next_state = ERROR;
                    end

                    7'b1100011: begin
                        case (funct3)
                            3'b000, // BEQ
                            3'b001: // BNE
                                next_state = BRANCH_TARGET;

                            default:
                                next_state = ERROR;
                        endcase
                    end

                    7'b1101111: next_state = JUMP_TARGET; // JAL
                    default: next_state = ERROR;
                endcase
            end

            MEM_ADDR: begin
                case (opcode)
                    7'b0000011: next_state = MEM_READ;
                    7'b0100011: next_state = MEM_WRITE;
                    default: next_state = ERROR;
                endcase
            end

            default: next_state = ERROR;
        endcase
    end

    always_comb begin
        // Disable all architectural state changes by default.
        PCWrite = 1'b0;
        PCWriteCond = 1'b0;
        BranchInvert = 1'b0;
        IRWrite = 1'b0;
        OldPCWrite = 1'b0;
        PCPlus4Write = 1'b0;
        AWrite = 1'b0;
        BWrite = 1'b0;
        ALUOutWrite = 1'b0;
        MDRWrite = 1'b0;
        RegWrite = 1'b0;
        MemRead = 1'b0;
        MemWrite = 1'b0;
        error = 1'b0;

        // Safe mux and ALU defaults.
        MemAddrSource = 1'b0;
        ALUSrcA = 2'b00;
        ALUSrcB = 2'b00;
        ALUOp = 2'b00;
        PCSource = 1'b0;
        WriteBackSelect = 2'b00;

        case (current_state)
            FETCH: begin
                // Keep the request asserted throughout backpressure. The
                // fetch bookkeeping changes only when the request fires.
                MemRead = 1'b1;
                ALUSrcB = 2'b01;

                if (MemReqReady) begin
                    PCWrite = 1'b1;
                    OldPCWrite = 1'b1;
                    PCPlus4Write = 1'b1;
                end
            end

            FETCH_CAPTURE: begin
                // Ignore stale response data until it is explicitly valid.
                IRWrite = MemRspValid;
            end

            DECODE: begin
                if (next_state != ERROR) begin
                    AWrite = 1'b1;
                    BWrite = 1'b1;
                end
            end

            R_EXEC: begin
                ALUOutWrite = 1'b1;
                ALUSrcA = 2'b10;
                ALUOp = 2'b10;
            end

            I_EXEC: begin
                ALUOutWrite = 1'b1;
                ALUSrcA = 2'b10;
                ALUSrcB = 2'b10;
            end

            ALU_WRITEBACK: begin
                RegWrite = 1'b1;
            end

            MEM_ADDR: begin
                ALUOutWrite = 1'b1;
                ALUSrcA = 2'b10;
                ALUSrcB = 2'b10;
            end

            MEM_READ: begin
                MemRead = 1'b1;
                MemAddrSource = 1'b1;
            end

            MEM_READ_CAPTURE: begin
                MDRWrite = MemRspValid;
            end

            MEM_WRITEBACK: begin
                RegWrite = 1'b1;
                WriteBackSelect = 2'b01;
            end

            MEM_WRITE: begin
                // Remain here with a stable payload until accepted. Stores
                // complete at request handshake and create no response.
                MemWrite = 1'b1;
                MemAddrSource = 1'b1;
            end

            BRANCH_TARGET: begin
                ALUOutWrite = 1'b1;
                ALUSrcA = 2'b01;
                ALUSrcB = 2'b10;
            end

            BRANCH_COMPARE: begin
                PCWriteCond = 1'b1;
                BranchInvert = (funct3 == 3'b001);
                ALUSrcA = 2'b10;
                ALUSrcB = 2'b00;
                ALUOp = 2'b01;
                PCSource = 1'b1;
            end

            JUMP_TARGET: begin
                ALUOutWrite = 1'b1;
                ALUSrcA = 2'b01;
                ALUSrcB = 2'b10;
            end

            JUMP_COMPLETE: begin
                PCWrite = 1'b1;
                RegWrite = 1'b1;
                PCSource = 1'b1;
                WriteBackSelect = 2'b10;
            end

            ERROR: begin
                error = 1'b1;
            end

            default: begin
                error = 1'b1;
            end
        endcase
    end

endmodule
