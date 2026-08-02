module alu (
    input logic [31:0] operand_a,
    input logic [31:0] operand_b,
    input logic [2:0] ALUControl,

    output logic [31:0] result,
    output logic Zero
);

always_comb begin
    result = '0;

    case (ALUControl)
        //operations
        3'b000: result = operand_a + operand_b; // ADD
        3'b001: result = operand_a - operand_b; // SUB
        3'b010: result = operand_a & operand_b; // AND
        3'b011: result = operand_a | operand_b; // OR
        3'b100: result = operand_a ^ operand_b; // XOR
        default: result = '0; // Default case, reserved for 101-111


    endcase

    Zero = (result == 32'b0); 
    
end

endmodule
