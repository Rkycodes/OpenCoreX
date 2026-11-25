#!/usr/bin/env python3
"""Emit an INT32 parameter and workspace ledger for the CIFAR and original VGG-16 shapes."""
import csv
import sys

from run_cifar_chunked import LAYERS

WORD = 4
MIB = 1024 * 1024
BLOCKS = ((64, 64), (128, 128), (256, 256, 256),
          (512, 512, 512), (512, 512, 512))


def convolution_rows(side):
    inputs = 3
    for block, channels in enumerate(BLOCKS, 1):
        for index, outputs in enumerate(channels, 1):
            yield f"Conv{block}_{index}", side, side, inputs, outputs, 9
            inputs = outputs
        side //= 2


def fully_connected_rows(widths):
    for index, (inputs, outputs) in enumerate(zip(widths, widths[1:]), 1):
        yield f"FC{index}", 1, 1, inputs, outputs, 1


def model_rows():
    models = (
        ("HERO CIFAR configuration D", 32, (512, 10)),
        ("Original VGG-16 configuration D", 224, (7 * 7 * 512, 4096, 4096, 1000)),
    )
    for model, side, widths in models:
        layers = [*convolution_rows(side), *fully_connected_rows(widths)]
        for layer, height, width, inputs, outputs, kernel_words in layers:
            weights = WORD * inputs * outputs * kernel_words
            bias = WORD * outputs
            input_bytes = WORD * height * width * inputs
            output_bytes = WORD * height * width * outputs
            resident = weights + bias + input_bytes + output_bytes
            streamed = input_bytes + output_bytes + WORD * (inputs * kernel_words + 1)
            yield dict(model=model, layer=layer, input_hwc=f"{height}x{width}x{inputs}",
                       output_hwc=f"{height}x{width}x{outputs}", weight_bytes=weights,
                       bias_bytes=bias, input_bytes=input_bytes, output_bytes=output_bytes,
                       resident_weight_working_set_bytes=resident,
                       one_output_channel_weight_working_set_bytes=streamed,
                       resident_fits_16_mib=resident <= 16 * MIB)


def workspace_rows():
    for work in LAYERS.values():
        regions = work.regions()
        end = max(base + WORD * words for base, words in regions.values())
        yield dict(workload=work.name, prefix_bytes=min(base for base, _ in regions.values()),
                   **{f"{name}_bytes": WORD * words for name, (_, words) in regions.items()},
                   total_address_space_bytes=end, fits_1_mib=end <= MIB,
                   fits_16_mib=end <= 16 * MIB)


def main():
    if sys.argv[1:] == ["--benchmark"]:
        rows = list(workspace_rows())
    elif not sys.argv[1:]:
        rows = list(model_rows())
    else:
        sys.exit("usage: python3 scripts/cifar_storage_ledger.py [--benchmark]")
    writer = csv.DictWriter(sys.stdout, fieldnames=list(rows[0]), lineterminator="\n")
    writer.writeheader()
    writer.writerows(rows)


if __name__ == "__main__":
    main()
