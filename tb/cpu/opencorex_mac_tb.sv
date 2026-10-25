// Whole-core directed/random MAC tests. Operands initialized by executed LW.
module opencorex_mac_tb;
    logic clk=0, reset=1;
    always #5 clk<=~clk;
    logic req, ready, wr, fetch, rsp=0, error;
    logic [31:0] addr, data, rdata=0;
    logic [31:0] mem [0:127];
    int checks=0;
    assign ready=!reset;
    opencorex_core dut(.clk, .reset, .mem_req_valid(req), .mem_req_ready(ready),
        .mem_req_write(wr), .mem_req_is_fetch(fetch), .mem_req_addr(addr),
        .mem_req_wdata(data), .mem_rsp_valid(rsp), .mem_rsp_rdata(rdata), .error);
    always @(posedge clk or posedge reset) begin
        if(reset) begin rsp<=0; rdata<=0; end
        else begin
            rsp <= req && ready && !wr;
            if(req && ready) begin
                if(fetch && wr) $fatal(1,"fetch marked as write");
                if(addr>=512 || addr[1:0]!=0) $fatal(1,"address");
                if(wr) mem[addr>>2] <= data;
                else rdata <= mem[addr>>2];
            end
        end
    end
    function automatic logic [31:0] mac(input int rd, s1, s2);
        return (32'd1<<25) | (32'(s2)<<20) | (32'(s1)<<15) | (32'(rd)<<7) | 32'h0b;
    endfunction
    task automatic setup(input logic [31:0] a,b,c, input int rd,s1,s2);
        @(negedge clk); reset=1;
        mem[0]=32'h10002083; // lw x1,256(x0)
        mem[1]=32'h10402103; // lw x2,260(x0)
        mem[2]=32'h10802183; // lw x3,264(x0)
        mem[3]=mac(rd,s1,s2);
        mem[4]=mac(rd,s1,s2); // dependency, including aliased sources
        mem[5]=(32'(rd)<<15) | (32'd4<<7) | 32'h33; // add x4,rd,x0
        mem[6]=32'h022082b3; // mul x5,x1,x2
        mem[7]=32'h10402623; // sw x4,268(x0)
        mem[8]=32'h00700313; // addi x6,x0,7
        mem[9]=32'h008003ef; // jal x7,+8
        mem[10]=32'h06300313; // skipped
        mem[11]=32'h0000000b; // reserved custom-0
        mem[64]=a; mem[65]=b; mem[66]=c; mem[67]=0;
        repeat(2) @(negedge clk);
        reset=0;
    endtask
    task automatic run_case(input logic [31:0] a,b,c, input int rd,s1,s2);
        logic [31:0] model [0:7];
        int dec, execs, accum, writes;
        bit finished;
        setup(a,b,c,rd,s1,s2);
        foreach(model[i]) model[i]=0;
        model[1]=a; model[2]=b; model[3]=c;
        repeat(2) begin
            if(rd!=0) model[rd]=model[rd]+model[s1]*model[s2];
        end
        model[4]=model[rd]; model[5]=model[1]*model[2]; model[6]=7; model[7]=40;
        dec=-1; execs=0; accum=0; writes=0; finished=0;
        for(int cycle=0;cycle<150;cycle++) begin
            @(posedge clk);
            if(dut.datapath_inst.IR[6:0]==7'h0b &&
               dut.datapath_inst.IR[31:25]==1) begin
                case(int'(dut.controller_inst.current_state))
                    2: dec=cycle;
                    3: begin
                        if(cycle-dec!=1 || dut.RegWrite || !dut.ALUOutWrite)
                            $fatal(1,"multiply control/timing");
                        execs++;
                    end
                    16: begin
                        if(cycle-dec!=2 || dut.RegWrite || dut.AWrite || dut.BWrite ||
                           !dut.ALUOutWrite || dut.ALUSrcA!=3 || dut.ALUSrcB!=3 ||
                           (rd==0 && dut.datapath_inst.ReadData1!==32'b0))
                            $fatal(1,"accumulate control/timing");
                        accum++;
                    end
                    5: begin
                        if(cycle-dec!=3 || !dut.RegWrite || dut.ALUOutWrite)
                            $fatal(1,"writeback control/timing");
                        writes++;
                    end
                    default: begin end
                endcase
            end
            if(error) begin finished=1; break; end
        end
        if(!finished || execs!=2 || accum!=2 || writes!=2) $fatal(1,"MAC counts/timeout");
        @(negedge clk);
        for(int i=1;i<8;i++)
            if(dut.datapath_inst.register_file_inst.registers[i]!==model[i])
                $fatal(1,"case %0d x%0d got=%h expected=%h",checks,i,
                    dut.datapath_inst.register_file_inst.registers[i],model[i]);
        if(mem[67]!==model[4]) $fatal(1,"store interaction");
        repeat(3) begin
            @(negedge clk);
            if(!error || dut.RegWrite || req) $fatal(1,"illegal instruction side effect");
        end
        checks++;
    endtask
    initial begin
        logic [31:0] seed;
        run_case(7,6,0,3,1,2);       // initialization and dependent accumulation
        run_case(-3,6,10,3,1,2);    // negative product / positive accumulator
        run_case(-3,-6,-100,3,1,2); // positive product / negative accumulator
        run_case(0,99,-17,3,1,2);
        run_case(32'h7fffffff,2,32'h7fffffff,3,1,2);
        run_case(32'h80000000,-1,32'hffffffff,3,1,2);
        run_case(32'h10000,32'h10000,1,3,1,2);
        run_case(7,6,10,1,1,2); // rd==rs1
        run_case(7,6,10,2,1,2); // rd==rs2
        run_case(-7,6,10,1,1,1); // all aliases
        run_case(7,6,10,0,1,2);
        run_case(7,6,10,3,0,2);
        seed=32'hac202610;
        for(int i=0;i<64;i++) begin
            logic [31:0] a,b;
            seed=seed*32'd1664525+32'd1013904223; a=seed;
            seed=seed*32'd1664525+32'd1013904223; b=seed;
            seed=seed*32'd1664525+32'd1013904223;
            run_case(a,b,seed,3,1,2);
        end
        // Abort before product, before accumulation, and before writeback.
        for(int phase=0;phase<3;phase++) begin
            int target_state;
            bit reached;
            target_state=(phase==0?3:phase==1?16:5); reached=0;
            setup(7,6,123,3,1,2);
            for(int cycle=0;cycle<80;cycle++) begin
                @(negedge clk);
                if(int'(dut.controller_inst.current_state)==target_state &&
                   dut.datapath_inst.IR[6:0]==7'h0b) begin reached=1; break; end
            end
            if(!reached) $fatal(1,"reset phase timeout");
            reset=1; mem[0]=32'h0000000b;
            repeat(2) @(negedge clk);
            if(dut.datapath_inst.ALUOut!=0 || dut.datapath_inst.PC!=0)
                $fatal(1,"reset temporaries");
            reset=0;
            repeat(5) @(negedge clk);
            if(!error || dut.datapath_inst.register_file_inst.registers[3]!==123)
                $fatal(1,"reset cancellation/recovery");
        end
        $display("PASS: CPU MAC %0d arithmetic programs, %0d dependent MACs, 3 reset phases; timing, single writeback, aliases, x0, mixed instructions, sticky illegal",checks,2*checks);
        $finish;
    end
endmodule
