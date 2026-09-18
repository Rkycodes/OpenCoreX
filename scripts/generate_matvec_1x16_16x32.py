#!/usr/bin/env python3
"""
Generate deterministic data and independent reference results for the
OpenCoreX 1x16 by 16x32 CPU-only matrix-vector benchmark.

This script deliberately keeps two matrix representations separate:

1. Logical representation:
       matrix[i][j]

   This is used by the independent software reference.

2. OpenCoreX memory representation:
       matrix[0][0], matrix[1][0], ..., matrix[15][0],
       matrix[0][1], matrix[1][1], ..., matrix[15][1],
       ...

   This output-major layout lets the CPU read all 16 matrix elements
   contributing to one output from consecutive memory addresses.

Keeping these representations separate helps expose matrix-layout and
transposition errors.
"""

from pathlib import Path


# ---------------------------------------------------------------------
# Benchmark dimensions
# ---------------------------------------------------------------------

INPUT_LENGTH = 16
OUTPUT_LENGTH = 32

# Mask used to model RV32 wraparound behavior.
MASK32 = 0xFFFF_FFFF


# ---------------------------------------------------------------------
# OpenCoreX byte addresses
# ---------------------------------------------------------------------

VECTOR_BASE_BYTE = 0x100
MATRIX_BASE_BYTE = 0x140
OUTPUT_BASE_BYTE = 0x940

COMPLETION_SIGNATURE = 0x524B_5943

SIGNATURE_BASE_BYTE = OUTPUT_BASE_BYTE + OUTPUT_LENGTH * 4
SIGNATURE_BASE_WORD = SIGNATURE_BASE_BYTE // 4

DONE_BASE_BYTE = SIGNATURE_BASE_BYTE + 4
DONE_BASE_WORD = DONE_BASE_BYTE // 4

assert SIGNATURE_BASE_BYTE == 0x9C0
assert SIGNATURE_BASE_WORD == 0x270
assert DONE_BASE_BYTE == 0x9C4
assert DONE_BASE_WORD == 0x271

# $readmemh address markers use word indices rather than byte addresses.
VECTOR_BASE_WORD = VECTOR_BASE_BYTE // 4
MATRIX_BASE_WORD = MATRIX_BASE_BYTE // 4
OUTPUT_BASE_WORD = OUTPUT_BASE_BYTE // 4

SIGNATURE_BASE_WORD = SIGNATURE_BASE_BYTE // 4

assert SIGNATURE_BASE_BYTE == 0x9C0
assert SIGNATURE_BASE_WORD == 0x270


# ---------------------------------------------------------------------
# Output paths
# ---------------------------------------------------------------------

REPOSITORY_ROOT = Path(__file__).resolve().parents[1]
HEX_DIRECTORY = REPOSITORY_ROOT / "programs" / "hex"

MEMORY_OUTPUT_PATH = (
    HEX_DIRECTORY / "matvec_1x16_16x32.hex"
)

REFERENCE_OUTPUT_PATH = (
    HEX_DIRECTORY / "matvec_1x16_16x32_expected.hex"
)


def to_u32(value: int) -> int:
    """Convert a Python integer into its RV32 unsigned representation."""

    return value & MASK32


def to_s32(value: int) -> int:
    """Interpret a 32-bit unsigned value as a signed integer."""

    value &= MASK32

    if value & 0x8000_0000:
        return value - 0x1_0000_0000

    return value

def check_register(register: int) -> None:
    """Require a valid RV32 register number."""

    if not 0 <= register <= 31:
        raise ValueError(f"Invalid register x{register}")


def encode_r_type(
    *,
    funct7: int,
    rs2: int,
    rs1: int,
    funct3: int,
    rd: int,
    opcode: int = 0b0110011,
) -> int:
    """
    Encode an R-type instruction.

    Bit layout:
        funct7 | rs2 | rs1 | funct3 | rd | opcode
         31:25  24:20 19:15   14:12  11:7   6:0
    """

    for register in (rd, rs1, rs2):
        check_register(register)

    return (
        ((funct7 & 0x7F) << 25)
        | ((rs2 & 0x1F) << 20)
        | ((rs1 & 0x1F) << 15)
        | ((funct3 & 0x7) << 12)
        | ((rd & 0x1F) << 7)
        | (opcode & 0x7F)
    )


def encode_i_type(
    *,
    immediate: int,
    rs1: int,
    funct3: int,
    rd: int,
    opcode: int,
) -> int:
    """Encode an I-type instruction such as ADDI or LW."""

    check_register(rd)
    check_register(rs1)

    if not -2048 <= immediate <= 2047:
        raise ValueError(f"I-type immediate out of range: {immediate}")

    immediate_bits = immediate & 0xFFF

    return (
        (immediate_bits << 20)
        | ((rs1 & 0x1F) << 15)
        | ((funct3 & 0x7) << 12)
        | ((rd & 0x1F) << 7)
        | (opcode & 0x7F)
    )


