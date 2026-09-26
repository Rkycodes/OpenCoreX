module pim_accelerator #(
    parameter logic [31:0] MMIO_BASE = 32'h4000_0000,
    parameter logic [31:0] RAM_BASE = 32'h0000_0000,
    parameter int unsigned RAM_WORDS = 1024,
    parameter int unsigned BUFFER_WORDS = 16,
    parameter int unsigned MAX_OUTPUTS = 32,
    parameter int unsigned MAC_LANES = 1
) (
    input logic clk, reset,
    input logic mmio_req_valid,
    output logic mmio_req_ready,
    input logic mmio_req_write,
    input logic [31:0] mmio_req_addr, mmio_req_wdata,
    output logic mmio_rsp_valid,
    output logic [31:0] mmio_rsp_rdata,
    output logic pim_busy,
    output logic mem_req_valid,
    input logic mem_req_ready,
    output logic mem_req_write,
    output logic [31:0] mem_req_addr, mem_req_wdata,
    input logic mem_rsp_valid,
    input logic [31:0] mem_rsp_rdata
);
    localparam int unsigned INDEX_W = (BUFFER_WORDS <= 1) ? 1 : $clog2(BUFFER_WORDS);
    localparam int unsigned COUNT_W = $clog2(BUFFER_WORDS + 1);

    logic cmd_start;
    pim_pkg::pim_descriptor_t cmd_descriptor, validator_descriptor;
    logic [31:0] cmd_word, validator_command_word;
    logic ctrl_done_set, ctrl_error_set;
    pim_pkg::pim_error_t ctrl_error_code, validator_error_code;
    logic validator_start, validator_busy, validator_result_valid, validator_result_ok;
    logic buffer_invalidate, buffer_begin_vector, buffer_query_valid;
    logic buffer_read_enable, buffer_write_enable, buffer_vector_full;
    logic [31:0] buffer_new_vector_base, buffer_new_vector_length;
    logic [31:0] buffer_read_data, buffer_write_data;
    logic [31:0] resident_vector_base, resident_vector_length;
    logic [INDEX_W-1:0] buffer_query_index, buffer_read_index, buffer_write_index;
    logic [COUNT_W-1:0] buffer_valid_count;
    logic [31:0] buffer_valid_count_mmio;
    logic mac_start, mac_busy, mac_done;
    logic [31:0] mac_operand_a, mac_operand_b, mac_accumulator_in, mac_result;

    assign buffer_valid_count_mmio = 32'(buffer_valid_count);

    /* verilator lint_off PINCONNECTEMPTY */
    pim_mmio_regs #(
        .MMIO_BASE(MMIO_BASE), .BUFFER_WORDS(BUFFER_WORDS),
        .MAX_OUTPUTS(MAX_OUTPUTS), .MAC_LANES(MAC_LANES)
    ) mmio (
        .clk, .reset, .req_valid(mmio_req_valid), .req_ready(mmio_req_ready),
        .req_write(mmio_req_write), .req_addr(mmio_req_addr),
        .req_wdata(mmio_req_wdata), .rsp_valid(mmio_rsp_valid),
        .rsp_rdata(mmio_rsp_rdata), .ctrl_busy(pim_busy), .ctrl_done_set,
        .ctrl_error_set, .ctrl_error_code, .buffer_valid_count(buffer_valid_count_mmio),
        .buffer_vector_full, .resident_vector_base, .resident_vector_length,
        .cmd_start, .cmd_descriptor, .cmd_word, .buffer_invalidate,
        .status_error()
    );

    /* verilator lint_on PINCONNECTEMPTY */
    pim_command_validator #(
        .RAM_BASE(RAM_BASE), .RAM_WORDS(RAM_WORDS),
        .BUFFER_WORDS(BUFFER_WORDS), .MAX_OUTPUTS(MAX_OUTPUTS)
    ) validator (
        .clk, .reset, .start(validator_start), .descriptor(validator_descriptor),
        .command_word(validator_command_word), .buffer_vector_full,
        .resident_vector_base, .resident_vector_length, .busy(validator_busy),
        .result_valid(validator_result_valid), .result_ok(validator_result_ok),
        .result_error_code(validator_error_code)
    );

    pim_controller #(.BUFFER_WORDS(BUFFER_WORDS), .INDEX_W(INDEX_W)) controller (
        .clk, .reset, .cmd_start, .cmd_descriptor, .cmd_word, .busy(pim_busy),
        .done_set(ctrl_done_set), .error_set(ctrl_error_set), .error_code(ctrl_error_code),
        .validator_start, .validator_descriptor, .validator_command_word,
        .validator_busy, .validator_result_valid, .validator_result_ok,
        .validator_error_code, .buffer_begin_vector, .buffer_new_vector_base,
        .buffer_new_vector_length, .buffer_query_index, .buffer_query_valid,
        .buffer_read_enable, .buffer_read_index, .buffer_read_data,
        .buffer_write_enable, .buffer_write_index, .buffer_write_data,
        .mac_start, .mac_operand_a, .mac_operand_b, .mac_accumulator_in,
        .mac_busy, .mac_done, .mac_result, .mem_req_valid, .mem_req_ready,
        .mem_req_write, .mem_req_addr, .mem_req_wdata, .mem_rsp_valid,
        .mem_rsp_rdata
    );

    pim_vector_buffer #(
        .BUFFER_WORDS(BUFFER_WORDS), .INDEX_W(INDEX_W), .COUNT_W(COUNT_W)
    ) vector_buffer (
        .clk, .reset, .begin_vector(buffer_begin_vector),
        .new_vector_base(buffer_new_vector_base),
        .new_vector_length(buffer_new_vector_length), .invalidate(buffer_invalidate),
        .query_index(buffer_query_index), .query_valid(buffer_query_valid),
        .read_enable(buffer_read_enable), .read_index(buffer_read_index),
        .read_data(buffer_read_data), .write_enable(buffer_write_enable),
        .write_index(buffer_write_index), .write_data(buffer_write_data),
        .valid_count(buffer_valid_count), .vector_full(buffer_vector_full),
        .resident_vector_base, .resident_vector_length
    );

    pim_mac mac (
        .clk, .reset, .start(mac_start), .operand_a(mac_operand_a),
        .operand_b(mac_operand_b), .accumulator_in(mac_accumulator_in),
        .busy(mac_busy), .done(mac_done), .result(mac_result)
    );
endmodule
