// Weight-buffered conv1 proof: 64 filter commands and fused CPU output gathering.
module opencorex_conv1_weight_reuse_tb #(parameter bit CACHE_ENABLE=1);
    localparam int RAM_WORDS=262144;
    logic clk=0;
    always #5 clk <= ~clk;
    logic reset,error,memory_read_enable,memory_write_enable;
    logic [31:0] memory_address,memory_write_data,memory_read_data;
    int read_delay=1,fetch_delay=1,mode=5;
    logic [31:0] bias_pc;
    logic [31:0] raw_ref[0:1279],biased_ref[0:1279],final_ref[0:1279],patch_ref[0:539];
    logic [31:0] original_input[0:59],original_weights[0:1727],original_bias[0:63];
    cache_study_subsystem #(.ICACHE_ENABLE(CACHE_ENABLE),.RAM_WORDS(RAM_WORDS),
        .BUFFER_WORDS(128),.MAX_OUTPUTS(128),.MAC_LANES(1)) dut (
        .clk,.reset,.read_delay,.fetch_delay,.error,.memory_read_enable,
        .memory_write_enable,.memory_address,.memory_write_data,.memory_read_data
    );
    memory #(.WORDS(RAM_WORDS)) test_memory (
        .clk,.read_enable(memory_read_enable),.write_enable(memory_write_enable),
        .address(memory_address),.write_data(memory_write_data),.read_data(memory_read_data)
    );
    int states[0:16],phase_cycles[0:3];
    int phase=0,phase_writes=0,done_edge=-1;
    int fetches=0,hits=0,misses=0,refill_reads=0,ram_reads=0,ram_writes=0,responses=0;
    int input_reads=0,patch_reads=0,weight_reads=0,bias_reads=0,post_reads=0;
    int literal_reads=0,signature_reads=0,patch_writes=0,raw_writes=0,final_writes=0,biased_checks=0;
    int dot_muls=0,dot_macs=0,packing_muls=0,pim_macs=0;
    int mmio_writes=0,mmio_reads=0,status_responses=0,commands=0,busy_cycles=0;
    int buffer_writes=0,buffer_reads=0,begin_vectors=0,command_cycles=0,start_edge=-1;
    bit fetch_pending=0,ram_pending=0,predicted_miss=0,stalled=0,cpu_stalled=0;
    int fetch_due=0,ram_due=0,ram_kind=0,refill_index=0,trace_fd=0;
    logic [31:0] fetch_address,ram_data,held_pc;
    logic [64:0] held_request;
    logic [65:0] held_cpu;
    bit valid_lines[0:31];
    logic [22:0] tags[0:31];

    task automatic metric(input string name,input int value);
        $display("METRIC,%s,%0d",name,value);
    endtask

    initial begin : experiment
        string image,raw_file,biased_file,final_file,patch_file,trace_file;
        if (!$value$plusargs("IMAGE=%s",image) ||
            !$value$plusargs("RAW=%s",raw_file) ||
            !$value$plusargs("BIASED=%s",biased_file) ||
            !$value$plusargs("FINAL=%s",final_file) ||
            !$value$plusargs("PATCHES=%s",patch_file) ||
            !$value$plusargs("BIAS_PC=%h",bias_pc)) $fatal(1,"missing image/reference arguments");
        if (!$value$plusargs("MODE=%d",mode)) mode=5;
        if (!$value$plusargs("DELAY=%d",read_delay)) read_delay=1;
        if (mode!=5 || read_delay<1 || read_delay>20) $fatal(1,"invalid study arguments");
        fetch_delay=read_delay;
        if ($value$plusargs("TRACE=%s",trace_file)) begin
            trace_fd=$fopen(trace_file,"wb");
            if (trace_fd==0) $fatal(1,"cannot open fetch trace");
        end
        foreach(states[i]) states[i]=0;
        foreach(phase_cycles[i]) phase_cycles[i]=0;
        foreach(valid_lines[i]) begin valid_lines[i]=0; tags[i]=0; end
        reset=1;
        #1;
        $readmemh(image,test_memory.mem);
        $readmemh(raw_file,raw_ref);
        $readmemh(biased_file,biased_ref);
        $readmemh(final_file,final_ref);
        $readmemh(patch_file,patch_ref);
        if ($test$plusargs("CODE_WRITE")) test_memory.mem[0]=32'h00002023;
        if ($test$plusargs("BAD_BIAS")) test_memory.mem['h8800]^=1;
        // Offset the gather LW by one word: its three-instruction prefix precedes bias_pc.
        if ($test$plusargs("BAD_GATHER"))
            test_memory.mem[(bias_pc-12)>>2]+=32'h00400000;
        repeat(2) @(posedge clk);
        foreach(original_input[i]) original_input[i]=test_memory.mem['h4000+i];
        foreach(original_weights[i]) original_weights[i]=test_memory.mem['h8000+i];
        foreach(original_bias[i]) original_bias[i]=test_memory.mem['h8800+i];
        @(negedge clk); reset=0;
        if (dut.accelerator_inst.buffer_valid_count!=0 || dut.accelerator_inst.buffer_vector_full)
            $fatal(1,"buffer reset metadata");
        for (int cycle=0;cycle<10000000;cycle++) begin
            @(posedge clk);
            states[int'(dut.core_inst.controller_inst.current_state)]++;
            phase_cycles[phase]++;
            if (error || dut.accelerator_inst.ctrl_error_set || dut.accelerator_inst.mmio.status_error)
                $fatal(1,"CPU or accelerator error");
            if (stalled && (!dut.mem_req_valid ||
                {dut.mem_req_write,dut.mem_req_addr,dut.mem_req_wdata}!==held_request))
                $fatal(1,"backing request changed while stalled");
            stalled=dut.mem_req_valid && !dut.mem_req_ready;
            held_request={dut.mem_req_write,dut.mem_req_addr,dut.mem_req_wdata};
            if (cpu_stalled && (!dut.cpu_req_valid ||
                {dut.cpu_req_is_fetch,dut.cpu_req_write,dut.cpu_req_addr,dut.cpu_req_wdata}!==held_cpu))
                $fatal(1,"CPU request changed while stalled");
            cpu_stalled=dut.cpu_req_valid && !dut.cpu_req_ready;
            held_cpu={dut.cpu_req_is_fetch,dut.cpu_req_write,dut.cpu_req_addr,dut.cpu_req_wdata};

            if (dut.cpu_req_valid && dut.cpu_req_ready && dut.cpu_req_is_fetch) begin
                logic [31:0] instruction,trace_word;
                logic unused_instruction;
                if (fetch_pending || (dut.cpu_req_addr!=0 &&
                    !(dut.cpu_req_addr>='h1000 && dut.cpu_req_addr<'h5000)))
                    $fatal(1,"invalid fetch address or overlap");
                fetch_pending=1; fetch_address=dut.cpu_req_addr; fetches++; refill_index=0;
                instruction=test_memory.mem[fetch_address>>2];
                unused_instruction=^instruction;
                if (instruction[6:0]==7'h33 && instruction[31:25]==1 && instruction[14:12]==0) begin
                    if (phase==1) packing_muls++;
                    else if (phase==2) dot_muls++;
                    else $fatal(1,"multiply outside packing/compute");
                end
                if (instruction[6:0]==7'h0b) begin
                    if (phase!=2 || mode!=3) $fatal(1,"unexpected CPU MAC");
                    dot_macs++;
                end
                if (fetch_address==bias_pc) begin
                    if (phase!=3 || biased_checks>=1280 ||
                        dut.core_inst.datapath_inst.register_file_inst.registers[11]!==biased_ref[biased_checks])
                        $fatal(1,"biased intermediate mismatch at %0d",biased_checks);
                    biased_checks++;
                end
                predicted_miss=!valid_lines[fetch_address[8:4]] ||
                               tags[fetch_address[8:4]]!=fetch_address[31:9];
                if (CACHE_ENABLE) begin
                    if (predicted_miss) misses++; else hits++;
                    valid_lines[fetch_address[8:4]]=1;
                    tags[fetch_address[8:4]]=fetch_address[31:9];
                end
                fetch_due=cycle+(CACHE_ENABLE?(predicted_miss?6+4*read_delay:2):read_delay);
                trace_word=fetch_address | ((CACHE_ENABLE && predicted_miss)?32'h80000000:0);
                if (trace_fd!=0) $fwrite(trace_fd,"%c%c%c%c",
                    trace_word[7:0],trace_word[15:8],trace_word[23:16],trace_word[31:24]);
            end
            if (fetch_pending && dut.cpu_rsp_valid) begin
                if (cycle!=fetch_due || dut.cpu_rsp_rdata!==test_memory.mem[fetch_address>>2] ||
                    (CACHE_ENABLE && predicted_miss && refill_index!=4))
                    $fatal(1,"fetch response timing/data/refill");
                fetch_pending=0;
            end
            if (memory_read_enable && memory_write_enable) $fatal(1,"shared RAM port collision");
            if ((memory_read_enable || memory_write_enable) &&
                (memory_address[1:0]!=0 || memory_address>=RAM_WORDS*4))
                $fatal(1,"RAM range/alignment");
            if (dut.mem_rsp_valid) begin
                if (!ram_pending || cycle!=ram_due || dut.mem_rsp_rdata!==ram_data)
                    $fatal(1,"RAM response timing/data");
                if (ram_kind==2) begin
                    if (!dut.pim_rsp_valid || dut.cpu_rsp_valid || dut.cache_rsp_valid)
                        $fatal(1,"PIM response owner");
                end else if (!dut.cache_rsp_valid || dut.pim_rsp_valid)
                    $fatal(1,"CPU response owner");
                ram_pending=0; responses++;
            end else if (ram_pending && cycle>=ram_due) $fatal(1,"missing RAM response");
            if (memory_read_enable) begin
                if (ram_pending || dut.mem_rsp_valid) $fatal(1,"more than one outstanding RAM read");
                ram_pending=1; ram_due=cycle+read_delay; ram_reads++;
                ram_data=test_memory.mem[memory_address>>2];
                if (dut.pim_req_valid && dut.pim_req_ready) begin
                    if (phase!=2 || commands==0 || raw_writes>=20*commands)
                        $fatal(1,"PIM read outside active command");
                    ram_kind=2;
                end else begin
                    if (!dut.cache_req_valid || !dut.cache_req_ready) $fatal(1,"unowned RAM read");
                    ram_kind=fetch_pending?0:1;
                end
                if (ram_kind==0) begin
                    if (CACHE_ENABLE) begin
                        if (!predicted_miss || refill_index>=4 ||
                            memory_address!=((fetch_address&32'hfffffff0)+32'(4*refill_index)))
                            $fatal(1,"instruction refill order");
                        refill_reads++; refill_index++;
                    end
                end else if (memory_address>='h10000 && memory_address<'h100f0) begin
                    if (phase!=1 || ram_kind!=1) $fatal(1,"input read outside CPU packing");
                    input_reads++;
                end else if (memory_address>='h11000 && memory_address<'h11870) begin
                    if (phase!=2 || ram_kind!=2 ||
                        memory_address!='h11000+32'(4*(patch_reads%540)))
                        $fatal(1,"patch read sequence/owner");
                    patch_reads++;
                end else if (memory_address>='h20000 && memory_address<'h21b00) begin
                    if (phase!=2 || ram_kind!=2 ||
                        memory_address!='h20000+32'(4*weight_reads))
                        $fatal(1,"weight read sequence/owner");
                    weight_reads++;
                end else if (memory_address>='h22000 && memory_address<'h22100) begin
                    if (phase!=3 || ram_kind!=1 || memory_address!='h22000+32'(4*(bias_reads%64)))
                        $fatal(1,"bias read sequence/owner");
                    bias_reads++;
                end else if (memory_address>='h32000 && memory_address<'h33400) begin
                    if (phase!=3 || ram_kind!=1 || post_reads>=1280 ||
                        memory_address!='h32000+32'(4*((post_reads%64)*20+post_reads/64)) ||
                        ram_data!==raw_ref[post_reads])
                        $fatal(1,"postprocessing raw read");
                    post_reads++;
                end else if (ram_kind==1 && memory_address>='h500 && memory_address<'h600)
                    literal_reads++;
                else if (ram_kind==1 && memory_address=='h440 && phase==3) signature_reads++;
                else $fatal(1,"unexpected RAM data read %h",memory_address);
            end
            if (memory_write_enable) begin
                ram_writes++;
                if (ram_pending || dut.mem_rsp_valid) $fatal(1,"write with outstanding read");
                if (memory_address>='h11000 && memory_address<'h11870) begin
                    if (phase!=1 || patch_writes>=540 || memory_address!='h11000+32'(4*patch_writes) ||
                        memory_write_data!==patch_ref[patch_writes] || dut.pim_req_valid)
                        $fatal(1,"packed patch mismatch at %0d",patch_writes);
                    patch_writes++;
                end else if (memory_address>='h32000 && memory_address<'h33400) begin
                    if (phase!=2 || raw_writes>=1280 || memory_address!='h32000+32'(4*raw_writes) ||
                        memory_write_data!==raw_ref[(raw_writes%20)*64+raw_writes/20] ||
                        !(dut.pim_req_valid && dut.pim_req_ready))
                        $fatal(1,"raw filter-first output mismatch at %0d",raw_writes);
                    raw_writes++;
                    if (raw_writes%20==0) begin
                        command_cycles+=cycle-start_edge;
                        $display("COMMAND,%0d,%0d,%0d,%0d",commands-1,start_edge,cycle,cycle-start_edge);
                    end
                end else if (memory_address>='h30000 && memory_address<'h31400) begin
                    if (phase!=3 || final_writes>=1280 || memory_address!='h30000+32'(4*final_writes) ||
                        memory_write_data!==final_ref[final_writes] || dut.pim_req_valid)
                        $fatal(1,"final output mismatch at %0d",final_writes);
                    final_writes++;
                end else if (memory_address=='h448) begin
                    if (memory_write_data!=32'(phase+1) || phase>=3 || dut.pim_req_valid)
                        $fatal(1,"invalid phase marker");
                    if (phase==1 && patch_writes!=540) $fatal(1,"premature packing completion");
                    if (phase==2 && (raw_writes!=1280 || status_responses!=64))
                        $fatal(1,"premature compute completion");
                    phase=int'(memory_write_data); phase_writes++;
                end else if (memory_address=='h444) begin
                    if (memory_write_data!==32'h524b5943 || phase!=3 || raw_writes!=1280 ||
                        final_writes!=1280 || biased_checks!=1280 || dut.pim_busy)
                        $fatal(1,"premature/invalid completion");
                    done_edge=cycle;
                end else $fatal(1,"unexpected RAM write %h",memory_address);
            end
            if (dut.mmio_req_valid && dut.mmio_req_ready) begin
                if (phase!=2 || memory_read_enable || memory_write_enable)
                    $fatal(1,"MMIO isolation");
                if (dut.mmio_req_write) begin
                    mmio_writes++;
                    if (dut.mmio_req_addr=='h40000018) begin
                        if (commands>=64 || raw_writes!=commands*20 || status_responses!=commands ||
                            dut.mmio_req_wdata!=1 || dut.pim_busy ||
                            dut.accelerator_inst.mmio.cmd_descriptor.vector_base!='h20000+32'(108*commands) ||
                            dut.accelerator_inst.mmio.cmd_descriptor.matrix_base!='h11000 ||
                            dut.accelerator_inst.mmio.cmd_descriptor.output_base!='h32000+32'(80*commands) ||
                            dut.accelerator_inst.mmio.cmd_descriptor.vector_length!=27 ||
                            dut.accelerator_inst.mmio.cmd_descriptor.matrix_column_stride!=108 ||
                            dut.accelerator_inst.mmio.cmd_descriptor.output_count!=20)
                            $fatal(1,"wrong command descriptor/freshness");
                        start_edge=cycle; commands++;
                    end
                end else begin
                    if (dut.mmio_req_addr!='h4000001c || dut.pim_busy) $fatal(1,"invalid status read");
                    mmio_reads++;
                end
            end
            if (dut.mmio_rsp_valid) begin
                if (status_responses>=mmio_reads || dut.mmio_rsp_rdata!==32'd10)
                    $fatal(1,"invalid status response");
                status_responses++;
            end
            if (dut.pim_busy) begin
                busy_cycles++;
                if (dut.cpu_req_ready || dut.ram_req_valid || dut.mmio_req_valid ||
                    dut.core_inst.datapath_inst.PC!==held_pc) $fatal(1,"CPU not blocked");
            end
            if (dut.accelerator_inst.buffer_begin_vector) begin_vectors++;
            if (dut.accelerator_inst.buffer_write_enable) buffer_writes++;
            if (dut.accelerator_inst.buffer_read_enable) buffer_reads++;
            if (dut.accelerator_inst.mac_start) pim_macs++;
            if (start_edge==cycle) begin #1; held_pc=dut.core_inst.datapath_inst.PC; end
            if (done_edge>=0) break;
        end
        if (done_edge<0 || ram_pending || fetch_pending || ram_reads!=responses) $fatal(1,"incomplete run");
        @(negedge clk);
        foreach(original_input[i])
            if (test_memory.mem['h4000+i]!==original_input[i]) $fatal(1,"input modified");
        foreach(original_weights[i])
            if (test_memory.mem['h8000+i]!==original_weights[i]) $fatal(1,"weights modified");
        foreach(original_bias[i])
            if (test_memory.mem['h8800+i]!==original_bias[i]) $fatal(1,"bias modified");
        foreach(final_ref[i])
            if (test_memory.mem['hc000+i]!==final_ref[i]) $fatal(1,"stored final output");
        if (patch_writes!=540 || input_reads!=390 || weight_reads!=1728 || patch_reads!=34560 ||
            bias_reads!=1280 || post_reads!=1280 || phase_writes!=3 || signature_reads!=1 ||
            packing_muls!=1170 || dot_muls!=0 || dot_macs!=0 || pim_macs!=34560 ||
            mmio_writes!=448 || mmio_reads!=64 || status_responses!=64 || commands!=64 ||
            ram_writes!=3104) $fatal(1,"unexpected weight-reuse traffic counts");
        if (buffer_writes!=1728 || buffer_reads!=32832 || begin_vectors!=64 ||
            busy_cycles!=command_cycles || dut.accelerator_inst.buffer_valid_count!=27 ||
            !dut.accelerator_inst.buffer_vector_full ||
            dut.accelerator_inst.resident_vector_base!='h20000+108*63 ||
            dut.accelerator_inst.vector_buffer.words[26]!==original_weights[1727])
            $fatal(1,"weight-vector residency/reuse counts");
        for (int i=0;i<1280;i++)
            if (test_memory.mem['hc800+i]!==raw_ref[(i%20)*64+i/20])
                $fatal(1,"raw filter-first allocation modified");
        if (CACHE_ENABLE && (fetches!=hits+misses || refill_reads!=4*misses)) $fatal(1,"cache counters");
        if (trace_fd!=0) $fclose(trace_fd);
        metric("whole_cycles",done_edge+1);
        metric("setup_cycles",phase_cycles[0]); metric("packing_cycles",phase_cycles[1]);
        metric("compute_cycles",phase_cycles[2]); metric("post_cycles",phase_cycles[3]);
        metric("fetches",fetches); metric("hits",hits); metric("misses",misses);
        metric("refill_reads",refill_reads); metric("ram_reads",ram_reads); metric("ram_writes",ram_writes);
        metric("input_reads",input_reads); metric("patch_reads",patch_reads); metric("weight_reads",weight_reads);
        metric("bias_reads",bias_reads); metric("post_reads",post_reads);
        metric("literal_reads",literal_reads); metric("signature_reads",signature_reads);
        metric("patch_writes",patch_writes); metric("raw_writes",raw_writes);
        metric("final_writes",final_writes); metric("biased_checks",biased_checks);
        metric("cpu_dot_muls",dot_muls); metric("cpu_dot_macs",dot_macs);
        metric("packing_muls",packing_muls); metric("pim_macs",pim_macs);
        metric("mmio_writes",mmio_writes); metric("mmio_reads",mmio_reads);
        metric("commands",commands); metric("busy_cycles",busy_cycles);
        metric("phase_writes",phase_writes); metric("completion_writes",1);
        metric("buffer_writes",buffer_writes); metric("buffer_reads",buffer_reads);
        for (int i=0;i<17;i++) $display("STATE,%0d,%0d",i,states[i]);
        $display("PASS: opencorex_conv1_weight_reuse_tb");
        $finish;
    end
endmodule