def encode_s_type(
    *,
    immediate: int,
    rs2: int,
    rs1: int,
    funct3: int,
    opcode: int = 0b0100011,
) -> int:
    """Encode an S-type store instruction."""

    check_register(rs1)
    check_register(rs2)

    if not -2048 <= immediate <= 2047:
        raise ValueError(f"S-type immediate out of range: {immediate}")

    immediate_bits = immediate & 0xFFF

    immediate_11_5 = (immediate_bits >> 5) & 0x7F
    immediate_4_0 = immediate_bits & 0x1F

    return (
        (immediate_11_5 << 25)
        | ((rs2 & 0x1F) << 20)
        | ((rs1 & 0x1F) << 15)
        | ((funct3 & 0x7) << 12)
        | (immediate_4_0 << 7)
        | (opcode & 0x7F)
    )


def encode_b_type(
    *,
    immediate: int,
    rs2: int,
    rs1: int,
    funct3: int,
    opcode: int = 0b1100011,
) -> int:
    """
    Encode a B-type branch instruction.

    The branch offset is relative to the address of the branch
    instruction—not the following instruction.
    """

    check_register(rs1)
    check_register(rs2)

    if immediate % 2 != 0:
        raise ValueError("Branch offset must be even")

    if not -4096 <= immediate <= 4094:
        raise ValueError(f"Branch offset out of range: {immediate}")

    immediate_bits = immediate & 0x1FFF

    immediate_12 = (immediate_bits >> 12) & 0x1
    immediate_11 = (immediate_bits >> 11) & 0x1
    immediate_10_5 = (immediate_bits >> 5) & 0x3F
    immediate_4_1 = (immediate_bits >> 1) & 0xF

    return (
        (immediate_12 << 31)
        | (immediate_10_5 << 25)
        | ((rs2 & 0x1F) << 20)
        | ((rs1 & 0x1F) << 15)
        | ((funct3 & 0x7) << 12)
        | (immediate_4_1 << 8)
        | (immediate_11 << 7)
        | (opcode & 0x7F)
    )


def encode_j_type(
    *,
    immediate: int,
    rd: int,
    opcode: int = 0b1101111,
) -> int:
    """Encode a J-type JAL instruction."""

    check_register(rd)

    if immediate % 2 != 0:
        raise ValueError("JAL offset must be even")

    if not -1_048_576 <= immediate <= 1_048_574:
        raise ValueError(f"JAL offset out of range: {immediate}")

    immediate_bits = immediate & 0x1F_FFFF

    immediate_20 = (immediate_bits >> 20) & 0x1
    immediate_19_12 = (immediate_bits >> 12) & 0xFF
    immediate_11 = (immediate_bits >> 11) & 0x1
    immediate_10_1 = (immediate_bits >> 1) & 0x3FF

    return (
        (immediate_20 << 31)
        | (immediate_10_1 << 21)
        | (immediate_11 << 20)
        | (immediate_19_12 << 12)
        | ((rd & 0x1F) << 7)
        | (opcode & 0x7F)
    )

def generate_vector() -> list[int]:
    """
    Generate a deterministic mixed-sign 16-element input vector.

    The formula is deterministic, so every invocation produces exactly
    the same benchmark data without depending on a random-number library.
    """

    return [
        ((5 * i + 3) % 17) - 8
        for i in range(INPUT_LENGTH)
    ]


def generate_logical_matrix() -> list[list[int]]:
    """
    Generate matrix[i][j] in normal mathematical row/column form.

    The i*j term prevents the columns from being simple shifted copies
    of one another. The modulus keeps values small enough that the first
    benchmark is easy to inspect while still including negative values.
    """

    return [
        [
            ((11 * i + 7 * j + 3 * i * j) % 37) - 18
            for j in range(OUTPUT_LENGTH)
        ]
        for i in range(INPUT_LENGTH)
    ]


def calculate_reference(
    vector: list[int],
    matrix: list[list[int]],
) -> list[int]:
    """
    Calculate all 32 reference outputs from logical matrix[i][j].

    Each multiplication and addition is reduced to 32 bits to match
    OpenCoreX MUL-low and ADD wraparound behavior.
    """

    expected_outputs = []

    for j in range(OUTPUT_LENGTH):
        accumulator = 0

        for i in range(INPUT_LENGTH):
            product = to_u32(vector[i] * matrix[i][j])
            accumulator = to_u32(accumulator + product)

        expected_outputs.append(accumulator)

    return expected_outputs


