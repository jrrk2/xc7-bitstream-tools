#!/usr/bin/env python3
"""Reconstruct an XC7 bitstream as Verilog and run a Verilator testbench."""
import argparse
import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def family_for_part(part):
    for prefix, family in (("xc7a", "artix7"), ("xc7k", "kintex7"),
                           ("xc7s", "spartan7"), ("xc7v", "virtex7"),
                           ("xc7z", "zynq7")):
        if part.startswith(prefix):
            return family
    raise ValueError("Unsupported XC7 part: %s" % part)


def device_for_part(part):
    match = re.match(r"^(xc7(?:[azks]\d+t?|vx\d+t?))", part)
    if not match:
        raise ValueError("Cannot derive XC7 device from part: %s" % part)
    return match.group(1)


def prepare_database_view(database_root, family, device, temporary_dir):
    family_root = database_root / family
    device_root = family_root / device
    view = temporary_dir / "database"
    view.mkdir()
    for name in ("tilegrid.json", "tileconn.json"):
        source = device_root / name
        if not source.exists():
            raise FileNotFoundError(source)
        (view / name).symlink_to(source)
    for pattern in ("tile_type_*.json", "ppips_*.db"):
        for source in family_root.glob(pattern):
            (view / source.name).symlink_to(source)
    return view


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--part", required=True)
    parser.add_argument("--db", type=Path, required=True)
    parser.add_argument("--bit", type=Path, required=True)
    parser.add_argument("--testbench", type=Path, required=True)
    parser.add_argument("--output-dir", type=Path, required=True)
    args = parser.parse_args()

    family = family_for_part(args.part)
    device = device_for_part(args.part)
    prjxray = ROOT / "prjxray"
    bit2verilog = ROOT / "bit2verilog"
    bit2fasm = prjxray / "utils" / "bit2fasm.py"
    bitread = prjxray / "build" / "tools" / "bitread"
    generator = bit2verilog / "param2verilog.py"
    for path in (args.bit, args.testbench, bit2fasm, bitread, generator):
        if not path.exists():
            raise FileNotFoundError(path)

    args.output_dir.mkdir(parents=True, exist_ok=True)
    fasm = args.output_dir / (args.bit.stem + ".fasm")
    model = args.output_dir / (args.bit.stem + "_baked.v")
    layout = args.output_dir / (args.bit.stem + "_layout.json")
    environment = os.environ.copy()
    environment["PATH"] = str(bitread.parent) + os.pathsep + environment["PATH"]
    environment["PYTHONPATH"] = str(prjxray) + os.pathsep + environment.get("PYTHONPATH", "")

    with fasm.open("w") as destination:
        subprocess.run(
            [sys.executable, str(bit2fasm), "--db-root", str(args.db / family), "--part", args.part, str(args.bit)],
            check=True,
            env=environment,
            stdout=destination,
        )
    with tempfile.TemporaryDirectory() as temporary_path:
        database_view = prepare_database_view(args.db, family, device, Path(temporary_path))
        subprocess.run(
            [sys.executable, str(generator), "bake", str(database_view), str(model), str(layout),
             "design=" + str(fasm)],
            check=True,
        )
    shutil.copy2(bit2verilog / "xslice_cfg.v", args.output_dir)
    shutil.copy2(bit2verilog / "xbels.v", args.output_dir)
    shutil.copy2(bit2verilog / "xramb18.v", args.output_dir)
    shutil.copy2(bit2verilog / "xdsp48.v", args.output_dir)
    subprocess.run(
        ["verilator", "--binary", "--timing", "-Wno-fatal", "-I" + str(args.output_dir),
         "--top-module", args.testbench.stem, str(model), str(args.testbench),
         "-Mdir", str(args.output_dir / "obj")],
        check=True,
    )
    subprocess.run([str(args.output_dir / "obj" / ("V" + args.testbench.stem))], check=True)


if __name__ == "__main__":
    main()