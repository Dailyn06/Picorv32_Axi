#!/usr/bin/env python3
"""Convert a little-endian firmware binary to 32-bit $readmemh words."""

import argparse
from pathlib import Path


def bin2hex(data, start_address, depth):
    if depth <= 0:
        raise ValueError("ROM depth must be positive")
    if start_address < 0 or start_address % 4:
        raise ValueError("start address must be a nonnegative multiple of four bytes")
    if not data:
        raise ValueError("firmware binary is empty")

    start_word = start_address // 4
    word_count = (len(data) + 3) // 4
    if start_word + word_count > depth:
        raise ValueError(f"firmware exceeds the {depth * 4}-byte ROM")

    lines = [f"@{start_word:08x}"] if start_word else []
    for offset in range(0, len(data), 4):
        word = int.from_bytes(data[offset:offset + 4], byteorder="little")
        lines.append(f"{word:08x}")
    return "\n".join(lines) + "\n"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("input", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--start-address", type=lambda value: int(value, 0), default=0,
                        help="byte offset from the ROM base, default 0")
    parser.add_argument("--depth", type=int, default=2048, help="ROM depth in 32-bit words")
    args = parser.parse_args()

    try:
        image = bin2hex(args.input.read_bytes(), args.start_address, args.depth)
        args.output.write_text(image, encoding="ascii")
    except (OSError, ValueError) as error:
        parser.error(str(error))


if __name__ == "__main__":
    main()
