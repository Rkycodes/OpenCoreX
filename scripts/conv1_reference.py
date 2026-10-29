"""Direct tensor reference; deliberately independent of packing and RV32 execution."""


def convolve(image, filters, biases):
    """Return raw, biased and ReLU words in [row][column][filter] order.

    Use unbounded Python sums and reduce once, rather than reproducing the
    mapped engine's per-MAC arithmetic or its flattened memory indexing.
    """
    channels, height, width = len(image), len(image[0]), len(image[0][0])
    count = len(filters)
    raw = [[[0] * count for _ in range(width)] for _ in range(height)]
    biased = [[[0] * count for _ in range(width)] for _ in range(height)]
    final = [[[0] * count for _ in range(width)] for _ in range(height)]
    for f, kernel in enumerate(filters):
        for y in range(height):
            for x in range(width):
                total = 0
                for c in range(channels):
                    for r in range(3):
                        for s in range(3):
                            iy, ix = y + r - 1, x + s - 1
                            if 0 <= iy < height and 0 <= ix < width:
                                total += image[c][iy][ix] * kernel[c][r][s]
                word = total % (2**32)
                after_bias = (total + biases[f]) % (2**32)
                raw[y][x][f] = word
                biased[y][x][f] = after_bias
                final[y][x][f] = after_bias if after_bias < 2**31 else 0
    flatten = lambda tensor: [value for row in tensor for pixel in row for value in pixel]
    return tuple(map(flatten, (raw, biased, final)))
