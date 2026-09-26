module pim_mmio_regs #(
    parameter logic [31:0] MMIO_BASE = 32'h4000_0000,
    parameter int unsigned BUFFER_WORDS = 16,
    parameter int unsigned MAX_OUTPUTS = 32,
    parameter int unsigned MAC_LANES = 1
) (
    input  logic                     clk,
    input  logic                     reset,
    input  logic                     req_valid,
    output logic                     req_ready,
    input  logic                     req_write,
    input  logic [31:0]              req_addr,
    input  logic [31:0]              req_wdata,
    output logic                     rsp_valid,
    output logic [31:0]              rsp_rdata,
    input  logic                     ctrl_busy,
    input  logic                     ctrl_done_set,
    input  logic                     ctrl_error_set,
    input  pim_pkg::pim_error_t      ctrl_error_code,
    input  logic [31:0]              buffer_valid_count,
    input  logic                     buffer_vector_full,
    input  logic [31:0]              resident_vector_base,
    input  logic [31:0]              resident_vector_length,
    output logic                     cmd_start,
    output pim_pkg::pim_descriptor_t cmd_descriptor,
    output logic [31:0]              cmd_word,
    output logic                     buffer_invalidate,
    output logic                     status_error
);
    import pim_pkg::*;

    pim_descriptor_t descriptor_q;
    logic done_q;
    logic error_q;
    pim_error_t error_code_q;
    logic [11:0] req_offset;
    logic req_fire;
    logic command_write;
    logic status_clear_write;
    logic config_write;
    logic buffer_control_write;
    logic [31:0] read_data;
    logic [31:0] status_data;
    logic [31:0] capabilities_data;
    logic access_allowed;
    logic local_error_set;
    pim_error_t local_error_code;

    assign req_offset = req_addr[11:0];
    assign req_ready = !reset && !rsp_valid;
    assign req_fire = req_valid && req_ready;
    assign command_write = req_fire && access_allowed && req_write
        && (req_offset == PIM_REG_COMMAND);
    assign status_clear_write = req_fire && access_allowed && req_write
        && (req_offset == PIM_REG_STATUS_CLEAR);
    assign buffer_control_write = req_fire && access_allowed && req_write
        && (req_offset == PIM_REG_BUFFER_CONTROL);
    assign config_write = req_fire && access_allowed && req_write
        && ((req_offset == PIM_REG_VECTOR_BASE)
            || (req_offset == PIM_REG_VECTOR_LENGTH)
            || (req_offset == PIM_REG_MATRIX_BASE)
            || (req_offset == PIM_REG_MATRIX_COLUMN_STRIDE)
            || (req_offset == PIM_REG_OUTPUT_BASE)
            || (req_offset == PIM_REG_OUTPUT_COUNT));

    // The command and descriptor are sampled by the controller on this same
    // accepted-write edge. Busy becomes visible only after that edge.
    assign cmd_start = command_write && req_wdata[PIM_CMD_START_BIT]
        && !ctrl_busy && !error_q;
    assign cmd_descriptor = descriptor_q;
    assign cmd_word = req_wdata;
    assign buffer_invalidate = buffer_control_write && !ctrl_busy
        && req_wdata[PIM_BUFFER_INVALIDATE_BIT];
    assign status_error = error_q;

    always_comb begin
        status_data = 32'b0;
        status_data[PIM_STATUS_BUSY_BIT] = ctrl_busy;
        status_data[PIM_STATUS_DONE_BIT] = done_q;
        status_data[PIM_STATUS_ERROR_BIT] = error_q;
        status_data[PIM_STATUS_VECTOR_FULL_BIT] = buffer_vector_full;

        capabilities_data = 32'd1;
        capabilities_data[PIM_CAP_REUSE_VECTOR_BIT] = 1'b1;

        read_data = 32'b0;
        unique case (req_offset)
            PIM_REG_VECTOR_BASE:            read_data = descriptor_q.vector_base;
            PIM_REG_VECTOR_LENGTH:          read_data = descriptor_q.vector_length;
            PIM_REG_MATRIX_BASE:            read_data = descriptor_q.matrix_base;
            PIM_REG_MATRIX_COLUMN_STRIDE:   read_data = descriptor_q.matrix_column_stride;
            PIM_REG_OUTPUT_BASE:            read_data = descriptor_q.output_base;
            PIM_REG_OUTPUT_COUNT:           read_data = descriptor_q.output_count;
            PIM_REG_STATUS:                 read_data = status_data;
            PIM_REG_VALID_COUNT:            read_data = buffer_valid_count;
            PIM_REG_ERROR_CODE:             read_data = {24'b0, error_code_q};
            PIM_REG_RESIDENT_VECTOR_BASE:   read_data = resident_vector_base;
            PIM_REG_RESIDENT_VECTOR_LENGTH: read_data = resident_vector_length;
            PIM_REG_CAPABILITIES:           read_data = capabilities_data;
            PIM_REG_BUFFER_WORDS:           read_data = 32'(BUFFER_WORDS);
            PIM_REG_MAX_OUTPUTS:            read_data = 32'(MAX_OUTPUTS);
            PIM_REG_MAC_LANES:              read_data = 32'(MAC_LANES);
            PIM_REG_INTERRUPT_ENABLE,
            PIM_REG_INTERRUPT_STATUS:       read_data = 32'b0;
            default:                        read_data = 32'b0;
        endcase
    end

    always_comb begin
        access_allowed = 1'b0;
        if ((req_addr[31:12] == MMIO_BASE[31:12])
                && (req_addr[1:0] == 2'b00)) begin
            if (req_write) begin
                unique case (req_offset)
                    PIM_REG_VECTOR_BASE,
                    PIM_REG_VECTOR_LENGTH,
                    PIM_REG_MATRIX_BASE,
                    PIM_REG_MATRIX_COLUMN_STRIDE,
                    PIM_REG_OUTPUT_BASE,
                    PIM_REG_OUTPUT_COUNT,
                    PIM_REG_COMMAND,
                    PIM_REG_STATUS_CLEAR,
                    PIM_REG_BUFFER_CONTROL: access_allowed = 1'b1;
                    default:                access_allowed = 1'b0;
                endcase
            end
            else begin
                unique case (req_offset)
                    PIM_REG_VECTOR_BASE,
                    PIM_REG_VECTOR_LENGTH,
                    PIM_REG_MATRIX_BASE,
                    PIM_REG_MATRIX_COLUMN_STRIDE,
                    PIM_REG_OUTPUT_BASE,
                    PIM_REG_OUTPUT_COUNT,
                    PIM_REG_STATUS,
                    PIM_REG_VALID_COUNT,
                    PIM_REG_ERROR_CODE,
                    PIM_REG_RESIDENT_VECTOR_BASE,
                    PIM_REG_RESIDENT_VECTOR_LENGTH,
                    PIM_REG_CAPABILITIES,
                    PIM_REG_BUFFER_WORDS,
                    PIM_REG_MAX_OUTPUTS,
                    PIM_REG_MAC_LANES,
                    PIM_REG_INTERRUPT_ENABLE,
                    PIM_REG_INTERRUPT_STATUS: access_allowed = 1'b1;
                    default:                  access_allowed = 1'b0;
                endcase
            end
        end
    end

    // Local semantic rejection does not undo a legal transport handshake.
    // START=0 cannot reach the sequential validator, so its command-bit
    // checks live here. START=1 carries the raw word to that validator.
    always_comb begin
        local_error_set = 1'b0;
        local_error_code = PIM_ERROR_NONE;
        if (command_write && req_wdata[PIM_CMD_START_BIT] && ctrl_busy) begin
            local_error_set = 1'b1;
            local_error_code = PIM_ERROR_START_WHILE_BUSY;
        end
        else if ((config_write || status_clear_write || buffer_control_write)
                && ctrl_busy) begin
            local_error_set = 1'b1;
            local_error_code = PIM_ERROR_CONFIG_WRITE_WHILE_BUSY;
        end
        else if (command_write && !req_wdata[PIM_CMD_START_BIT]) begin
            if (|req_wdata[31:3]) begin
                local_error_set = 1'b1;
                local_error_code = PIM_ERROR_RESERVED_COMMAND_BIT;
            end
            else if (req_wdata[PIM_CMD_NONBLOCKING_BIT]) begin
                local_error_set = 1'b1;
                local_error_code = PIM_ERROR_UNSUPPORTED_MODE;
            end
        end
    end

    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
            descriptor_q <= '0;
            done_q <= 1'b0;
            error_q <= 1'b0;
            error_code_q <= PIM_ERROR_NONE;
            rsp_valid <= 1'b0;
            rsp_rdata <= 32'b0;
        end
        else begin
            rsp_valid <= 1'b0;
            if (req_fire && access_allowed && !req_write) begin
                rsp_valid <= 1'b1;
                rsp_rdata <= read_data;
            end

            if (ctrl_done_set)
                done_q <= 1'b1;

            if (cmd_start)
                done_q <= 1'b0;

            if (req_fire && access_allowed && req_write && !ctrl_busy) begin
                unique case (req_offset)
                    PIM_REG_VECTOR_BASE:
                        descriptor_q.vector_base <= req_wdata;
                    PIM_REG_VECTOR_LENGTH:
                        descriptor_q.vector_length <= req_wdata;
                    PIM_REG_MATRIX_BASE:
                        descriptor_q.matrix_base <= req_wdata;
                    PIM_REG_MATRIX_COLUMN_STRIDE:
                        descriptor_q.matrix_column_stride <= req_wdata;
                    PIM_REG_OUTPUT_BASE:
                        descriptor_q.output_base <= req_wdata;
                    PIM_REG_OUTPUT_COUNT:
                        descriptor_q.output_count <= req_wdata;
                    default: begin end
                endcase
            end

            if (status_clear_write && !ctrl_busy) begin
                if (req_wdata[PIM_STATUS_DONE_BIT])
                    done_q <= 1'b0;
                if (req_wdata[PIM_STATUS_ERROR_BIT]) begin
                    error_q <= 1'b0;
                    error_code_q <= PIM_ERROR_NONE;
                end
            end
            else if (!error_q) begin
                if (ctrl_error_set) begin
                    error_q <= 1'b1;
                    error_code_q <= ctrl_error_code;
                end
                else if (local_error_set) begin
                    error_q <= 1'b1;
                    error_code_q <= local_error_code;
                end
            end
        end
    end

`ifndef SYNTHESIS
    initial begin
        if (MMIO_BASE[11:0] != 12'b0)
            $fatal(1, "pim_mmio_regs: MMIO_BASE must be page aligned");
        if (BUFFER_WORDS == 0 || (BUFFER_WORDS & (BUFFER_WORDS - 1)) != 0)
            $fatal(1, "pim_mmio_regs: BUFFER_WORDS must be a nonzero power of two");
        if (MAX_OUTPUTS == 0)
            $fatal(1, "pim_mmio_regs: MAX_OUTPUTS must be nonzero");
        if (MAC_LANES != 1)
            $fatal(1, "pim_mmio_regs: MAC_LANES must be one in version 1");
    end

    always @(posedge clk or posedge reset) begin
        if (reset) begin
            // Ignore requests during asynchronous reset.
        end
        else if (req_fire && !access_allowed) begin
            if (req_write)
                $fatal(1, "ILLEGAL: PIM MMIO write at %08x", req_addr);
            else
                $fatal(1, "ILLEGAL: PIM MMIO read at %08x", req_addr);
        end
    end
`endif
endmodule
