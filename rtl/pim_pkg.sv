package pim_pkg;
    typedef struct packed {
        logic [31:0] vector_base;
        logic [31:0] vector_length;
        logic [31:0] matrix_base;
        logic [31:0] matrix_column_stride;
        logic [31:0] output_base;
        logic [31:0] output_count;
    } pim_descriptor_t;

    typedef enum logic [7:0] {
        PIM_ERROR_NONE                       = 8'd0,
        PIM_ERROR_START_WHILE_BUSY           = 8'd1,
        PIM_ERROR_PREVIOUS_ERROR_NOT_CLEARED = 8'd2,
        PIM_ERROR_RESERVED_COMMAND_BIT       = 8'd3,
        PIM_ERROR_UNSUPPORTED_MODE           = 8'd4,
        PIM_ERROR_INVALID_VECTOR_LENGTH      = 8'd5,
        PIM_ERROR_INVALID_OUTPUT_COUNT       = 8'd6,
        PIM_ERROR_MISALIGNED_ADDRESS         = 8'd7,
        PIM_ERROR_INVALID_COLUMN_STRIDE      = 8'd8,
        PIM_ERROR_ADDRESS_OVERFLOW           = 8'd9,
        PIM_ERROR_ADDRESS_OUTSIDE_RAM        = 8'd10,
        PIM_ERROR_INPUT_OUTPUT_OVERLAP       = 8'd11,
        PIM_ERROR_VECTOR_REUSE_MISMATCH      = 8'd12,
        PIM_ERROR_CONFIG_WRITE_WHILE_BUSY    = 8'd13,
        PIM_ERROR_MEMORY_FAULT               = 8'd14,
        PIM_ERROR_MEMORY_TIMEOUT             = 8'd15,
        PIM_ERROR_INTERNAL_PROTOCOL          = 8'd16
    } pim_error_t;

    // Some architectural fields are reserved for later modules or features.
    /* verilator lint_off UNUSEDPARAM */
    localparam logic [11:0] PIM_REG_VECTOR_BASE            = 12'h000;
    localparam logic [11:0] PIM_REG_VECTOR_LENGTH          = 12'h004;
    localparam logic [11:0] PIM_REG_MATRIX_BASE            = 12'h008;
    localparam logic [11:0] PIM_REG_MATRIX_COLUMN_STRIDE   = 12'h00c;
    localparam logic [11:0] PIM_REG_OUTPUT_BASE            = 12'h010;
    localparam logic [11:0] PIM_REG_OUTPUT_COUNT           = 12'h014;
    localparam logic [11:0] PIM_REG_COMMAND                = 12'h018;
    localparam logic [11:0] PIM_REG_STATUS                 = 12'h01c;
    localparam logic [11:0] PIM_REG_VALID_COUNT            = 12'h020;
    localparam logic [11:0] PIM_REG_ERROR_CODE             = 12'h024;
    localparam logic [11:0] PIM_REG_STATUS_CLEAR           = 12'h028;
    localparam logic [11:0] PIM_REG_RESIDENT_VECTOR_BASE   = 12'h02c;
    localparam logic [11:0] PIM_REG_RESIDENT_VECTOR_LENGTH = 12'h030;
    localparam logic [11:0] PIM_REG_CAPABILITIES           = 12'h034;
    localparam logic [11:0] PIM_REG_BUFFER_WORDS           = 12'h038;
    localparam logic [11:0] PIM_REG_MAX_OUTPUTS            = 12'h03c;
    localparam logic [11:0] PIM_REG_MAC_LANES              = 12'h040;
    localparam logic [11:0] PIM_REG_INTERRUPT_ENABLE       = 12'h044;
    localparam logic [11:0] PIM_REG_INTERRUPT_STATUS       = 12'h048;
    localparam logic [11:0] PIM_REG_BUFFER_CONTROL         = 12'h04c;

    localparam int unsigned PIM_CMD_START_BIT           = 0;
    localparam int unsigned PIM_CMD_REUSE_VECTOR_BIT    = 1;
    localparam int unsigned PIM_CMD_NONBLOCKING_BIT     = 2;
    localparam int unsigned PIM_STATUS_BUSY_BIT         = 0;
    localparam int unsigned PIM_STATUS_DONE_BIT         = 1;
    localparam int unsigned PIM_STATUS_ERROR_BIT        = 2;
    localparam int unsigned PIM_STATUS_VECTOR_FULL_BIT  = 3;
    localparam int unsigned PIM_STATUS_INTERRUPT_BIT    = 4;
    localparam int unsigned PIM_BUFFER_INVALIDATE_BIT   = 0;
    localparam int unsigned PIM_CAP_REUSE_VECTOR_BIT     = 8;
    localparam int unsigned PIM_CAP_NONBLOCKING_BIT      = 9;
    localparam int unsigned PIM_CAP_INTERRUPTS_BIT       = 10;
    localparam int unsigned PIM_CAP_MULTI_READ_BIT       = 11;
    /* verilator lint_on UNUSEDPARAM */
endpackage
