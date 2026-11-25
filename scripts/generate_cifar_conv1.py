"""Assemble the CPU and PIM programs for CIFAR-sized Conv1_1."""

import random

import generate_matvec_1x16_16x32 as rv
from conv1_reference import convolve
from generate_conv1 import Assembler, CONSTANTS, DONE, KERNEL, MASK, PHASE, SIGNATURE, hex_text

SIZE, CHANNELS, FILTERS = 32, 3, 64
TERMS = 3 * 3 * CHANNELS
POSITIONS = SIZE * SIZE
OUTPUTS = POSITIONS * FILTERS
TILE = 128
INPUT, PATCH, WEIGHTS, OUTPUT, FILTER_OUTPUT = 0x10000, 0x14000, 0x30000, 0x40000, 0x80000
POLICIES = ("cpu-streaming", "pim-per-dot", "activation-retaining",
            "weight-reload", "weight-retaining")


def flatten(rows):
    return [word for row in rows for word in row]


def workload():
    rng = random.Random(0xC1FA)
    image = [[[rv.to_s32(rng.getrandbits(32)) for _ in range(SIZE)]
              for _ in range(SIZE)] for _ in range(CHANNELS)]
    weights = [[[[rv.to_s32(rng.getrandbits(32)) for _ in range(3)]
                 for _ in range(3)] for _ in range(CHANNELS)] for _ in range(FILTERS)]
    image[0][0][:2] = [-2**31, -2**31]
    weights[0] = [[[0] * 3 for _ in range(3)] for _ in range(CHANNELS)]
    weights[1] = [[[0] * 3 for _ in range(3)] for _ in range(CHANNELS)]
    weights[0][0][1][1] = -1
    weights[1][0][1][1:] = [-1, -1]
    raw, _, _ = convolve(image, weights, [0] * FILTERS)
    assert raw[:2] == [0x80000000, 0]  # Corner product truncation and sum wrap.

    patches = []
    for y in range(SIZE):
        for x in range(SIZE):
            for channel in image:
                for ky in (-1, 0, 1):
                    for kx in (-1, 0, 1):
                        iy, ix = y + ky, x + kx
                        value = channel[iy][ix] if 0 <= iy < SIZE and 0 <= ix < SIZE else 0
                        patches.append(value & MASK)
    return flatten(flatten(image)), flatten(flatten(flatten(weights))), patches, raw


def pack_patches(a):
    # Runtime loops use y/x/channel/kernel row/kernel column in x3..x7.
    a.load(1, INPUT)
    a.load(2, PATCH)
    a.emit(rv.addi(13, 0, -1), rv.addi(14, 0, SIZE), rv.addi(16, 0, 3),
           rv.addi(18, 0, POSITIONS), rv.addi(19, 0, 4), rv.addi(3, 0, 0))
    loops = ((3, 14, "y"), (4, 14, "x"), (5, 16, "channel"),
             (6, 16, "row"), (7, 16, "col"))
    for (_, _, label), (next_register, _, _) in zip(loops, loops[1:]):
        a.label(f"pack_{label}")
        a.emit(rv.addi(next_register, 0, 0))
    a.label("pack_col")
    a.emit(rv.add(8, 3, 6), rv.addi(8, 8, -1), rv.add(9, 4, 7), rv.addi(9, 9, -1))
    for coordinate in (8, 9):
        for bound in (13, 14):
            a.branch(coordinate, bound, "pad", equal=True)
    a.emit(rv.mul(10, 5, 18), rv.mul(11, 8, 14), rv.add(10, 10, 11),
           rv.add(10, 10, 9), rv.mul(10, 10, 19), rv.add(10, 10, 1), rv.lw(12, 10))
    a.jump("store_patch")
    a.label("pad")
    a.emit(rv.addi(12, 0, 0))
    a.label("store_patch")
    a.emit(rv.sw(12, 2), rv.addi(2, 2, 4))
    for register, bound, label in reversed(loops):
        a.emit(rv.addi(register, register, 1))
        a.branch(register, bound, f"pack_{label}")


def cpu_streaming(a):
    a.load(5, PATCH)
    a.load(7, OUTPUT)
    a.load(19, WEIGHTS)
    a.emit(rv.addi(20, 0, POSITIONS))
    a.label("cpu_position")
    a.emit(rv.addi(6, 19, 0), rv.addi(8, 0, FILTERS))
    a.label("cpu_filter")
    a.emit(rv.addi(10, 5, 0), rv.addi(13, 0, TERMS), rv.addi(11, 0, 0))
    a.label("cpu_term")
    a.emit(rv.lw(12, 10), rv.lw(18, 6), rv.mul(14, 12, 18), rv.add(11, 11, 14),
           rv.addi(10, 10, 4), rv.addi(6, 6, 4), rv.addi(13, 13, -1))
    a.branch(13, 0, "cpu_term")
    a.emit(rv.sw(11, 7), rv.addi(7, 7, 4), rv.addi(8, 8, -1))
    a.branch(8, 0, "cpu_filter")
    a.emit(rv.addi(5, 5, 4 * TERMS), rv.addi(20, 20, -1))
    a.branch(20, 0, "cpu_position")


