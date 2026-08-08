module memory#(
    parameter int WORDS = 1024,
    parameter string INIT_FILE = ""
) (
    input logic clk,
    input logic read_enable,
    input logic write_enable,
    input logic [31:0] address,
    input logic [31:0] write_data,
    output logic [31:0] read_data
);

//storage and logic
logic [31:0] mem [0:WORDS-1];
localparam int addr_width = $clog2(WORDS);
logic [addr_width-1:0] word_index;  // word aligned address

initial begin
    if (INIT_FILE != "") begin
        $readmemh(INIT_FILE, mem);
    end
end

assign word_index = address[addr_width+1:2];

always_ff @(posedge clk) begin
    if (read_enable && write_enable) begin
        $fatal(1,"ILLEGAL: READ and WRITE are asserted simultaneously");
    end

    else if (read_enable || write_enable) begin
        if (address[1:0] != 2'b00) begin
            $fatal(1, "ILLEGAL: misaligned memory address %08h", address);
        end

        else if (address >= WORDS * 4) begin
            $fatal(1, "ILLEGAL: memory address out of range: %08h", address);
        end
        
        else if(read_enable) begin
            read_data <= mem[word_index];
        end

        else begin
            mem[word_index] <= write_data;
        end
    end
end

endmodule
