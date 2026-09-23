#!/usr/bin/env python3
"""prjxray's fasm2frames, with the FASM read by scripts/fasm_fast.py.

A wrapper rather than a patch to prjxray, because prjxray is a submodule
pinned by commit: editing it here would make every checkout of this repository
depend on a change that is not in the pinned tree.  Same arguments, same
behaviour, same output -- only the parser differs.  See fasm_fast.py for why.
"""

import os
import runpy
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "scripts"))
sys.path.insert(0, os.path.join(ROOT, "prjxray"))

import fasm_fast

fasm_fast.install()

# run_name="__main__" so fasm2frames' own "if __name__ == '__main__'" fires.
runpy.run_path(os.path.join(ROOT, "prjxray", "utils", "fasm2frames.py"),
               run_name="__main__")