def configure_pim(a, count):
    a.load(1, 0x40000000)
    a.emit(rv.addi(2, 0, TERMS), rv.sw(2, 1, 4),
           rv.addi(2, 0, 4 * TERMS), rv.sw(2, 1, 12),
           rv.addi(2, 0, count), rv.sw(2, 1, 20),
           rv.addi(24, 0, 10))


def launch(a):
    # x5: vector, x6: matrix, x7: output, x25: command word.
    a.emit(rv.sw(5, 1, 0), rv.sw(6, 1, 8), rv.sw(7, 1, 16), rv.sw(25, 1, 24),
           rv.lw(3, 1, 28))
    a.branch(3, 24, "failure")


def activation_pim(a, per_dot):
    configure_pim(a, 1 if per_dot else FILTERS)
    a.load(5, PATCH)
    a.load(7, OUTPUT)
    a.load(19, WEIGHTS)
    a.emit(rv.addi(20, 0, POSITIONS), rv.addi(25, 0, 1))
    a.label("pim_position")
    a.emit(rv.addi(6, 19, 0))
    if per_dot:
        a.emit(rv.addi(21, 0, FILTERS))
        a.label("pim_filter")
    launch(a)
    if per_dot:
        a.emit(rv.addi(6, 6, 4 * TERMS), rv.addi(7, 7, 4), rv.addi(21, 21, -1))
        a.branch(21, 0, "pim_filter")
    else:
        a.emit(rv.addi(7, 7, 4 * FILTERS))
    a.emit(rv.addi(5, 5, 4 * TERMS), rv.addi(20, 20, -1))
    a.branch(20, 0, "pim_position")


def weight_pim(a, reuse):
    configure_pim(a, TILE)
    a.load(5, WEIGHTS)
    a.load(7, FILTER_OUTPUT)
    a.load(19, PATCH)
    a.load(22, TILE * TERMS * 4)
    a.emit(rv.addi(20, 0, FILTERS))
    a.label("pim_filter")
    a.emit(rv.addi(6, 19, 0), rv.addi(21, 0, POSITIONS // TILE), rv.addi(25, 0, 1))
    a.label("pim_tile")
    launch(a)
    # Both programs execute the same instructions. Only this immediate differs.
    a.emit(rv.addi(25, 0, 3 if reuse else 1), rv.add(6, 6, 22),
           rv.addi(7, 7, 4 * TILE), rv.addi(21, 21, -1))
    a.branch(21, 0, "pim_tile")
    a.emit(rv.addi(5, 5, 4 * TERMS), rv.addi(20, 20, -1))
    a.branch(20, 0, "pim_filter")


def gather(a):
    # Read raw[f,p] with a filter-plane stride; store contiguous raw[p,f].
    a.load(5, FILTER_OUTPUT)
    a.load(7, OUTPUT)
    a.load(22, POSITIONS * 4)
    a.emit(rv.addi(20, 0, POSITIONS))
    a.label("gather_position")
    a.emit(rv.addi(6, 5, 0), rv.addi(21, 0, FILTERS))
    a.label("gather_filter")
    a.emit(rv.lw(11, 6), rv.sw(11, 7), rv.add(6, 6, 22),
           rv.addi(7, 7, 4), rv.addi(21, 21, -1))
    a.branch(21, 0, "gather_filter")
    a.emit(rv.addi(5, 5, 4), rv.addi(20, 20, -1))
    a.branch(20, 0, "gather_position")


def program(policy):
    a = Assembler()
    a.phase(1)
    pack_patches(a)
    a.phase(2)
    weights_first = policy.startswith("weight-")
    if weights_first:
        weight_pim(a, reuse=policy == "weight-retaining")
    elif policy == "cpu-streaming":
        cpu_streaming(a)
    else:
        activation_pim(a, per_dot=policy == "pim-per-dot")
    a.phase(3)
    if weights_first:
        gather(a)
    a.emit(rv.lw(31, 0, SIGNATURE), rv.sw(31, 0, DONE))
    a.label("failure")
    a.jump("failure")
    return a, a.finish()


def generate(directory):
    directory.mkdir(parents=True, exist_ok=True)
    image, weights, patches, raw = workload()
    for name, words in (("patches", patches), ("raw", raw)):
        (directory / f"{name}.hex").write_text("".join(f"{word:08x}\n" for word in words))
    for policy in POLICIES:
        assembly, code = program(policy)
        regions = [(0, [rv.jal(0, KERNEL), 0, 0, 0]),
                   (SIGNATURE, [rv.COMPLETION_SIGNATURE, 0, 0]),
                   (CONSTANTS, assembly.constants), (KERNEL, code + [0] * (-len(code) % 4)),
                   (INPUT, image), (PATCH, [0xa5a5a5a5] * len(patches)), (WEIGHTS, weights),
                   (OUTPUT, [0xdeadbeef] * OUTPUTS), (FILTER_OUTPUT, [0xdeadbeef] * OUTPUTS)]
        (directory / f"{policy}.hex").write_text(hex_text(regions))
