#!/usr/bin/env python3
"""Convert FPGA FASM to a board deployment image when a backend is available."""
import argparse
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))


def parse_args():
    parser = argparse.ArgumentParser()
    parser.add_argument("--arch", required=True, help="FPGA architecture, e.g. xilinx")
    parser.add_argument("--family", required=True, help="Architecture family, e.g. xc7")
    parser.add_argument("--board", help="Board output format, e.g. sonata")
    parser.add_argument("--part", required=True, help="Full FPGA part name")
    parser.add_argument("--db", type=Path, required=True, help="Project X-Ray database root")
    parser.add_argument("--fasm", type=Path, required=True, help="Input FASM")
    parser.add_argument("--output", type=Path, required=True, help="Converted output image")
    parser.add_argument("--allow-missing-features", action="store_true",
                        help="Allow Project X-Ray to skip FASM features absent from the selected database")
    return parser.parse_args()


def main():
    args = parse_args()
    if (args.arch, args.family) != ("xilinx", "xc7"):
        print("No conversion backend for %s/%s; no output generated." % (args.arch, args.family))
        return 0

    from backends.xilinx_xc7 import fasm_to_bit

    bitstream = fasm_to_bit(args.part, args.db, args.fasm, args.allow_missing_features)
    if args.board is None:
        args.output.write_bytes(bitstream)
    elif args.board == "sonata":
        from boards.sonata import write_uf2

        write_uf2(bitstream, args.output)
    else:
        raise SystemExit("Unsupported XC7 board format: %s" % args.board)
    print("Wrote %s" % args.output)
    return 0


if __name__ == "__main__":
    sys.exit(main())