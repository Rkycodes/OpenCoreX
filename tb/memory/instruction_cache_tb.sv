module instruction_cache_tb;
    logic clk=0;
    always #5 clk <= ~clk;
    logic reset=1, busy=0, allow_memory=1;
    logic cpu_req_valid=0, cpu_req_write=0, cpu_req_is_fetch=0;
    logic [31:0] cpu_req_addr=0, cpu_req_wdata=0;
    logic cpu_req_ready, cpu_rsp_valid;
    logic [31:0] cpu_rsp_rdata;
    logic ram_req_valid, ram_req_ready, ram_req_write, ram_req_is_fetch;
    logic [31:0] ram_req_addr, ram_req_wdata;
    logic ram_rsp_valid;
    logic [31:0] ram_rsp_rdata;
    logic mmio_req_valid, mmio_req_ready, mmio_req_write, mmio_rsp_valid=0;
    logic [31:0] mmio_req_addr, mmio_req_wdata, mmio_rsp_rdata;
    logic mem_req_valid, mem_req_ready, mem_req_write, model_ready, mem_rsp_valid;
    logic [31:0] mem_req_addr, mem_req_wdata, mem_rsp_rdata;
    logic memory_read_enable, memory_write_enable;
    logic [31:0] memory_address, memory_write_data, memory_read_data;
    int read_delay=1, fetch_delay=1;
    int edge_index=0, reads=0, writes=0, mmio_reads=0;
    bit stalled=0;
    logic [31:0] stalled_addr=0, stalled_data=0;
    logic stalled_write=0, stalled_fetch=0;
    logic unused_mmio;

    cpu_address_router #(.RAM_WORDS(1024)) router (
        .clk, .reset, .cpu_req_valid, .cpu_req_ready, .cpu_req_write,
        .cpu_req_is_fetch, .cpu_req_addr, .cpu_req_wdata,
        .cpu_rsp_valid, .cpu_rsp_rdata,
        .ram_req_valid, .ram_req_ready, .ram_req_write, .ram_req_is_fetch,
        .ram_req_addr, .ram_req_wdata, .ram_rsp_valid, .ram_rsp_rdata,
        .mmio_req_valid, .mmio_req_ready, .mmio_req_write, .mmio_req_addr,
        .mmio_req_wdata, .mmio_rsp_valid, .mmio_rsp_rdata, .pim_busy(busy)
    );
    instruction_cache #(.ENABLE(1'b1)) dut (
        .clk, .reset, .cpu_req_valid(ram_req_valid), .cpu_req_ready(ram_req_ready),
        .cpu_req_write(ram_req_write), .cpu_req_is_fetch(ram_req_is_fetch),
        .cpu_req_addr(ram_req_addr), .cpu_req_wdata(ram_req_wdata),
        .cpu_rsp_valid(ram_rsp_valid), .cpu_rsp_rdata(ram_rsp_rdata),
        .mem_req_valid, .mem_req_ready, .mem_req_write, .mem_req_addr,
        .mem_req_wdata, .mem_rsp_valid, .mem_rsp_rdata
    );
    assign mem_req_ready=allow_memory && model_ready;
    latency_memory_responder responder (
        .clk, .reset, .read_delay, .fetch_delay, .is_fetch(1'b0),
        .req_valid(mem_req_valid && allow_memory), .req_ready(model_ready),
        .req_write(mem_req_write), .req_addr(mem_req_addr), .req_wdata(mem_req_wdata),
        .rsp_valid(mem_rsp_valid), .rsp_rdata(mem_rsp_rdata),
        .memory_read_enable, .memory_write_enable, .memory_address,
        .memory_write_data, .memory_read_data
    );
    memory #(.WORDS(1024)) ram (
        .clk, .read_enable(memory_read_enable), .write_enable(memory_write_enable),
        .address(memory_address), .write_data(memory_write_data), .read_data(memory_read_data)
    );
    assign mmio_req_ready=!reset;
    assign mmio_rsp_rdata=32'h12345678;
    assign unused_mmio=^{mmio_req_addr,mmio_req_wdata};

    always @(posedge clk or posedge reset) begin
        edge_index <= edge_index+1;
        if (reset) begin
            mmio_rsp_valid <= 0;
            stalled<=0;
        end else begin
            mmio_rsp_valid <= mmio_req_valid && mmio_req_ready && !mmio_req_write;
            if (memory_read_enable) reads<=reads+1;
            if (memory_write_enable) writes<=writes+1;
            if (mmio_req_valid && !mmio_req_write) mmio_reads<=mmio_reads+1;
            if (stalled && (!cpu_req_valid || cpu_req_addr != stalled_addr ||
                cpu_req_write != stalled_write || cpu_req_wdata != stalled_data ||
                cpu_req_is_fetch != stalled_fetch))
                $fatal(1,"CPU request/classification changed under stall");
            stalled<=cpu_req_valid && !cpu_req_ready;
            stalled_addr<=cpu_req_addr; stalled_data<=cpu_req_wdata;
            stalled_write<=cpu_req_write; stalled_fetch<=cpu_req_is_fetch;
            if (busy && (cpu_req_ready || ram_req_valid || mmio_req_valid))
                $fatal(1,"busy gate bypassed");
        end
    end

    task automatic read_word(input logic [31:0] address, input bit fetch,
                             input int latency, input int backing_reads,
                             input logic [31:0] expected);
        int accepted, before_reads, attempts;
        before_reads=reads;
        @(negedge clk);
        cpu_req_valid=1; cpu_req_write=0; cpu_req_is_fetch=fetch; cpu_req_addr=address;
        attempts=0;
        do begin
            @(posedge clk);
            attempts++;
            if (attempts>100) $fatal(1,"acceptance timeout");
        end while (!cpu_req_ready);
        accepted=edge_index;
        @(negedge clk); cpu_req_valid=0;
        attempts=0;
        do begin
            @(posedge clk);
            attempts++;
            if (attempts>200) $fatal(1,"response timeout");
        end while (!cpu_rsp_valid);
        if (cpu_rsp_rdata !== expected || (latency>=0 && edge_index-accepted != latency))
            $fatal(1,"read %h data %h expected %h latency %0d expected %0d",
                   address,cpu_rsp_rdata,expected,edge_index-accepted,latency);
        @(negedge clk);
        if (reads-before_reads != backing_reads) $fatal(1,"backing read count");
        repeat (2) begin
            @(posedge clk);
            if (cpu_rsp_valid) $fatal(1,"duplicate response");
        end
    endtask

    task automatic pulse_reset;
        @(negedge clk);
        reset=1; cpu_req_valid=0; busy=0; allow_memory=1;
        repeat (2) @(posedge clk);
        @(negedge clk); reset=0;
        repeat (8) begin
            @(posedge clk);
            if (cpu_rsp_valid || memory_read_enable) $fatal(1,"stale reset activity");
        end
    endtask

    task automatic launch_fetch(input logic [31:0] address);
        @(negedge clk);
        cpu_req_valid=1; cpu_req_is_fetch=1; cpu_req_write=0; cpu_req_addr=address;
        @(posedge clk);
        if (!cpu_req_ready) $fatal(1,"launch not ready");
        @(negedge clk); cpu_req_valid=0;
    endtask

    initial begin
        #1;
        for (int i=0;i<1024;i++) ram.mem[i]=32'habc00000+32'(4*i);
        pulse_reset();
        // Cold miss and warm hit for each requested-word position.
        for (int offset=0;offset<4;offset++) begin
            read_word(32'(offset*16+offset*4),1,10,4,32'habc00000+32'(offset*16+offset*4));
            for (int word_index=0;word_index<4;word_index++)
                read_word(32'(offset*16+word_index*4),1,2,0,
                          32'habc00000+32'(offset*16+word_index*4));
        end
        // Same index, different tag; then refill the evicted line.
        read_word('h200,1,10,4,32'habc00200);
        read_word(0,1,10,4,32'habc00000);
        // Data at a cached code address still reads RAM.
        ram.mem[0]=32'hdeadbeef;
        read_word(0,0,1,1,32'hdeadbeef);
        read_word(0,1,2,0,32'habc00000);
        // Data writes pass directly through; immutable code is a harness restriction.
        @(negedge clk);
        cpu_req_valid=1; cpu_req_write=1; cpu_req_is_fetch=0;
        cpu_req_addr='h940; cpu_req_wdata=32'h5555aaaa;
        @(posedge clk);
        if (!cpu_req_ready) $fatal(1,"write not ready");
        @(negedge clk); cpu_req_valid=0; cpu_req_write=0;
        if (ram.mem['h250] !== 32'h5555aaaa || writes != 1) $fatal(1,"write bypass");
        read_word('h4000001c,0,1,0,32'h12345678);
        if (mmio_reads!=1) $fatal(1,"MMIO count");
        // Busy blocks even a resident hit; request/classification stays stable.
        @(negedge clk); busy=1;
        fork
            read_word(0,1,2,0,32'habc00000);
            begin repeat (5) @(negedge clk); busy=0; end
        join
        // Variable memory latency and downstream acceptance backpressure.
        read_delay=5;
        @(negedge clk); allow_memory=0;
        fork
            read_word('h104,1,-1,4,32'habc00104);
            begin repeat (6) @(negedge clk); allow_memory=1; end
        join
        read_word('h144,1,26,4,32'habc00144);
        // Reset before lookup, during partial refill, and before response consumption.
        launch_fetch('h300);
        reset=1;
        pulse_reset();
        read_word('h300,1,26,4,32'habc00300);
        launch_fetch('h340);
        wait(memory_read_enable);
        @(posedge clk);
        pulse_reset();
        read_word('h340,1,26,4,32'habc00340);
        launch_fetch('h380);
        wait(cpu_rsp_valid);
        pulse_reset();
        read_word('h380,1,26,4,32'habc00380);
        $display("PASS: instruction_cache_tb timing/offsets/conflicts/stalls/busy/MMIO/reset");
        $finish;
    end
    initial begin
        #100000;
        $fatal(1,"unit timeout");
    end
endmodule
