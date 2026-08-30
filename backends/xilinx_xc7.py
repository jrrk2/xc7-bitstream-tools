"""Project X-Ray FASM-to-bitstream backend for Xilinx 7-series parts."""
import os
import subprocess
import sys
import tempfile
from pathlib import Path


def family_for_part(part):
    if part.startswith("xc7a"):
        return "artix7"
    if part.startswith("xc7k"):
        return "kintex7"
    if part.startswith("xc7s"):
        return "spartan7"
    if part.startswith("xc7v"):
        return "virtex7"
    if part.startswith("xc7z"):
        return "zynq7"
    raise ValueError("Unsupported XC7 part: %s" % part)


def fasm_to_bit(part, database_root, fasm, allow_missing_features=False):
    root = Path(__file__).resolve().parents[1]
    prjxray = root / "prjxray"
    fasm2frames = prjxray / "utils" / "fasm2frames.py"
    frames2bit = prjxray / "build" / "tools" / "xc7frames2bit"
    family = family_for_part(part)
    part_dir = database_root / family / part

    for path in (fasm2frames, frames2bit, part_dir / "part.yaml", fasm):
        if not path.exists():
            raise FileNotFoundError(path)

    environment = os.environ.copy()
    environment["PYTHONPATH"] = str(prjxray) + os.pathsep + environment.get("PYTHONPATH", "")
    if allow_missing_features:
        environment["XRAY_ALLOW_MISSING_FEATURES"] = "1"
    with tempfile.TemporaryDirectory() as temporary_dir:
        frames = Path(temporary_dir) / "design.frames"
        bitstream = Path(temporary_dir) / "design.bit"
        subprocess.run(
            [sys.executable, str(fasm2frames), "--part", part, "--db-root", str(database_root / family), str(fasm), str(frames)],
            check=True,
            env=environment,
        )
        subprocess.run(
            [str(frames2bit), "--part_file", str(part_dir / "part.yaml"), "--part_name", part,
             "--frm_file", str(frames), "--output_file", str(bitstream)],
            check=True,
        )
        return bitstream.read_bytes()