#!/usr/bin/env python3
"""Assert that a FASM file contains nothing the bitstream cannot express.

Our flows run fasm2frames with XRAY_ALLOW_MISSING_FEATURES=1, which SILENTLY
DROPS any feature prjxray cannot resolve.  A bitstream can therefore be missing
connections nextpnr believed it had routed, and the board configures and does
nothing -- that is exactly how the LiteX SoC came up dark, via a clock routed
through HCLK_IOI_I2IOCLK_* pips that have no bits in the artix7 database.

This runs fasm2frames in STRICT mode (the env var unset) so a missing feature
is an error rather than a shrug.  fasm2frames is the authority here: features
like LUT INIT and the PLLE2 parameter tables are resolved by special-case code
rather than by a segbits lookup, so checking segbits_*.db by hand reports false
failures on a perfectly good FASM.

Exits 0 if every feature resolves, non-zero otherwise.

Usage: check_fasm_expressible.py <db-root> <part> <file.fasm>
  e.g. check_fasm_expressible.py .deps/prjxray-db/virtex7 \\
           xc7vx485tffg1761-2 .verify/examples/vc707-litex/design.fasm
"""
import os
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
PXPY = os.path.join(ROOT, ".venv", "bin", "python")
F2F = os.path.join(ROOT, "prjxray", "utils", "fasm2frames.py")


def main():
    if len(sys.argv) != 4:
        print(__doc__)
        return 2
    db_root, part, fasm_path = sys.argv[1], sys.argv[2], sys.argv[3]

    for p in (PXPY, F2F):
        if not os.path.exists(p):
            print("missing %s (run the prjxray venv setup first)" % p)
            return 2
    if not os.path.exists(fasm_path):
        print("missing FASM %s" % fasm_path)
        return 2

    env = dict(os.environ)
    # The whole point: do NOT allow missing features.
    env.pop("XRAY_ALLOW_MISSING_FEATURES", None)
    # prjxray's own package is not installed into the venv, only its
    # dependencies, so put the checkout on the path the way the Makefile does.
    env["PYTHONPATH"] = os.path.join(ROOT, "prjxray") + os.pathsep + env.get("PYTHONPATH", "")

    with tempfile.NamedTemporaryFile(suffix=".frames", delete=False) as tf:
        frames = tf.name
    try:
        proc = subprocess.run(
            [PXPY, F2F, "--db-root", db_root, "--part", part, fasm_path, frames],
            env=env, capture_output=True, text=True)
    finally:
        if os.path.exists(frames):
            os.unlink(frames)

    if proc.returncode == 0:
        print("PASS: %s -- every feature resolves against %s (%s)"
              % (os.path.basename(fasm_path), os.path.basename(db_root), part))
        return 0

    print("FAIL: %s contains features the bitstream cannot express."
          % os.path.basename(fasm_path))
    print("      With XRAY_ALLOW_MISSING_FEATURES=1 these are dropped silently")
    print("      and the connection is simply absent from the hardware.")
    print()
    tail = [ln for ln in proc.stderr.splitlines()
            if ln.strip() and "Warning" not in ln and "warn(" not in ln]
    for ln in tail[-25:]:
        print("  " + ln)
    return 1


if __name__ == "__main__":
    sys.exit(main())