def serialize_matrix_column_major(
    matrix: list[list[int]],
) -> list[int]:
    """
    Convert logical matrix[i][j] into the OpenCoreX memory order.

    All 16 elements contributing to y[j] are stored consecutively.
    """

    return [
        to_u32(matrix[i][j])
        for j in range(OUTPUT_LENGTH)
        for i in range(INPUT_LENGTH)
    ]


def validate_test_pattern(
    vector: list[int],
    matrix: list[list[int]],
    expected_outputs: list[int],
) -> None:
    """Reject test data that could hide common implementation errors."""

    assert len(vector) == INPUT_LENGTH
    assert len(matrix) == INPUT_LENGTH
    assert all(len(row) == OUTPUT_LENGTH for row in matrix)

    # Require mixed-sign vector values.
    assert any(value < 0 for value in vector)
    assert any(value > 0 for value in vector)

    matrix_values = [
        matrix[i][j]
        for i in range(INPUT_LENGTH)
        for j in range(OUTPUT_LENGTH)
    ]

    # Require mixed-sign matrix values.
    assert any(value < 0 for value in matrix_values)
    assert any(value > 0 for value in matrix_values)

    # Represent each column as a tuple so columns can be compared.
    columns = {
        tuple(matrix[i][j] for i in range(INPUT_LENGTH))
        for j in range(OUTPUT_LENGTH)
    }

    assert len(columns) == OUTPUT_LENGTH, "Matrix columns are not unique"

    assert len(set(expected_outputs)) == OUTPUT_LENGTH, (
        "Reference outputs are not all unique"
    )

def addi(rd: int, rs1: int, immediate: int) -> int:
    return encode_i_type(
        immediate=immediate,
        rs1=rs1,
        funct3=0b000,
        rd=rd,
        opcode=0b0010011,
    )


def lw(rd: int, rs1: int, immediate: int = 0) -> int:
    return encode_i_type(
        immediate=immediate,
        rs1=rs1,
        funct3=0b010,
        rd=rd,
        opcode=0b0000011,
    )


def sw(rs2: int, rs1: int, immediate: int = 0) -> int:
    return encode_s_type(
        immediate=immediate,
        rs2=rs2,
        rs1=rs1,
        funct3=0b010,
    )


def add(rd: int, rs1: int, rs2: int) -> int:
    return encode_r_type(
        funct7=0b0000000,
        rs2=rs2,
        rs1=rs1,
        funct3=0b000,
        rd=rd,
    )


def mul(rd: int, rs1: int, rs2: int) -> int:
    return encode_r_type(
        funct7=0b0000001,
        rs2=rs2,
        rs1=rs1,
        funct3=0b000,
        rd=rd,
    )


def bne(rs1: int, rs2: int, immediate: int) -> int:
    return encode_b_type(
        immediate=immediate,
        rs2=rs2,
        rs1=rs1,
        funct3=0b001,
    )


def jal(rd: int, immediate: int) -> int:
    return encode_j_type(
        immediate=immediate,
        rd=rd,
    )


def write_memory_hex(
    program: list[int],
    vector: list[int],
    serialized_matrix: list[int],
) -> None:
    """
    Write one sparse $readmemh image containing instructions and data.

    Address markers are word indices:
        byte 0x100 / 4 = word 0x040
        byte 0x140 / 4 = word 0x050
        byte 0x940 / 4 = word 0x250
    """

    HEX_DIRECTORY.mkdir(parents=True, exist_ok=True)

    with MEMORY_OUTPUT_PATH.open("w", encoding="utf-8") as output_file:
        # Program begins at byte address 0x000.
        output_file.write("@00000000\n")

        for instruction in program:
            output_file.write(f"{instruction:08x}\n")

        # Input vector begins at byte address 0x100.
        output_file.write(f"@{VECTOR_BASE_WORD:08x}\n")

        for value in vector:
            output_file.write(f"{to_u32(value):08x}\n")

        # Matrix begins at byte address 0x140.
        output_file.write(f"@{MATRIX_BASE_WORD:08x}\n")

        for value in serialized_matrix:
            output_file.write(f"{value:08x}\n")

        # Output vector begins at byte address 0x940.
        output_file.write(f"@{OUTPUT_BASE_WORD:08x}\n")

        for _ in range(OUTPUT_LENGTH):
            output_file.write("00000000\n")

        # Signature source at byte address 0x9C0.
        output_file.write(f"@{SIGNATURE_BASE_WORD:08x}\n")
        output_file.write(f"{COMPLETION_SIGNATURE:08x}\n")

        # Completion destination at byte address 0x9C4.
        # This word must be overwritten by the CPU.
        output_file.write(f"@{DONE_BASE_WORD:08x}\n")
        output_file.write("00000000\n")

def write_expected_hex(expected_outputs: list[int]) -> None:
    """Write the 32 independently calculated expected output words."""

    with REFERENCE_OUTPUT_PATH.open("w", encoding="utf-8") as output_file:
        for value in expected_outputs:
            output_file.write(f"{value:08x}\n")

