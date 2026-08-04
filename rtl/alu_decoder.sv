module alu_decoder (
    //operation constants
    //shared conceptually with ALU
    //consistent with alu.sv and architecture.md
    input  logic [1:0] ALUOp,
    input  logic [2:0] funct3,
    input  logic [6:0] funct7,
    output logic [2:0] ALUControl,
    output logic       ALUDecodeValid
);

    localparam logic [2:0] ALU_ADD = 3'b000;
    localparam logic [2:0] ALU_SUB = 3'b001;
    localparam logic [2:0] ALU_AND = 3'b010;
    localparam logic [2:0] ALU_OR  = 3'b011;
    localparam logic [2:0] ALU_XOR = 3'b100;

    always_comb begin
        // Safe defaults for every unsupported encoding
        //this marks decode invalid, and prevents latch interference
        ALUControl     = ALU_ADD;
        ALUDecodeValid = 1'b0;

        case (ALUOp)
            2'b00: begin //ADD, instruction fetch ignored
                ALUControl     = ALU_ADD;
                ALUDecodeValid = 1'b1;
            end

            2'b01: begin //SUB; for branch compare
                ALUControl     = ALU_SUB;
                ALUDecodeValid = 1'b1;
            end

            2'b10: begin //Rtype Ops, requires exact combo
            //prevents unsupported instruction encodings from reaching the ALU as valid
                case ({funct7, funct3})
                    {7'b0000000, 3'b000}: begin
                        ALUControl     = ALU_ADD;
                        ALUDecodeValid = 1'b1;
                    end

                    {7'b0100000, 3'b000}: begin
                        ALUControl     = ALU_SUB;
                        ALUDecodeValid = 1'b1;
                    end

                    {7'b0000000, 3'b111}: begin
                        ALUControl     = ALU_AND;
                        ALUDecodeValid = 1'b1;
                    end

                    {7'b0000000, 3'b110}: begin
                        ALUControl     = ALU_OR;
                        ALUDecodeValid = 1'b1;
                    end

                    {7'b0000000, 3'b100}: begin
                        ALUControl     = ALU_XOR;
                        ALUDecodeValid = 1'b1;
                    end

                    default: begin
                        // keep safe defaults
                    end
                endcase
            end

            default: begin
                // ALUOp = 2'b11 retains safe defaults
            end
        endcase
    end

endmodule
