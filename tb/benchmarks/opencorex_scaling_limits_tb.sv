// Separately verifies MAX_OUTPUTS=128 through real MMIO, controller and physical RAM.
module opencorex_scaling_limits_tb;
    import pim_pkg::*;
    logic clk=0;
    always #5 clk <= ~clk;
    logic reset=1,req_valid=0,req_write=0,req_ready,rsp_valid,busy;
    logic [31:0] req_addr=0,req_wdata=0,rsp_rdata;
    logic mem_req_valid,mem_req_ready,mem_req_write,mem_rsp_valid;
    logic [31:0] mem_req_addr,mem_req_wdata,mem_rsp_rdata;
    logic memory_read_enable,memory_write_enable;
    logic [31:0] memory_address,memory_write_data,memory_read_data;
    logic [31:0] expected[0:127],operands[0:2063];
    int reads=0,writes=0,outputs=0,macs=0;
    pim_accelerator #(.RAM_WORDS(262144),.MAX_OUTPUTS(128),
        .BUFFER_WORDS(16),.MAC_LANES(1)) dut (
        .clk,.reset,.mmio_req_valid(req_valid),.mmio_req_ready(req_ready),
        .mmio_req_write(req_write),.mmio_req_addr(req_addr),.mmio_req_wdata(req_wdata),
        .mmio_rsp_valid(rsp_valid),.mmio_rsp_rdata(rsp_rdata),.pim_busy(busy),
        .mem_req_valid,.mem_req_ready,.mem_req_write,.mem_req_addr,.mem_req_wdata,
        .mem_rsp_valid,.mem_rsp_rdata
    );
    synchronous_memory_adapter adapter (
        .clk,.reset,.req_valid(mem_req_valid),.req_ready(mem_req_ready),
        .req_write(mem_req_write),.req_addr(mem_req_addr),.req_wdata(mem_req_wdata),
        .rsp_valid(mem_rsp_valid),.rsp_rdata(mem_rsp_rdata),.memory_read_enable,
        .memory_write_enable,.memory_address,.memory_write_data,.memory_read_data
    );
    memory #(.WORDS(262144),.INIT_FILE("programs/scaling/hex/offload_128.hex")) ram (
        .clk,.read_enable(memory_read_enable),.write_enable(memory_write_enable),
        .address(memory_address),.write_data(memory_write_data),.read_data(memory_read_data)
    );
    always @(posedge clk or posedge reset) begin
        if(reset) begin reads<=0; writes<=0; outputs<=0; macs<=0; end
        else begin
            if(memory_read_enable) reads<=reads+1;
            if(dut.mac_start) macs<=macs+1;
            if(memory_write_enable) begin
                writes<=writes+1;
                if(outputs>=128 || memory_address!='h10000+32'(outputs*4) ||
                   memory_write_data!==expected[outputs]) $fatal(1,"limit-test output");
                outputs<=outputs+1;
            end
            if(dut.ctrl_done_set && outputs!=128) $fatal(1,"done before final output acceptance");
        end
    end
    task automatic restart;
        @(negedge clk); reset=1; req_valid=0;
        repeat(2) @(posedge clk);
        @(negedge clk); reset=0;
    endtask
    task automatic write_reg(input logic[31:0] offset,input logic[31:0] value);
        @(negedge clk); req_valid=1; req_write=1; req_addr='h40000000+offset; req_wdata=value;
        do @(posedge clk); while(!req_ready);
        @(negedge clk); req_valid=0;
    endtask
    task automatic read_reg(input logic[31:0] offset,input logic[31:0] value);
        @(negedge clk); req_valid=1; req_write=0; req_addr='h40000000+offset;
        do @(posedge clk); while(!req_ready);
        @(negedge clk); req_valid=0;
        @(posedge clk);
        if(!rsp_valid || rsp_rdata!==value) $fatal(1,"MMIO capability/status mismatch %h got %h",offset,rsp_rdata);
        @(negedge clk);
    endtask
    task automatic configure(input logic[31:0] count);
        write_reg(0,'h100); write_reg(4,16); write_reg(8,'h1000);
        write_reg(12,64); write_reg(16,'h10000); write_reg(20,count);
        write_reg(24,1);
        for(int i=0;i<100000;i++) begin
            @(posedge clk);
            if(!busy) break;
            if(i==99999) $fatal(1,"limit command timeout");
        end
        @(negedge clk);
    endtask
    initial begin
        $readmemh("programs/scaling/hex/expected_128.hex",expected);
        repeat(2) @(posedge clk);
        for(int i=0;i<16;i++) operands[i]=ram.mem['h40+i];
        for(int i=0;i<2048;i++) operands[16+i]=ram.mem['h400+i];
        restart();
        read_reg('h3c,128); read_reg('h38,16); read_reg('h40,1);
        configure(129);
        read_reg('h24,{24'b0,PIM_ERROR_INVALID_OUTPUT_COUNT});
        read_reg('h1c,4);
        if(reads!=0 || writes!=0 || macs!=0) $fatal(1,"129 caused operand traffic");
        $display("LIMIT,129,6,0,0");
        restart(); configure(0);
        read_reg('h24,{24'b0,PIM_ERROR_INVALID_OUTPUT_COUNT}); read_reg('h1c,4);
        if(reads!=0 || writes!=0 || macs!=0) $fatal(1,"zero caused operand traffic");
        $display("LIMIT,0,6,0,0");
        restart(); configure(128); read_reg('h1c,10);
        if(reads!=2064 || writes!=128 || outputs!=128 || macs!=2048)
            $fatal(1,"valid 128 limit counters");
        for(int i=0;i<16;i++) if(ram.mem['h40+i]!==operands[i]) $fatal(1,"vector changed");
        for(int i=0;i<2048;i++) if(ram.mem['h400+i]!==operands[16+i]) $fatal(1,"matrix changed");
        $display("LIMIT,128,0,%0d,%0d",reads,writes);
        $display("PASS: opencorex_scaling_limits_tb capability=128 zero/129 reject before traffic");
        $finish;
    end
    initial begin #2000000; $fatal(1,"limits timeout"); end
endmodule