def current_pc(program: list[int]) -> int:
    """Return the byte address of the next instruction."""

    return len(program) * 4


def build_program() -> list[int]:
    """Encode the CPU-only matrix-vector benchmark."""

    program = []

    # -------------------------------------------------------------
    # Initialization
    # -------------------------------------------------------------

    program.append(addi(5, 0, 0x100))   # x5 = vector base
    program.append(addi(6, 0, 0x140))   # x6 = matrix base
    program.append(addi(7, 6, 0x400))   # x7 = 0x540
    program.append(addi(7, 7, 0x400))   # x7 = 0x940
    program.append(addi(8, 0, 32))      # x8 = outputs remaining

    # Save the byte address represented by outer_loop.
    outer_loop_pc = current_pc(program)

    # -------------------------------------------------------------
    # Outer-loop initialization
    # -------------------------------------------------------------

    program.append(add(9, 5, 0))        # x9 = vector base
    program.append(addi(10, 0, 16))     # x10 = inner count
    program.append(addi(11, 0, 0))      # x11 = accumulator

    # Save the byte address represented by inner_loop.
    inner_loop_pc = current_pc(program)

    # -------------------------------------------------------------
    # Inner dot-product loop
    # -------------------------------------------------------------

    program.append(lw(12, 9))           # x12 = x[i]
    program.append(lw(13, 6))           # x13 = W[i][j]
    program.append(mul(14, 12, 13))     # x14 = x[i] * W[i][j]
    program.append(add(11, 11, 14))     # accumulator += product
    program.append(addi(9, 9, 4))       # advance vector pointer
    program.append(addi(6, 6, 4))       # advance matrix pointer
    program.append(addi(10, 10, -1))    # decrement inner count

    branch_pc = current_pc(program)
    inner_offset = inner_loop_pc - branch_pc

    program.append(bne(10, 0, inner_offset))

    # -------------------------------------------------------------
    # Outer-loop tail
    # -------------------------------------------------------------

    program.append(sw(11, 7))           # store completed y[j]
    program.append(addi(7, 7, 4))       # advance output pointer
    program.append(addi(8, 8, -1))      # decrement output count

    branch_pc = current_pc(program)
    outer_offset = outer_loop_pc - branch_pc

    program.append(bne(8, 0, outer_offset))

    # -------------------------------------------------------------
    # Completion
    # -------------------------------------------------------------

    # Load RKYC from memory[0x9C0].
    program.append(lw(31, 7, 0))

    # Externally signal completion by writing RKYC to memory[0x9C4].
    program.append(sw(31, 7, 4))

    # Safety loop if simulation continues.
    program.append(jal(0, 0))

    assert len(program) == 23
    assert outer_loop_pc == 0x14
    assert inner_loop_pc == 0x20
    assert inner_offset == -28
    assert outer_offset == -56

    return program

def main() -> None:
    """
    Generate the executable memory image and independent reference data.
    """

    # Generate the logical benchmark operands.
    vector = generate_vector()
    matrix = generate_logical_matrix()

    # Calculate expected results independently from the serialized layout.
    expected_outputs = calculate_reference(vector, matrix)

    # Make sure the test pattern is capable of exposing common bugs.
    validate_test_pattern(
        vector,
        matrix,
        expected_outputs,
    )

    # Convert the logical matrix into the column-major memory layout
    # expected by the OpenCoreX benchmark program.
    serialized_matrix = serialize_matrix_column_major(matrix)

    # Encode the 22-instruction CPU benchmark.
    program = build_program()

    # Write instructions, operands, and the empty output region into one
    # memory image that OpenCoreX can load through $readmemh.
    write_memory_hex(
        program,
        vector,
        serialized_matrix,
    )

    # Write the independently calculated expected output vector.
    write_expected_hex(expected_outputs)

    print("Generated matrix-vector benchmark")
    print(f"Program words:    {len(program)}")
    print(f"Vector words:     {len(vector)}")
    print(f"Matrix words:     {len(serialized_matrix)}")
    print(f"Expected outputs: {len(expected_outputs)}")
    print(f"Memory image:     {MEMORY_OUTPUT_PATH}")
    print(f"Reference image:  {REFERENCE_OUTPUT_PATH}")

    print("\nEncoded program:")

    for index, instruction in enumerate(program):
        byte_address = index * 4

        print(
            f"0x{byte_address:04X}: "
            f"{instruction:08X}"
        )

    print("\nExpected outputs:")

    for index, value in enumerate(expected_outputs):
        print(
            f"y[{index:02d}] = "
            f"0x{value:08X} "
            f"({to_s32(value)})"
        )


if __name__ == "__main__":
    main()