# XC7 Bitstream Tools

This repository packages FASM emitted by FPGA implementation tools into
board-deployment images. It owns neither synthesis nor place-and-route.

The repository contains two submodules:

- `nextpnr` supplies the implementation flow and FASM-producing examples.
- `prjxray` supplies `fasm2frames.py` and `xc7frames2bit`.

The converter performs no work for unsupported architectures. The only
implemented backend is `--arch xilinx --family xc7`.

Run `make` to display the available conversion and validation targets.

## Proving what was built

Every example verifies itself: the bitstream's FASM is extracted back to a
netlist and proved equivalent to the synthesis it came from.

```sh
make verify-examples PRJXRAY_DB=/path/to/prjxray-db
```

The largest is a LiteX SoC (SERV CPU, BIOS in block RAM, register file in
distributed RAM, carry chains, an MMCM) at 2820 proved obligations and no
differences. `fasm2netlist/README.md` describes what the checker models, what
it cuts at a boundary, and what it assumes.

yosys is pinned as a submodule and built from source, because which yosys
synthesised a design decides what the proof is even asking -- the same SoC
proves completely under the pinned version and shows differences under another,
since the two produce different netlists. `make yosys` builds it, and the sweep
refuses to run with a different one unless `YOSYS_UNPINNED=1` says you mean it.

## Setup

```sh
git submodule update --init --recursive
cmake -S prjxray -B prjxray/build -DCMAKE_BUILD_TYPE=Release
make tools
make yosys
make setup
```

Pass a Project X-Ray database checkout with `PRJXRAY_DB`; it is deliberately
not vendored because it is a large, independently versioned database. `make
setup` creates a repository-local `.venv` and installs the Python dependencies
declared by the pinned Project X-Ray submodule; it never changes the system
Python environment.

## Sonata

Convert any Sonata FASM into the board's UF2 format:

```sh
make sonata DESIGN=johnson_sonata \
  FASM=/path/to/johnson_sonata.fasm \
  PRJXRAY_DB=/path/to/prjxray-db
```

This produces `johnson_sonata.uf2`, with Sonata's family ID `0x6ce29e6b` and
slot-one base address `0x00000000`. The converter does not upload the image.

The equivalent generic invocation is:

```sh
python3 scripts/convert.py --arch xilinx --family xc7 --board sonata \
  --part xc7a50tcsg324-1 --db /path/to/prjxray-db \
  --fasm design.fasm --output design.uf2
```

Use `--board` only where a board-specific container is needed. Omitting it
produces a raw XC7 `.bit` image.

## VC707

The VC707 uses the Virtex-7 part `xc7vx485tffg1761-2` and consumes a raw
bitstream. Build the included Johnson test design all the way from Verilog:

```sh
make vc707-johnson PRJXRAY_DB=/path/to/prjxray-db
```

The target configures and builds one multi-device Himbaechel/Xilinx binary,
using its `xc7a50t` and `xc7vx485t` chip databases, then runs synthesis,
place-and-route, FASM conversion, and raw-bitstream packaging. It requires
Yosys on `PATH` (or `YOSYS=/path/to/yosys`).

Convert an existing routed VC707 FASM with:

```sh
make vc707 \
  VC707_FASM=/path/to/johnson.fasm \
  PRJXRAY_DB=/path/to/prjxray-db
```

This writes `johnson_vc707.bit`. The XC7 backend selects the `virtex7`
database automatically from the part name.

## Bitstream Validation

Optional bitstream validation reconstructs a physical XC7 `.bit` as a
configured Verilog fabric and runs a caller-provided Verilator testbench. This
is independent of physical hardware and belongs in this repository rather than
the `nextpnr` submodule.

```sh
make validate-bitstream \
  PART=xc7a50tcsg324-1 \
  BIT=/path/to/design.bit \
  TESTBENCH=/path/to/design_tb.v \
  PRJXRAY_DB=/path/to/prjxray-db
```

The generated FASM, reconstructed model, support models, and simulator output
are placed in `.validation`. The testbench module name must match its filename.
The `bit2verilog` submodule supplies the fabric reconstruction models; the
orchestration layer creates a temporary Project X-Ray database view so the same
command works with every XC7 family.