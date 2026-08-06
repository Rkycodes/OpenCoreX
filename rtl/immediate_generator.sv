module immediate_generator (
    input logic [31:0] instruction,
    output logic [31:0] immediate

);

always_comb begin
    //prevent latch inferral
    immediate = 32'b0;

    case (instruction[6:0])
        //ADDI: I type
        7'b0010011: immediate = {{20{instruction[31]}}, instruction[31:20]};
        //LW: I Type
        7'b0000011: immediate = {{20{instruction[31]}}, instruction[31:20]};
        // SW: S-Type
        7'b0100011: immediate = {{20{instruction[31]}}, instruction[31:25], instruction[11:7]};
        //BEQ: B-type
        7'b1100011: immediate = {{19{instruction[31]}}, instruction[31],
                                     instruction[7], instruction[30:25],
                                     instruction[11:8], 1'b0};
        // JAL: J-Type
        7'b1101111: immediate = {{11{instruction[31]}}, instruction[31],
                                     instruction[19:12], instruction[20],
                                     instruction[30:21], 1'b0};
        default: begin
            //Retain safe 0 immediate
        end
        
    endcase

end

endmodule
