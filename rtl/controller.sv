module controller (
    //inputs
    input logic reset,
    input logic clk,
    input logic [6:0] opcode,
    input logic [2:0] funct3,
    input logic [6:0] funct7,

    //write enables
    output logic PCWrite,
    output logic PCWriteCond,
    output logic IRWrite,
    output logic OldPCWrite,
    output logic PCPlus4Write,
    output logic AWrite,
    output logic BWrite,
    output logic ALUOutWrite,
    output logic MDRWrite,
    output logic RegWrite,

    //memory controls
    output logic MemRead,
    output logic MemWrite,

    //mux and ALU

    output logic MemAddrSource,
    output logic [1:0] ALUSrcA,
    output logic [1:0] ALUSrcB,
    output logic [1:0] ALUOp,
    output logic PCSource,
    output logic [1:0] WriteBackSelect,

    //Status
    output logic error
);

typedef enum logic [3:0] {
    //16 states
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
    //reset behavior
    if (reset) begin
        current_state <= FETCH;
    end
    //go to next if not reset
    else begin
        current_state <= next_state;
    end
end


//combinational next state logic
always_comb begin
    //default to current state to prevent inference
    next_state = current_state;

    case(current_state)
        //instruction fetch
        FETCH: next_state = FETCH_CAPTURE;
        FETCH_CAPTURE: next_state = DECODE;

        //arithmetic
        R_EXEC: next_state = ALU_WRITEBACK;
        I_EXEC: next_state = ALU_WRITEBACK;
        ALU_WRITEBACK: next_state = FETCH;

        //load 
        MEM_READ: next_state = MEM_READ_CAPTURE;
        MEM_READ_CAPTURE: next_state = MEM_WRITEBACK;
        MEM_WRITEBACK: next_state = FETCH;
        MEM_WRITE: next_state = FETCH;

        //branch
        BRANCH_TARGET: next_state = BRANCH_COMPARE;
        BRANCH_COMPARE: next_state = FETCH;

        //jump
        JUMP_TARGET: next_state = JUMP_COMPLETE;
        JUMP_COMPLETE: next_state = FETCH;

        //error until reset
        ERROR:  next_state = ERROR;

        DECODE: begin
            case (opcode)
                7'b0110011: begin
                    case({funct3, funct7})
                        //five legal 10 bit combos
                        //ADD
                        {3'b000,7'b0000000}: begin
                            next_state = R_EXEC;
                        end
                        //SUB
                        {3'b000,7'b0100000}: begin
                            next_state = R_EXEC;
                        end
                        //XOR
                        {3'b100,7'b0000000}: begin
                            next_state = R_EXEC;
                        end
                        //OR
                        {3'b110,7'b0000000}: begin
                            next_state = R_EXEC;
                        end
                        //AND
                        {3'b111,7'b0000000}: begin
                            next_state = R_EXEC;
                        end
                        //error if anything else
                        default: next_state = ERROR;
                    endcase

                end

                7'b0010011: begin
                    //ADDI
                    if (funct3 == 3'b000)
                        next_state = I_EXEC;
                    else 
                        next_state = ERROR;       
                end

                7'b0000011: begin
                    //LW
                    if (funct3 == 3'b010)
                        next_state = MEM_ADDR;
                    else
                        next_state = ERROR;
                end

                7'b0100011: begin
                    //SW
                    if (funct3 == 3'b010)
                        next_state = MEM_ADDR;
                    else
                        next_state = ERROR;
                end

                7'b1100011: begin
                    //BEQ
                    if(funct3 == 3'b000)
                        next_state = BRANCH_TARGET;
                    else
                        next_state = ERROR;
                end

                7'b1101111: begin
                    //JAL
                    next_state = JUMP_TARGET;
                end

                default: next_state = ERROR;
            endcase
        end

            MEM_ADDR: begin
                case(opcode)
                    7'b0000011: next_state = MEM_READ;
                    7'b0100011: next_state = MEM_WRITE;
                    default: next_state = ERROR;
                endcase
            end
        //invalid = error
        default: next_state = ERROR;
    endcase
end

//combinational control output logic
always_comb begin
    //disable all state-change controls by default
    PCWrite = 1'b0;
    PCWriteCond = 1'b0;
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

    //safe mux and alu defaults
    MemAddrSource = 1'b0;
    ALUSrcA = 2'b00;
    ALUSrcB = 2'b00;
    ALUOp = 2'b00;
    PCSource = 1'b0;
    WriteBackSelect = 2'b00;

    case(current_state)
    //state-specific override

        FETCH: begin
            PCWrite = 1'b1;
            OldPCWrite = 1'b1;
            PCPlus4Write = 1'b1;
            MemRead = 1'b1;
            ALUSrcB = 2'b01;
        end

        FETCH_CAPTURE: begin
            IRWrite = 1'b1;
        end

        DECODE: begin
            if (next_state != ERROR) begin
                AWrite = 1'b1;
                BWrite = 1'b1;
            end
        end

        R_EXEC: begin
            ALUOutWrite = 1'b1;
            ALUSrcA = 2'b10; //A
            ALUOp = 2'b10; //decode funct3/funct7
        end

        I_EXEC: begin
            ALUOutWrite = 1'b1;
            ALUSrcA = 2'b10; //A
            ALUSrcB = 2'b10; //immediate
        end

        //arithmetic writeback
    ALU_WRITEBACK: begin
        RegWrite = 1'b1;
    end

    //calculate load or store address
    MEM_ADDR: begin
        ALUOutWrite = 1'b1;
        ALUSrcA     = 2'b10;
        ALUSrcB     = 2'b10;
    end

    //request load
    MEM_READ: begin
        MemRead       = 1'b1;
        MemAddrSource = 1'b1;
    end

    //capture loaded word
    MEM_READ_CAPTURE: begin
        MDRWrite = 1'b1;
    end

    //load writeback
    MEM_WRITEBACK: begin
        RegWrite        = 1'b1;
        WriteBackSelect = 2'b01;
    end

    //perform store
    MEM_WRITE: begin
        MemWrite      = 1'b1;
        MemAddrSource = 1'b1;
    end

    //calculate branch target
    BRANCH_TARGET: begin
        ALUOutWrite = 1'b1;
        ALUSrcA     = 2'b01;
        ALUSrcB     = 2'b10;
    end

    //compare branch operands
    BRANCH_COMPARE: begin
        PCWriteCond = 1'b1;
        ALUSrcA     = 2'b10;
        ALUOp       = 2'b01;
        PCSource    = 1'b1;
    end

    //calculate jump target
    JUMP_TARGET: begin
        ALUOutWrite = 1'b1;
        ALUSrcA     = 2'b01;
        ALUSrcB     = 2'b10;
    end

    //update PC and write link address
    JUMP_COMPLETE: begin
        PCWrite         = 1'b1;
        RegWrite        = 1'b1;
        PCSource        = 1'b1;
        WriteBackSelect = 2'b10;
    end

    //remain inactive until reset
    ERROR: begin
        error = 1'b1;
    end

    //invalid FSM encoding fails safely
    default: begin
        error = 1'b1;
    end

    endcase
        
end

endmodule
