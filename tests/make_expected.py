#!/usr/bin/env python3
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
FIXTURES = os.path.join(HERE, "fixtures")
EXPECTED = os.path.join(HERE, "expected")
START = b"\x1b[38;5;174m"
EOL = b"\r\r\n"

BLOCKS = {
    "banner-2.1.304.bin": ("banner-2.1.304.bin", ["first"]),
    "trust-2.1.304.bin": ("trust-2.1.304.bin", []),
    "cfgdir-2.1.304.bin": ("cfgdir-2.1.304.bin", []),
    "settings-dialog-2.1.304.bin": ("settings-dialog-2.1.304.bin", [1772]),
    "resize-2.1.304.bin": ("resize-2.1.304.bin", ["first", 1936]),
    "resize-2.1.304.keystroke-only.bin": ("resize-2.1.304.bin", ["first"]),
}


def cut_block(data: bytes, start: int) -> bytes:
    assert data[start:start + len(START)] == START, f"no START at {start}"
    assert start == 0 or data[start - 1:start] != b"\x1b", "START cut in the middle of a sequence"
    pos = start
    for line in range(3):
        assert data[pos:pos + len(START)] == START, f"line {line + 1} does not begin with START"
        end = data.index(EOL, pos) + len(EOL)
        pos = end
    block = data[start:pos]
    assert block.startswith(START) and block.endswith(EOL)
    assert b"\xe2\x96\x90" in block.split(EOL)[0], "line 1 lacks U+2590"
    return data[:start] + data[pos:]


def main() -> int:
    os.makedirs(EXPECTED, exist_ok=True)
    for name, (fixture, starts) in BLOCKS.items():
        data = open(os.path.join(FIXTURES, fixture), "rb").read()
        out = data
        for where in reversed(starts):
            start = out.index(START) if where == "first" else where
            before = len(out)
            out = cut_block(out, start)
            print(f"{name}: removed {before - len(out)} bytes at {start}")
        with open(os.path.join(EXPECTED, name), "wb") as fh:
            fh.write(out)
    return 0


if __name__ == "__main__":
    sys.exit(main())
