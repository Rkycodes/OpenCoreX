// Square GEMM harness: production topology with only test RAM responder replaced.
module opencorex_gemm_tb #(parameter bit CACHE_ENABLE=0);
    localparam int RAM_WORDS=262144;
    logic clk=0;
    always #5 clk <= ~clk;
    logic reset, error, memory_read_enable, memory_write_enable;
    logic [31:0] memory_address, memory_write_data, memory_read_data;
    int read_delay=1, fetch_delay=1, mode=1, n=16, k=16;
    logic [31:0] expected [0:1023], original_vector [0:1023], original_matrix [0:1023];
    cache_study_subsystem #(.ICACHE_ENABLE(CACHE_ENABLE), .RAM_WORDS(RAM_WORDS),
        .MAX_OUTPUTS(128), .BUFFER_WORDS(128), .MAC_LANES(1)) dut (
        .clk, .reset, .read_delay, .fetch_delay, .error, .memory_read_enable,
        .memory_write_enable, .memory_address, .memory_write_data, .memory_read_data
    );
    memory #(.WORDS(RAM_WORDS)) test_memory (
        .clk, .read_enable(memory_read_enable), .write_enable(memory_write_enable),
        .address(memory_address), .write_data(memory_write_data), .read_data(memory_read_data)
    );
    int fetches=0,hits=0,misses=0,refill_reads=0,muls=0,adds=0,macs=0;
    int vector_reads=0,matrix_reads=0,outputs=0,cpu_other=0,completion=0;
    int literal_reads=0,signature_reads=0;
    int mmio_w=0,mmio_r=0,mmio_responses=0,blocked=0,busy_blocked=0,busy_cycles=0;
    int fetch_wait=0,data_wait=0,pim_wait=0,cpu_fetch_wait=0,ram_writes=0,other_writes=0;
    int states [0:15];
    int commands_started=0,command_cycles=0,command_final=-1;
    int start_edge=-1,final_edge=-1,done_edge=-1,buffer_writes=0,buffer_reads=0,begin_vector=0;
    bit fetch_pending=0,predicted_miss=0,ram_pending=0,stalled=0,cpu_stalled=0;
    int fetch_due=0,refill_index=0,ram_due=0,ram_kind=0,reads=0,responses=0;
    logic [31:0] fetch_address=0,ram_data=0,held_pc=0;
    logic [64:0] stalled_payload=0;
    logic [65:0] cpu_payload=0;
    bit valid_lines [0:31];
    logic [22:0] tags [0:31];

    initial begin : experiment
        string image,reference_image;
        if (!$value$plusargs("MODE=%d",mode)) mode=1;
        if (!$value$plusargs("N=%d",n)) n=16;
        k=n;
        if (!$value$plusargs("DELAY=%d",read_delay)) read_delay=1;
        if ((mode<1 || mode>3) || (n!=16 && n!=32) ||
            read_delay<1 || read_delay>20) $fatal(1,"invalid GEMM arguments");
        fetch_delay=read_delay;
        if(mode==1) image=$sformatf("programs/gemm/hex/streaming_%0d.hex",k);
        else if(mode==2) image=$sformatf("programs/gemm/hex/tiled_%0d.hex",k);
        else image=$sformatf("programs/gemm/hex/offload_%0d.hex",k);
        reference_image=$sformatf("programs/gemm/hex/expected_%0d.hex",k);
        foreach(states[i]) states[i]=0;
        foreach(valid_lines[i]) begin valid_lines[i]=0; tags[i]=0; end
        reset=1;
        #1;
        $readmemh(image,test_memory.mem);
        $readmemh(reference_image,expected);
        if ($test$plusargs("CODE_WRITE")) test_memory.mem[0]=32'h00002023;
        if ($test$plusargs("PIM_CODE_WRITE")) test_memory.mem['h102]='h1000;
        repeat(2) @(posedge clk);
        for (int i=0;i<n*n;i++) original_vector[i]=test_memory.mem['h4000+i];
        for (int i=0;i<k*n;i++) original_matrix[i]=test_memory.mem['h8000+i];
        @(negedge clk); reset=0;
        if(dut.accelerator_inst.buffer_valid_count!=0 || dut.accelerator_inst.buffer_vector_full)
            $fatal(1,"buffer reset validity");
        for(int cycle=0;cycle<20000000;cycle++) begin
            @(posedge clk);
            states[int'(dut.core_inst.controller_inst.current_state)]++;
            if(fetch_pending && !dut.cpu_rsp_valid) cpu_fetch_wait++;
            if(error || dut.accelerator_inst.ctrl_error_set || dut.accelerator_inst.mmio.status_error)
                $fatal(1,"CPU/offload error");
            if(stalled && (!dut.mem_req_valid ||
                {dut.mem_req_write,dut.mem_req_addr,dut.mem_req_wdata}!==stalled_payload))
                $fatal(1,"backing request changed under stall");
            stalled=dut.mem_req_valid && !dut.mem_req_ready;
            stalled_payload={dut.mem_req_write,dut.mem_req_addr,dut.mem_req_wdata};
            if(cpu_stalled && (!dut.cpu_req_valid ||
                {dut.cpu_req_is_fetch,dut.cpu_req_write,dut.cpu_req_addr,dut.cpu_req_wdata}!==cpu_payload))
                $fatal(1,"CPU request/classification changed under stall");
            cpu_stalled=dut.cpu_req_valid && !dut.cpu_req_ready;
            cpu_payload={dut.cpu_req_is_fetch,dut.cpu_req_write,dut.cpu_req_addr,dut.cpu_req_wdata};

            if(dut.cpu_req_valid && dut.cpu_req_ready && dut.cpu_req_is_fetch) begin
                logic [31:0] instruction;
                logic unused_operands;
                if(fetch_pending || (dut.cpu_req_addr!=0 &&
                    !(dut.cpu_req_addr>='h1000 && dut.cpu_req_addr<'h5000)))
                    $fatal(1,"invalid/overlapping fetch");
                fetch_pending=1; fetch_address=dut.cpu_req_addr; refill_index=0; fetches++;
                instruction=test_memory.mem[fetch_address>>2];
                unused_operands=^instruction[24:15];
                if(instruction[6:0]==7'h33 && instruction[31:25]==1 && instruction[14:12]==0) muls++;
                if(instruction[6:0]==7'h33 && instruction[31:25]==0 &&
                   instruction[14:12]==0 && (instruction[11:7]==11 || instruction[11:7]==15 ||
                    instruction[11:7]==16 || instruction[11:7]==17)) adds++;
                predicted_miss=!valid_lines[fetch_address[8:4]] ||
                    tags[fetch_address[8:4]]!=fetch_address[31:9];
                if(CACHE_ENABLE) begin
                    if(predicted_miss) misses++; else hits++;
                    valid_lines[fetch_address[8:4]]=1;
                    tags[fetch_address[8:4]]=fetch_address[31:9];
                end
                fetch_due=cycle+(CACHE_ENABLE?(predicted_miss?6+4*read_delay:2):read_delay);
                $display("FETCH,%0d,%0d",fetch_address,CACHE_ENABLE && predicted_miss);
            end
            if(fetch_pending && dut.cpu_rsp_valid) begin
                if(cycle!=fetch_due || dut.cpu_rsp_rdata!==test_memory.mem[fetch_address>>2] ||
                   (CACHE_ENABLE && predicted_miss && refill_index!=4))
                    $fatal(1,"fetch response deadline/data/refill");
                fetch_pending=0;
            end
            if(memory_read_enable && memory_write_enable) $fatal(1,"RAM port collision");
            if((memory_read_enable || memory_write_enable) &&
               (memory_address[1:0]!=0 || memory_address>=RAM_WORDS*4))
                $fatal(1,"RAM range/alignment");
            if(dut.mem_rsp_valid) begin
                if(!ram_pending || cycle!=ram_due || dut.mem_rsp_rdata!==ram_data)
                    $fatal(1,"RAM response deadline/data");
                if(ram_kind==2) begin
                    if(!dut.pim_rsp_valid || dut.cpu_rsp_valid || dut.cache_rsp_valid)
                        $fatal(1,"PIM response ownership");
                end else if(!dut.cache_rsp_valid || dut.pim_rsp_valid)
                    $fatal(1,"CPU response ownership");
                ram_pending=0; responses++;
            end else if(ram_pending) begin
                if(cycle>=ram_due) $fatal(1,"missing backing response");
                case(ram_kind)
                    0: fetch_wait++;
                    1: data_wait++;
                    2: pim_wait++;
                    default: $fatal(1,"invalid owner");
                endcase
            end
            if(memory_read_enable) begin
                if(ram_pending || dut.mem_rsp_valid) $fatal(1,"overlapping backing reads");
                ram_pending=1; ram_due=cycle+read_delay; reads++;
                ram_data=test_memory.mem[memory_address>>2];
                if(dut.pim_req_valid && dut.pim_req_ready) begin
                    if(mode!=3 || commands_started==0 || outputs>=commands_started*n) $fatal(1,"PIM read outside command");
                    ram_kind=2;
                end else begin
                    if(!dut.cache_req_valid || !dut.cache_req_ready) $fatal(1,"unowned backing read");
                    ram_kind=fetch_pending?0:1;
                end
                if(ram_kind==0) begin
                    if(CACHE_ENABLE) begin
                        if(!predicted_miss || refill_index>=4 ||
                           memory_address!=((fetch_address&32'hfffffff0)+32'(4*refill_index)))
                            $fatal(1,"refill sequence");
                        refill_reads++; refill_index++;
                    end
                end else if(memory_address>='h10000 && memory_address<'h10000+32'(4*n*n)) begin
                    if(memory_address!='h10000+32'(4*((vector_reads/(mode==1?n*n:mode==2?n*n/4:n))*n+vector_reads%n))) $fatal(1,"vector sequence");
                    vector_reads++;
                end else if(memory_address>='h20000 && memory_address<'h20000+32'(4*k*n)) begin
                    if(memory_address!='h20000+32'(4*(mode==2?
                        ((matrix_reads%(n*n))/(4*k))*(4*k)+(matrix_reads%4)*k+(matrix_reads%(4*k))/4:
                        matrix_reads%(n*n)))) $fatal(1,"matrix sequence");
                    matrix_reads++;
                end else if(ram_kind==1 && ((memory_address>='h400 && memory_address<'h41c) ||
                                           memory_address=='h440)) begin
                    cpu_other++;
                    if(memory_address=='h440) signature_reads++; else literal_reads++;
                end
                else $fatal(1,"unexpected operand/data read");
            end
            if(memory_write_enable) begin
                ram_writes++;
                if(ram_pending || dut.mem_rsp_valid) $fatal(1,"write during read");
                if(memory_address<'h10 || (memory_address>='h1000 && memory_address<'h5000))
                    $fatal(1,"immutable executable code write");
                if(memory_address>='h30000 && memory_address<'h30000+32'(4*n*n)) begin
                    if(outputs>=n*n || memory_address!='h30000+32'(4*outputs) ||
                       memory_write_data!==expected[outputs] ||
                       (mode==3 && (!dut.pim_req_valid || !dut.pim_req_ready)))
                        $fatal(1,"wrong output/address/owner");
                    outputs++;
                    if(mode==3 && outputs%n==0) begin
                        command_final=cycle;
                        command_cycles+=cycle-start_edge;
                        $display("ROW,%0d,%0d,%0d,%0d",commands_started-1,start_edge,cycle,cycle-start_edge);
                    end
                    if(outputs==n*n) final_edge=cycle;
                end else if(memory_address=='h444) begin
                    if(outputs!=n*n || memory_write_data!==32'h524b5943 || completion!=0 ||
                       (mode==3 && (dut.pim_busy || mmio_responses!=n)))
                        $fatal(1,"premature/invalid completion");
                    completion++; done_edge=cycle;
                end else begin other_writes++; $fatal(1,"unexpected RAM write"); end
            end
            if(dut.mmio_req_valid && dut.mmio_req_ready) begin
                if(mode!=3 || memory_read_enable || memory_write_enable) $fatal(1,"MMIO isolation");
                if(dut.mmio_req_write) begin
                    mmio_w++;
                    if(dut.mmio_req_addr=='h40000018) begin
                        if(commands_started>=n || outputs!=commands_started*n || mmio_responses!=commands_started ||
                           dut.mmio_req_wdata!=1 || dut.pim_busy ||
                           dut.accelerator_inst.mmio.cmd_descriptor.vector_base!='h10000+32'(4*n*commands_started) ||
                           dut.accelerator_inst.mmio.cmd_descriptor.output_base!=
                               ($test$plusargs("PIM_CODE_WRITE")?32'h1000:32'h30000+32'(4*n*commands_started)) ||
                           dut.accelerator_inst.mmio.cmd_descriptor.matrix_base!='h20000 ||
                           dut.accelerator_inst.mmio.cmd_descriptor.vector_length!=32'(n) ||
                           dut.accelerator_inst.mmio.cmd_descriptor.output_count!=32'(n) ||
                           dut.accelerator_inst.mmio.cmd_descriptor.matrix_column_stride!=32'(4*n))
                            $fatal(1,"invalid/non-cold START");
                        start_edge=cycle; commands_started++;
                    end
                end else begin
                    if(dut.mmio_req_addr!='h4000001c) $fatal(1,"unexpected MMIO read");
                    mmio_r++;
                end
            end
            if(dut.mmio_rsp_valid) begin
                if(mmio_responses>=mmio_r || dut.mmio_rsp_rdata!==32'd10)
                    $fatal(1,"status response");
                mmio_responses++;
            end
            if(dut.cpu_req_valid && !dut.cpu_req_ready) blocked++;
            if(dut.pim_busy) begin
                busy_cycles++;
                if(start_edge<0 || dut.cpu_req_ready || dut.ram_req_valid || dut.mmio_req_valid ||
                   dut.core_inst.datapath_inst.PC!==held_pc) $fatal(1,"busy behavior");
                if(dut.cpu_req_valid) busy_blocked++;
            end
            if(dut.accelerator_inst.buffer_invalidate) $fatal(1,"unexpected invalidation");
            if(dut.accelerator_inst.buffer_begin_vector) begin_vector++;
            if(dut.accelerator_inst.buffer_write_enable) begin
                buffer_writes++;
            end
            if(dut.accelerator_inst.buffer_read_enable) begin
                buffer_reads++;
            end
            if(dut.accelerator_inst.mac_start) macs++;
            if(start_edge==cycle) begin #1; held_pc=dut.core_inst.datapath_inst.PC; end
            if(done_edge>=0) break;
        end
        if(done_edge<0 || ram_pending || fetch_pending || reads!=responses) $fatal(1,"incomplete run");
        @(negedge clk);
        for(int i=0;i<n*n;i++)
            if(test_memory.mem['hc000+i]!==expected[i]) $fatal(1,"stored output");
        for(int i=0;i<n*n;i++)
            if(test_memory.mem['h4000+i]!==original_vector[i]) $fatal(1,"vector modified");
        for(int i=0;i<k*n;i++)
            if(test_memory.mem['h8000+i]!==original_matrix[i]) $fatal(1,"matrix modified");
        if(test_memory.mem['h111]!==32'h524b5943) $fatal(1,"stored completion");
        if(vector_reads!=(mode==1?n*n*n:mode==2?n*n*n/4:n*n) || matrix_reads!=n*n*n ||
           outputs!=n*n || completion!=1 ||
           muls!=(mode!=3?n*n*n:0) || adds!=(mode!=3?n*n*n:0) ||
           macs!=(mode==3?n*n*n:0) || mmio_w!=(mode==3?7*n:0) || mmio_r!=(mode==3?n:0) ||
           mmio_responses!=mmio_r) $fatal(1,"unexpected GEMM counters");
        if(literal_reads!=(mode==3?6+n:5) || signature_reads!=1)
            $fatal(1,"literal/signature accounting");
        if(mode==3 && (commands_started!=n || buffer_writes!=n*n || buffer_reads!=n*n*(n-1) ||
           begin_vector!=n || busy_cycles!=command_cycles || command_final!=final_edge ||
           int'(dut.accelerator_inst.buffer_valid_count)!=n || !dut.accelerator_inst.buffer_vector_full ||
           dut.accelerator_inst.vector_buffer.words[n-1]!==original_vector[n*n-1]))
            $fatal(1,"cold row command/buffer accounting");
        if(CACHE_ENABLE && (fetches!=hits+misses || refill_reads!=4*misses)) $fatal(1,"cache counters");
        $display("PROGRAM,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d",
            mode,read_delay,fetch_delay,done_edge+1,fetches,vector_reads,matrix_reads,
            outputs,completion,mmio_w,mmio_r,blocked,busy_blocked,fetch_wait,data_wait,pim_wait);
        $display("CACHE,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d",
            hits,misses,refill_reads,muls,adds,macs,cpu_other,cpu_fetch_wait,busy_cycles);
        $display("EXTRA,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d",
            reads,ram_writes,other_writes,literal_reads,signature_reads,buffer_writes,buffer_reads,
            commands_started,command_cycles,begin_vector);
        for(int i=0;i<16;i++) $display("STATE,%0d,%0d",i,states[i]);
        $display("PASS: opencorex_gemm_tb N=%0d",n);
        $finish;
    end
endmodule
