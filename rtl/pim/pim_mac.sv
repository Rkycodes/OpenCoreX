module pim_mac (
    input  logic        clk,
    input  logic        reset,
    input  logic        start,
    input  logic [31:0] operand_a,
    input  logic [31:0] operand_b,
    input  logic [31:0] accumulator_in,
    output logic        busy,
    output logic        done,
    output logic [31:0] result
);
    logic [31:0] operand_a_q;
    logic [31:0] operand_b_q;
    logic [31:0] accumulator_q;
    logic [31:0] product_low;

    assign product_low = $signed(operand_a_q) * $signed(operand_b_q);

    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
            operand_a_q <= '0;
            operand_b_q <= '0;
            accumulator_q <= '0;
            busy <= 1'b0;
            done <= 1'b0;
            result <= '0;
        end
        else begin
            done <= 1'b0;
            if (busy) begin
                result <= product_low + accumulator_q;
                busy <= 1'b0;
                done <= 1'b1;
            end
            else if (start) begin
                operand_a_q <= operand_a;
                operand_b_q <= operand_b;
                accumulator_q <= accumulator_in;
                busy <= 1'b1;
            end
        end
    end
endmodule
