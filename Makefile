.PHONY: help setup litex-deps tools yosys nextpnr check-fasm vc707-ethmin vc707-ethmin-flash vc707-litex-ddr-gen vc707-litex-ddr-vivado vc707-litex-ddr-flash vc707-johnson vc707-telegraph vc707-telegraph-vivado vc707-telegraph-flash vc707-telegraph-flash-vivado vc707-litex-eth-vivado vc707-litex-eth-flash-vivado vc707-litex-ddr-eth-vivado vc707-litex-ddr-eth-flash-vivado vc707-litex-ddr-ethmin vc707-litex-ddr-ethmin-flash vc707-litex-ddr-ethmin-vivado vc707-litex-ddr-ethmin-vivado-pnr vc707-litex-ddr-ethmin-flash-vivado vc707-litex-linux vc707-litex-linux-emulator vc707-litex-linux-payload vc707-litex-linux-flash arty-blinky vc707-litex vc707-litex-gen vc707-litex-verify verify-examples sonata vc707 validate-bitstream fasm2netlist lvs z3-prove sat-match verify-extraction clean
.DEFAULT_GOAL := help

DESIGN ?= johnson_sonata
FASM ?=
PART ?= xc7a50tcsg324-1
# Defaults to the checkout the setup instructions and CI both make; override
# to point at a database elsewhere.
PRJXRAY_DB ?= .deps/prjxray-db
# cmake's chipdb generator runs with its working directory set to the build
# tree, so a database path given relative to here does not resolve there --
# it fails looking for <device>/tilegrid.json.  Make it absolute up front.
# `override` because the case that actually goes wrong is a relative path
# passed on the command line, and a command-line value beats a plain
# assignment.  The default is relative too, so it needs the same treatment.
override PRJXRAY_DB := $(abspath $(PRJXRAY_DB))
OUT ?= $(DESIGN).uf2
PYTHON ?= $(abspath .venv/bin/python)
NEXTPNR_DIR ?= nextpnr
NEXTPNR_BUILD ?= build
NEXTPNR_BIN ?= $(NEXTPNR_BUILD)/nextpnr-himbaechel

# HeAP trades wirelength against timing, and its default weight is too low for
# a design whose I/O is pinned at opposite ends of the die: the DDR3+SGMII SoC
# placed its 125 MHz GMII datapath ~76 rows from the transceiver and came out
# at 60-120 MHz across runs of IDENTICAL RTL -- a 2x lottery, with 78% of the
# critical path in wire.  At weight 60 the same netlist reaches 181/219 MHz.
#
# This is not tuning for one design.  Any design here with a fast datapath and
# distant pins is exposed to the same lottery; Vivado's placer closes 125 MHz
# on the very netlist nextpnr was failing, so the deficit was never the
# netlist.  Override for experiments: NEXTPNR_FLAGS=
NEXTPNR_FLAGS ?= --placer-heap-timingweight 60
# yosys is pinned as a submodule and built from source, because the answer the
# equivalence check gives depends on which yosys asked the question: the LiteX
# SoC proves completely under the pinned one and shows 36 differences under
# 0.64, since the two synthesise different netlists.  A sweep that used
# whatever yosys happened to be installed would report a different result on
# every machine and none of them would be wrong.
#
# Set YOSYS on the command line to use another one deliberately; the pinned
# build is only the default, and `make yosys` is what produces it.
YOSYS_DIR ?= yosys
YOSYS_BIN ?= $(YOSYS_DIR)/yosys
# Resolved and CHECKED by one script, so that neither this file nor the sweep
# can quietly settle for a different version.  Recursively expanded, so the
# check runs when a recipe actually needs yosys rather than on every make.
#
# Deliberately NOT called YOSYS.  Assigning YOSYS here would make `make` export
# this computed value in place of the one the user put in the environment, so
# the guard below would be handed an empty YOSYS, conclude that none was asked
# for, and approve the pinned build -- while the recipe ran with an empty
# command.  Leaving YOSYS alone lets it reach the guard as the user set it,
# which is the whole point of having a guard.
PINNED_YOSYS = $(shell scripts/pinned_yosys.sh 2>/dev/null)
VC707_DIR ?= examples/vc707-johnson
VC707_FASM ?=
VC707_PART ?= xc7vx485tffg1761-2
VC707_OUT ?= johnson_vc707.bit
TELEGRAPH_DIR ?= examples/vc707-telegraph
TELEGRAPH_OUT ?= telegraph_vc707.bit
BIT ?=
TESTBENCH ?=
VALIDATION_DIR ?= .validation
F2N_DIR ?= fasm2netlist
F2N_BIN ?= $(F2N_DIR)/build/fasm2netlist
VC707_DEVICE ?= xc7vx485t
VC707_FAMILY ?= virtex7
# The Arty A7-35: the smaller bin of the same die as the xc7a50t, so that is
# the chipdb nextpnr uses and the grid the database is keyed by, while the
# package pins come from the -35 part.
ARTY_DIR ?= examples/arty-blinky
ARTY_PART ?= xc7a35tcsg324-1
ARTY_DEVICE ?= xc7a50t
ARTY_FAMILY ?= artix7
ARTY_OUT ?= blinky_arty.bit

# The DDR3 LiteX SoC.  Vivado first and deliberately: a memory controller
# calibrates against real silicon timing, so "does the design work" and "does
# the open flow reproduce it" have to stay separate questions -- a board that
# fails to train its DDR tells you nothing about which half is at fault.
LITEX_DDR_DIR      ?= examples/vc707-litex-ddr
LITEX_DDR_GATEWARE ?= $(LITEX_DDR_DIR)/gateware
LITEX_DDR_TOP      ?= xilinx_vc707
LITEX_DDR_CPU      ?= serv

vc707-litex-ddr-gen:
	@test -x "$(PYTHON)" || { echo "Run 'make setup' first"; exit 2; }
	@$(PYTHON) -c 'import litedram' 2>/dev/null || { \
	  echo "LiteX packages missing from $(PYTHON); run: make litex-deps"; exit 2; }
	PATH="$(dir $(PYTHON)):$$PATH" $(PYTHON) $(LITEX_DDR_DIR)/vc707_litex_ddr.py \
		--cpu-type $(LITEX_DDR_CPU) --flow generated --no-compile-gateware --build \
		--output-dir $(LITEX_DDR_DIR)/build-generated
	cp $(LITEX_DDR_DIR)/build-generated/gateware/$(LITEX_DDR_TOP).v \
	   $(LITEX_DDR_DIR)/build-generated/gateware/$(LITEX_DDR_TOP).xdc \
	   $(LITEX_DDR_DIR)/build-generated/gateware/$(LITEX_DDR_TOP)_*.init $(LITEX_DDR_GATEWARE)/
	@echo "refreshed $(LITEX_DDR_GATEWARE)"

# Needs Vivado on PATH; VIVADO_BIN points at its bin directory if it is not.
VIVADO_BIN ?= /NFS/apps/Xilinx/Vivado/2020.1/bin
vc707-litex-ddr-vivado:
	@test -x "$(PYTHON)" || { echo "Run 'make setup' first"; exit 2; }
	@$(PYTHON) -c 'import litedram' 2>/dev/null || { \
	  echo "LiteX packages missing from $(PYTHON); run: make litex-deps"; exit 2; }
	rm -rf $(LITEX_DDR_DIR)/build-vivado
	$(LITEX_GEN) --with-ddr --output-dir $(LITEX_DDR_DIR)/build-vivado
	@echo "built $(LITEX_DDR_DIR)/build-vivado/gateware/$(LITEX_TOP).bit"

vc707-litex-ddr-flash:
	$(OFL) --cable digilent --freq 15000000 $(LITEX_DDR_DIR)/build-vivado/gateware/$(LITEX_DDR_TOP).bit

# The minimal LiteX SoC.  LITEX_GATEWARE holds the generated Verilog, checked
# in so a build needs neither LiteX nor a RISC-V toolchain; `make vc707-litex-gen`
# regenerates it and needs both.  yosys must run IN that directory: the design
# $readmemh's its ROM from a relative path, and from anywhere else the ROM
# reads as zero without a word of complaint.
LITEX_ETH_DIR  ?= examples/vc707-litex-eth
LITEX_DDRETH_DIR ?= examples/vc707-litex-ddr-eth
LITEX_DDRETHMIN_DIR ?= examples/vc707-litex-ddr-ethmin
LITEX_DDRETHMIN_OUT ?= litex_ddr_ethmin_vc707.bit
LINUX_DIR      ?= examples/vc707-litex-linux
LINUX_BUILD    ?= $(LITEX_DDRETHMIN_DIR)/build-linux
LINUX_OUT      ?= litex_linux_vc707.bit
# Kernel and rootfs are not vendored: point this at a directory holding an
# rv32ima `Image` and `rootfs.cpio`.
LINUX_IMAGES   ?= /home/jonathan/f4pga-examples/xc7/linux_litex_demo/buildroot
# Where the per-MAC TFTP server serves this board's payload from.
LINUX_TFTP_DIR ?= /home/jonathan/tftp-vc707/10:e2:d5:00:00:07
VEXRISCV_V     ?= $(CURDIR)/litex-deps/pythondata-cpu-vexriscv/pythondata_cpu_vexriscv/verilog/VexRiscv.v
VEXRISCV_LINUX_V ?= $(CURDIR)/litex-deps/pythondata-cpu-vexriscv/pythondata_cpu_vexriscv/verilog/VexRiscv_Linux.v
ETHMIN_PHY_V   ?= $(CURDIR)/examples/vc707-ethmin/rtl/liteeth_sgmii_phy.v
LITEX_DIR      ?= examples/vc707-litex
LITEX_GATEWARE ?= $(LITEX_DIR)/gateware
LITEX_TOP      ?= xilinx_vc707
LITEX_PART     ?= xc7vx485tffg1761-2
LITEX_DEVICE   ?= xc7vx485t
LITEX_FAMILY   ?= virtex7
LITEX_OUT      ?= litex_vc707.bit
LITEX_FLOW     ?= openXC7
LITEX_CPU      ?= serv

# Every example verifies itself: the bitstream's FASM is extracted back to a
# netlist and proved equivalent to the synthesis it came from.  A build that
# produces a bitstream nobody has checked is a build that can be quietly wrong,
# and this is cheap -- under a second for the VC707 Johnson counter.  Set
# VERIFY=0 to skip, e.g. when bringing up a design whose primitives the tile
# model does not cover yet.
VERIFY ?= 1
VERIFY_DIR ?= .verify
DESIGNS ?=
TILEVERILOG ?= $(F2N_DIR)/build/tileverilog
LVS_EQUIV ?= $(F2N_DIR)/build/lvs_equiv

# ethmin: a picorv32 SoC with a gigabit MAC and a LiteEth SGMII PCS on a GTX.
# Everything it needs is in this repository -- see examples/vc707-ethmin.
#
# --timing-allow-fail is deliberate and is the design's one outstanding fault:
# nextpnr places and routes it and then reports 18 hold-time violations, most
# on the MAC transmit path into a block RAM.  The bitstream is built anyway so
# the rest of the flow can be exercised on hardware, where it answers arping;
# treat a run of this target as "does it still build and come up", not as a
# design that meets timing.
ETHMIN_DIR  ?= examples/vc707-ethmin
ETHMIN_TOP  ?= vc707_ethmin
ETHMIN_PART ?= xc7vx485tffg1761-2
ETHMIN_OUT  ?= ethmin_vc707.bit
# One line, no continuations: a backslash inside the quoted yosys script is
# passed straight through and yosys reports it as an unknown command.
ETHMIN_SRCS := $(shell sed -e '/^[[:space:]]*\#/d' -e 's/[[:space:]][[:space:]]*\#.*$$//' -e '/^[[:space:]]*$$/d' examples/vc707-ethmin/sources.f | tr '\n' ' ')

vc707-ethmin: fasm2netlist nextpnr
	@scripts/pinned_yosys.sh >/dev/null
	@test -n "$(PRJXRAY_DB)" && test -d "$(PRJXRAY_DB)" || { echo "no Project X-Ray database at $(PRJXRAY_DB)"; echo "  git clone --depth 1 https://github.com/openXC7/prjxray-db .deps/prjxray-db"; echo "  (or build with PRJXRAY_DB=/path/to/prjxray-db)"; exit 2; }
	cd $(ETHMIN_DIR) && $(PINNED_YOSYS) -q -p 'read_verilog -sv $(ETHMIN_SRCS); synth_xilinx -flatten -abc9 -arch xc7 -top $(ETHMIN_TOP); write_json $(ETHMIN_TOP).json'
	$(NEXTPNR_BIN) --device $(ETHMIN_PART) -o xdc=$(ETHMIN_DIR)/$(ETHMIN_TOP).xdc \
		--json $(ETHMIN_DIR)/$(ETHMIN_TOP).json \
		-o fasm=$(ETHMIN_DIR)/$(ETHMIN_TOP).fasm \
		-o placement=$(ETHMIN_DIR)/$(ETHMIN_TOP)_placement.json \
		--router router2 $(NEXTPNR_FLAGS) --timing-allow-fail
	scripts/check_fasm_expressible.py $(PRJXRAY_DB)/virtex7 $(ETHMIN_PART) $(ETHMIN_DIR)/$(ETHMIN_TOP).fasm
	$(PYTHON) scripts/convert.py --arch xilinx --family xc7 \
		--part $(ETHMIN_PART) --db $(PRJXRAY_DB) \
		--fasm $(ETHMIN_DIR)/$(ETHMIN_TOP).fasm --output $(ETHMIN_OUT)
	@echo "built $(ETHMIN_OUT) -- flash it with 'make vc707-ethmin-flash'"

# The board this repository targets drives JTAG through the on-board Digilent
# cable; 15 MHz is what it is reliable at here.
OFL ?= openFPGALoader
vc707-ethmin-flash:
	@test -f $(ETHMIN_OUT) || { echo "no $(ETHMIN_OUT); run 'make vc707-ethmin' first"; exit 2; }
	$(OFL) --cable digilent --freq 15000000 $(ETHMIN_OUT)

vc707-litex: fasm2netlist nextpnr
	@scripts/pinned_yosys.sh >/dev/null
	@test -n "$(PRJXRAY_DB)" && test -d "$(PRJXRAY_DB)" || { echo "no Project X-Ray database at $(PRJXRAY_DB)"; echo "  git clone --depth 1 https://github.com/openXC7/prjxray-db .deps/prjxray-db"; echo "  (or build with PRJXRAY_DB=/path/to/prjxray-db)"; exit 2; }
	@test -f "$(LITEX_GATEWARE)/$(LITEX_TOP).v" || { echo "no generated gateware; run 'make vc707-litex-gen' first"; exit 2; }
	cd $(LITEX_GATEWARE) && $(PINNED_YOSYS) -q -p \
		'synth_xilinx -flatten -abc9 -arch xc7 -top $(LITEX_TOP); write_json $(LITEX_TOP).json' \
		$$(grep -v '^\#' sources.f)
	$(NEXTPNR_BIN) --device $(LITEX_PART) -o xdc=$(LITEX_GATEWARE)/$(LITEX_TOP).xdc \
		--json $(LITEX_GATEWARE)/$(LITEX_TOP).json \
		-o fasm=$(LITEX_GATEWARE)/$(LITEX_TOP).fasm \
		-o placement=$(LITEX_GATEWARE)/$(LITEX_TOP)_placement.json --router router2 $(NEXTPNR_FLAGS)
	$(PYTHON) scripts/convert.py --arch xilinx --family xc7 \
		--part $(LITEX_PART) --db $(PRJXRAY_DB) --fasm $(LITEX_GATEWARE)/$(LITEX_TOP).fasm --output $(LITEX_OUT)
	@echo
	@echo "Extracting it back out, with the families the tile model does not cover yet:"
	$(F2N_BIN) --fasm $(LITEX_GATEWARE)/$(LITEX_TOP).fasm --db $(PRJXRAY_DB) \
		--family $(LITEX_FAMILY) --device $(LITEX_DEVICE) --out $(LITEX_GATEWARE)/$(LITEX_TOP)_gates.v

# Regenerate the gateware from the LiteX sources.  Needs the submodules under
# litex-deps/ installed into the venv, and a RISC-V toolchain for the BIOS.
# Every LiteX package the generators import, installed editable so the
# checked-out submodule commit is what runs.  The guards below point here
# rather than each naming its own partial set: a fresh checkout otherwise
# discovers the dependencies one failure at a time.
LITEX_PKGS = migen litex litex-boards liteeth litedram \
             pythondata-cpu-serv pythondata-cpu-vexriscv \
             pythondata-software-picolibc pythondata-software-compiler_rt

litex-deps:
	@test -x "$(PYTHON)" || { echo "Run 'make setup' first"; exit 2; }
	@for p in $(LITEX_PKGS); do \
	  test -d litex-deps/$$p || { \
	    echo "litex-deps/$$p is empty; the submodules are not checked out:"; \
	    echo "  git submodule update --init --recursive"; exit 2; }; \
	done
	$(PYTHON) -m pip install $(foreach p,$(LITEX_PKGS),-e litex-deps/$(p))
	# Building the BIOS needs meson and ninja: picolibc is a meson project,
	# and LiteX looks for a `meson` BINARY on PATH (>= 0.59), not an
	# importable module.  Installed into the venv, where every target that
	# runs a generator already puts .venv/bin on PATH.  A system meson from
	# apt or brew serves just as well; this only makes a fresh checkout work
	# without one.
	$(PYTHON) -m pip install meson ninja
	@echo "LiteX packages installed in $(PYTHON)"
	@command -v meson >/dev/null 2>&1 || test -x "$(dir $(PYTHON))meson" || { \
	  echo "warning: no meson on PATH -- the BIOS build will fail"; }

# LITEX_FLOW names the flow in the BIOS banner's tagline, which is the only
# thing distinguishing two bitstreams built from identical gateware.
vc707-litex-gen:
	@test -x "$(PYTHON)" || { echo "Run 'make setup' first"; exit 2; }
	@$(PYTHON) -c 'import litex, migen, litex_boards' 2>/dev/null || { \
		echo "LiteX packages missing from $(PYTHON); run: make litex-deps"; exit 2; }
	PATH="$(dir $(PYTHON)):$$PATH" $(PYTHON) $(LITEX_DIR)/vc707_litex.py \
		--with-led-chaser --cpu-type $(LITEX_CPU) --integrated-main-ram-size 0x4000 \
		--flow $(LITEX_FLOW) --no-compile-gateware --build --output-dir $(LITEX_DIR)/build-$(LITEX_FLOW)
	cp $(LITEX_DIR)/build-$(LITEX_FLOW)/gateware/$(LITEX_TOP).v \
	   $(LITEX_DIR)/build-$(LITEX_FLOW)/gateware/$(LITEX_TOP).xdc \
	   $(LITEX_DIR)/build-$(LITEX_FLOW)/gateware/$(LITEX_TOP)_*.init $(LITEX_GATEWARE)/
	@echo "refreshed $(LITEX_GATEWARE) from the $(LITEX_FLOW) build"

# Prove the LiteX SoC against its own synthesis.  Separate from vc707-litex
# because the two answer different questions and cost different amounts: that
# target asks whether the flow produces a bitstream and gets the design back
# out of it, this one asks whether what came back out is the same circuit.
# It runs the same sweep CI does, narrowed to this one design, so a result
# here and a result in CI are the same measurement rather than two that
# happen to agree.  A design the tile model cannot yet cover is reported as
# blocked, with the reason -- not as a failure, and not silently.
vc707-litex-verify: fasm2netlist nextpnr
	@scripts/pinned_yosys.sh >/dev/null
	@test -n "$(PRJXRAY_DB)" && test -d "$(PRJXRAY_DB)" || { echo "no Project X-Ray database at $(PRJXRAY_DB)"; echo "  git clone --depth 1 https://github.com/openXC7/prjxray-db .deps/prjxray-db"; echo "  (or build with PRJXRAY_DB=/path/to/prjxray-db)"; exit 2; }
	YOSYS=$(PINNED_YOSYS) NEXTPNR_BIN=$(NEXTPNR_BIN) PRJXRAY_DB=$(PRJXRAY_DB) \
		TILEVERILOG=$(TILEVERILOG) LVS_EQUIV=$(LVS_EQUIV) OUT=$(VERIFY_DIR)/examples \
		scripts/verify_examples.sh vc707-litex

help:
	@printf '%s\n' 'Targets:' \
	  '  make setup                              Create the local Python environment' \
	  '  make litex-deps                         Install the LiteX packages the generators import' 	  '  make tools                              Build Project X-Ray conversion tools' \
	  '  make yosys                              Build the pinned yosys (the one the results are quoted for)' \
	  '  make vc707-johnson                      Build VC707 Johnson from source to raw bitstream' \
	  '  make vc707-telegraph                    Build VC707 telegraph: UART "JRRK" + heartbeat LED' \
	  '  make vc707-litex-ddr-ethmin             LiteX SoC with DDR3 + gigabit ethernet, open flow' \
	  '  make vc707-litex-ddr-ethmin-vivado-pnr  Place that same netlist in Vivado, to compare placers' \
	  '  make arty-blinky                        Build the Arty A7 blinky (the carry-chain example)' \
	  '  make vc707-litex                        Build the LiteX SoC from its checked-in gateware, and extract it' \
	  '  make vc707-litex-gen [LITEX_FLOW=vivado] Regenerate that gateware from the LiteX sources' \
	  '  make vc707-litex-verify                 Prove that SoC equals its synthesis, as CI does' \
	  '  make vc707-ethmin                       Build the gigabit-Ethernet SoC (picorv32 + LiteEth SGMII)' \
	  '  make vc707-ethmin-flash                 ...and flash it to the board' \
	  '  make vc707-litex-ddr-vivado             Build the DDR3 SoC with Vivado (the golden reference)' \
	  '  make vc707-litex-ddr-gen                Regenerate its gateware from the LiteX sources' \
	  '  make sonata FASM=...                    Convert an Artix-7 FASM to Sonata UF2' \
	  '  make vc707 VC707_FASM=...               Convert a Virtex-7 FASM to raw bitstream' \
	  '  make validate-bitstream PART=... BIT=... TESTBENCH=...' \
	  '  make fasm2netlist                       Build the FASM-to-netlist extractor' \
	  '  make lvs                                LVS-check the extraction against the placement' \
	  '  make z3-prove                           Prove extraction == gold synthesis with Z3' \
	  '  make sat-match                          Match registers with no placement oracle' \
	  '  make verify-extraction V_*=...          Extract a bitstream and prove it equals its synthesis' \
	  '  make verify-examples                    Prove every eligible nextpnr example, and say what is not' \
	  '  make verify-examples DESIGNS="a b"      ... or just the named ones, as the CI matrix does' \
	  '  make check-fasm FASM=...                Fail if a FASM needs bits prjxray does not have' \
	  '' \
	  'Examples verify themselves by default; pass VERIFY=0 to skip that step.'

setup:
	python3 -m venv .venv
	cd prjxray && $(PYTHON) -m pip install -r requirements.txt -e third_party/fasm
	$(PYTHON) -m pip install z3-solver

tools:
	cmake -S prjxray -B prjxray/build -DCMAKE_BUILD_TYPE=Release
	cmake --build prjxray/build --target bitread xc7frames2bit --parallel 4

# The pinned yosys builds with its own makefile -- CMake arrived after this
# commit, so do not "modernise" this without moving the pin, and moving the pin
# means re-establishing which results it gives.  ABC comes with it as a
# submodule, hence --recursive in the message: without it the build stops part
# way through with a missing abc rather than at the checkout.
yosys:
	@test -f $(YOSYS_DIR)/Makefile && test -f $(YOSYS_DIR)/abc/abc.rc || { \
	  echo "the yosys submodule is not checked out; run:"; \
	  echo "  git submodule update --init --recursive $(YOSYS_DIR)"; exit 2; }
	$(MAKE) -C $(YOSYS_DIR) -j$$(nproc)
	@echo "built $$($(YOSYS_BIN) -V)"

nextpnr:
	@test -n "$(PRJXRAY_DB)" && test -d "$(PRJXRAY_DB)" || { echo "no Project X-Ray database at $(PRJXRAY_DB)"; echo "  git clone --depth 1 https://github.com/openXC7/prjxray-db .deps/prjxray-db"; echo "  (or build with PRJXRAY_DB=/path/to/prjxray-db)"; exit 2; }
	cmake -S $(NEXTPNR_DIR) -B $(NEXTPNR_BUILD) -DARCH=himbaechel -DHIMBAECHEL_UARCH=xilinx \
		-DBUILD_GUI=OFF -DBUILD_PYTHON=OFF -DHIMBAECHEL_XILINX_DEVICES="xc7a50t;xc7vx485t" \
		-DHIMBAECHEL_PRJXRAY_DB=$(PRJXRAY_DB)
	cmake --build $(NEXTPNR_BUILD) --target nextpnr-himbaechel --parallel 4

vc707-johnson: tools nextpnr
	@scripts/pinned_yosys.sh >/dev/null
	cd $(VC707_DIR) && $(PINNED_YOSYS) -p 'synth_xilinx -flatten -abc9 -nobram -arch xc7 -top top; write_json johnson.json' top.v counter25_core.v
	$(NEXTPNR_BIN) --device $(VC707_PART) -o xdc=$(VC707_DIR)/top.xdc --json $(VC707_DIR)/johnson.json \
		-o fasm=$(VC707_DIR)/johnson.fasm -o placement=$(VC707_DIR)/johnson_placement.json --router router2 $(NEXTPNR_FLAGS)
	$(MAKE) vc707 VC707_FASM=$(VC707_DIR)/johnson.fasm PRJXRAY_DB=$(PRJXRAY_DB) VC707_OUT=$(VC707_OUT)
ifeq ($(VERIFY),1)
	$(MAKE) verify-extraction V_NAME=vc707-johnson V_FASM=$(VC707_DIR)/johnson.fasm \
		V_JSON=$(VC707_DIR)/johnson.json V_PLACE=$(VC707_DIR)/johnson_placement.json \
		V_XDC=$(VC707_DIR)/top.xdc V_TOP=top V_PART=$(VC707_PART) \
		V_DEVICE=$(VC707_DEVICE) V_FAMILY=$(VC707_FAMILY) PRJXRAY_DB=$(PRJXRAY_DB)
endif

# The smallest design here that drives BOTH a UART and an LED: a bit-banged
# 8N1 transmitter repeating "JRRK", with no CPU, no BRAM and no MMCM.  It
# exists to tell two failures apart that otherwise look identical -- a dead
# clock and a dead output path -- because a silent LiteX SoC drives no LED and
# so cannot distinguish them.  led[0] blinks at ~0.75 Hz if sysclk reaches the
# fabric; "JRRK" arrives at 115200 8N1 if the AU36 TX path works end to end.
vc707-telegraph: tools nextpnr
	@scripts/pinned_yosys.sh >/dev/null
	cd $(TELEGRAPH_DIR) && $(PINNED_YOSYS) -p 'synth_xilinx -flatten -abc9 -nobram -arch xc7 -top top; write_json telegraph.json' top.v telegraph_core.v
	$(NEXTPNR_BIN) --device $(VC707_PART) -o xdc=$(TELEGRAPH_DIR)/top.xdc --json $(TELEGRAPH_DIR)/telegraph.json \
		-o fasm=$(TELEGRAPH_DIR)/telegraph.fasm -o placement=$(TELEGRAPH_DIR)/telegraph_placement.json --router router2 $(NEXTPNR_FLAGS)
	$(MAKE) vc707 VC707_FASM=$(TELEGRAPH_DIR)/telegraph.fasm PRJXRAY_DB=$(PRJXRAY_DB) VC707_OUT=$(TELEGRAPH_OUT)
ifeq ($(VERIFY),1)
	$(MAKE) verify-extraction V_NAME=vc707-telegraph V_FASM=$(TELEGRAPH_DIR)/telegraph.fasm \
		V_JSON=$(TELEGRAPH_DIR)/telegraph.json V_PLACE=$(TELEGRAPH_DIR)/telegraph_placement.json \
		V_XDC=$(TELEGRAPH_DIR)/top.xdc V_TOP=top V_PART=$(VC707_PART) \
		V_DEVICE=$(VC707_DEVICE) V_FAMILY=$(VC707_FAMILY) PRJXRAY_DB=$(PRJXRAY_DB)
endif

# Vivado's build of the same RTL: the reference the open flow is graded
# against.  When the open flow's bitstream misbehaves on hardware, the useful
# question is not "is our bitstream wrong?" but "how does it differ from one
# that works?", and that needs both.
vc707-telegraph-vivado:
	cd $(TELEGRAPH_DIR) && mkdir -p build-vivado && $(VIVADO_BIN)/vivado -mode batch -nojournal -nolog -source build_vivado.tcl
	@echo "built $(TELEGRAPH_DIR)/build-vivado/telegraph.bit"

vc707-telegraph-flash:
	$(OFL) --cable digilent --freq 15000000 $(TELEGRAPH_OUT)

vc707-telegraph-flash-vivado:
	$(OFL) --cable digilent --freq 15000000 $(TELEGRAPH_DIR)/build-vivado/telegraph.bit

# The LiteX SoC triage matrix, all four variants from ONE generator
# (examples/vc707-litex/vc707_litex.py) so they cannot drift apart:
#
#   vc707-litex                 block RAM only            open flow: PROVED
#   vc707-litex-ddr-*           + DDR3 SODIMM             Vivado only so far
#   vc707-litex-eth-*           + LiteEth over the GTX    open flow: router
#   vc707-litex-ddr-eth-*       + both
#
# Each is built with Vivado first, where the answer is known, before the open
# flow is asked the same question; --flow names the build in the BIOS banner
# so two bitstreams from identical gateware can be told apart on the board.
# Note that --with-ddr selects a different clock generator (see _CRGDDR), so a
# DDR variant is not a controlled comparison against a non-DDR one.
LITEX_GEN = PATH="$(VIVADO_BIN):$(dir $(PYTHON)):$$PATH" $(PYTHON) $(LITEX_DIR)/vc707_litex.py \
	--with-led-chaser --cpu-type $(LITEX_CPU) --flow vivado --build

# Block RAM for main memory; the DDR variants take theirs from the SODIMM.
LITEX_BRAM_RAM = --integrated-main-ram-size 0x4000

vc707-litex-eth-vivado:
	@test -x "$(PYTHON)" || { echo "Run 'make setup' first"; exit 2; }
	@$(PYTHON) -c 'import liteeth' 2>/dev/null || { \
	  echo "LiteX packages missing from $(PYTHON); run: make litex-deps"; exit 2; }
	rm -rf $(LITEX_ETH_DIR)/build-vivado
	$(LITEX_GEN) $(LITEX_BRAM_RAM) --with-ethernet --output-dir $(LITEX_ETH_DIR)/build-vivado
	@echo "built $(LITEX_ETH_DIR)/build-vivado/gateware/$(LITEX_TOP).bit"

vc707-litex-ddr-eth-vivado:
	@test -x "$(PYTHON)" || { echo "Run 'make setup' first"; exit 2; }
	@$(PYTHON) -c 'import liteeth, litedram' 2>/dev/null || { \
	  echo "LiteX packages missing from $(PYTHON); run: make litex-deps"; exit 2; }
	rm -rf $(LITEX_DDRETH_DIR)/build-vivado
	$(LITEX_GEN) --with-ddr --with-ethernet --output-dir $(LITEX_DDRETH_DIR)/build-vivado
	@echo "built $(LITEX_DDRETH_DIR)/build-vivado/gateware/$(LITEX_TOP).bit"

vc707-litex-eth-flash-vivado:
	$(OFL) --cable digilent --freq 15000000 $(LITEX_ETH_DIR)/build-vivado/gateware/$(LITEX_TOP).bit

# DDR3 + the SGMII PCS taken from ethmin's wrapper rather than generated by
# LiteX.  This is the variant the open flow can route, so its golden build is
# the reference the open flow's bitstream is graded against -- and the one
# that says what the GMII timing looks like when placement is done properly.
# The result of 2026-09-06: a LiteX SoC with DDR3 *and* a working gigabit
# link, built entirely by yosys, nextpnr-himbaechel and prjxray.  On hardware
# it calibrates the SODIMM, passes memtest, brings up 1000BASE-X over the GTX
# and network-boots over it.
#
# Two things make it work, and neither is obvious:
#   * --with-ethmin-phy, so the SGMII PCS comes from examples/vc707-ethmin's
#     wrapper rather than LiteX's K7_1000BASEX.  Same PCS; the difference is
#     its clocking, and LiteX's does not route here.
#   * NEXTPNR_FLAGS' placer timing weight (see the top of this file).  At the
#     default the GMII datapath lands 60-120 MHz across identical runs.
vc707-litex-ddr-ethmin: fasm2netlist nextpnr
	@scripts/pinned_yosys.sh >/dev/null
	@test -n "$(PRJXRAY_DB)" && test -d "$(PRJXRAY_DB)" || { echo "no Project X-Ray database at $(PRJXRAY_DB)"; echo "  git clone --depth 1 https://github.com/openXC7/prjxray-db .deps/prjxray-db"; echo "  (or build with PRJXRAY_DB=/path/to/prjxray-db)"; exit 2; }
	@test -x "$(PYTHON)" || { echo "Run 'make setup' first"; exit 2; }
	@$(PYTHON) -c 'import liteeth, litedram, pythondata_cpu_vexriscv' 2>/dev/null || { \
	  echo "LiteX packages missing from $(PYTHON); run: make litex-deps"; exit 2; }
	rm -rf $(LITEX_DDRETHMIN_DIR)/build-openXC7
	PATH="$(dir $(PYTHON)):$$PATH" $(PYTHON) $(LITEX_DIR)/vc707_litex.py \
		--with-led-chaser --cpu-type vexriscv --with-ddr --with-ethmin-phy \
		--flow openXC7 --no-compile-gateware --build \
		--output-dir $(LITEX_DDRETHMIN_DIR)/build-openXC7
	cd $(LITEX_DDRETHMIN_DIR)/build-openXC7/gateware && $(PINNED_YOSYS) -q -p \
		'synth_xilinx -flatten -abc9 -arch xc7 -top $(LITEX_TOP); write_json $(LITEX_TOP).json' \
		$(VEXRISCV_V) $(ETHMIN_PHY_V) $(LITEX_TOP).v
	$(NEXTPNR_BIN) --device $(LITEX_PART) \
		-o xdc=$(LITEX_DDRETHMIN_DIR)/build-openXC7/gateware/$(LITEX_TOP).xdc \
		--json $(LITEX_DDRETHMIN_DIR)/build-openXC7/gateware/$(LITEX_TOP).json \
		-o fasm=$(LITEX_DDRETHMIN_DIR)/build-openXC7/gateware/$(LITEX_TOP).fasm \
		--router router2 $(NEXTPNR_FLAGS)
	$(MAKE) check-fasm FASM=$(LITEX_DDRETHMIN_DIR)/build-openXC7/gateware/$(LITEX_TOP).fasm PRJXRAY_DB=$(PRJXRAY_DB)
	$(PYTHON) scripts/convert.py --arch xilinx --family xc7 --part $(LITEX_PART) \
		--db $(PRJXRAY_DB) --fasm $(LITEX_DDRETHMIN_DIR)/build-openXC7/gateware/$(LITEX_TOP).fasm \
		--output $(LITEX_DDRETHMIN_OUT)
	@echo "built $(LITEX_DDRETHMIN_OUT) -- flash with 'make vc707-litex-ddr-ethmin-flash'"

# Linux, through the open flow.  See examples/vc707-litex-linux/README.md.
vc707-litex-linux: fasm2netlist nextpnr
	@scripts/pinned_yosys.sh >/dev/null
	@test -n "$(PRJXRAY_DB)" && test -d "$(PRJXRAY_DB)" || { echo "no Project X-Ray database at $(PRJXRAY_DB)"; echo "  git clone --depth 1 https://github.com/openXC7/prjxray-db .deps/prjxray-db"; echo "  (or build with PRJXRAY_DB=/path/to/prjxray-db)"; exit 2; }
	rm -rf $(LINUX_BUILD)
	PATH="$(dir $(PYTHON)):$$PATH" $(PYTHON) $(LITEX_DIR)/vc707_litex.py \
		--with-led-chaser --cpu-type vexriscv --cpu-variant linux \
		--with-ddr --with-ethmin-phy --flow openXC7 --no-compile-gateware \
		--build --output-dir $(LINUX_BUILD)
	cd $(LINUX_BUILD)/gateware && $(PINNED_YOSYS) -q -p \
		'synth_xilinx -flatten -abc9 -arch xc7 -top $(LITEX_TOP); write_json $(LITEX_TOP).json' \
		$(VEXRISCV_LINUX_V) $(ETHMIN_PHY_V) $(LITEX_TOP).v
	$(NEXTPNR_BIN) --device $(LITEX_PART) -o xdc=$(LINUX_BUILD)/gateware/$(LITEX_TOP).xdc \
		--json $(LINUX_BUILD)/gateware/$(LITEX_TOP).json \
		-o fasm=$(LINUX_BUILD)/gateware/$(LITEX_TOP).fasm \
		--router router2 $(NEXTPNR_FLAGS) --timing-allow-fail
	$(MAKE) check-fasm FASM=$(LINUX_BUILD)/gateware/$(LITEX_TOP).fasm PRJXRAY_DB=$(PRJXRAY_DB)
	$(PYTHON) scripts/convert.py --arch xilinx --family xc7 --part $(LITEX_PART) \
		--db $(PRJXRAY_DB) --fasm $(LINUX_BUILD)/gateware/$(LITEX_TOP).fasm --output $(LINUX_OUT)
	@echo "built $(LINUX_OUT); now 'make vc707-litex-linux-payload'"

# The emulator and the dtb both come from THIS SoC's csr.json: the emulator
# #includes generated/csr.h, and adding the CPU timer shifts every CSR bank.
# Split out so CI can build it: this needs only the SoC, where the payload
# also needs a kernel and rootfs, which are not vendored.  The emulator takes
# its addresses from the SoC's generated/csr.h, so building it is a real check
# that the SoC still provides what the machine-mode software expects -- it is
# how the missing cpu_timer would have been caught.
vc707-litex-linux-emulator:
	@test -d $(LINUX_BUILD)/software || { echo "run 'make vc707-litex-linux' first"; exit 2; }
	$(MAKE) -C $(LINUX_DIR)/emulator BUILD_DIR=$(CURDIR)/$(LINUX_BUILD)
	@echo "built $(LINUX_DIR)/emulator/emulator.bin"

vc707-litex-linux-payload: vc707-litex-linux-emulator
	@test -f $(LINUX_IMAGES)/Image || { echo "LINUX_IMAGES must hold Image and rootfs.cpio"; exit 2; }
	mkdir -p "$(LINUX_TFTP_DIR)"
	cp $(LINUX_IMAGES)/Image $(LINUX_IMAGES)/rootfs.cpio "$(LINUX_TFTP_DIR)/"
	cp $(LINUX_DIR)/emulator/emulator.bin "$(LINUX_TFTP_DIR)/"
	$(PYTHON) scripts/linux_payload.py --dts $(LINUX_DIR)/rv32.dts \
		--csr $(LINUX_BUILD)/csr.json --images $(LINUX_IMAGES) \
		--out "$(LINUX_TFTP_DIR)"
	@echo "payload staged in $(LINUX_TFTP_DIR)"

vc707-litex-linux-flash:
	$(OFL) --cable digilent --freq 15000000 $(LINUX_OUT)

vc707-litex-ddr-ethmin-flash:
	$(OFL) --cable digilent --freq 15000000 $(LITEX_DDRETHMIN_OUT)

# Place and route the OPEN FLOW's own netlist in Vivado.  This is how the
# placer was identified as the deficit: same yosys netlist, same constraints,
# only the placer differs.  Vivado met 125 MHz where nextpnr reached 78.8, and
# its bitstream ran on hardware -- so the netlist was never the problem.
# Writes timing.rpt, clocks.rpt and a routed checkpoint for comparison.
vc707-litex-ddr-ethmin-vivado-pnr:
	@test -f $(LITEX_DDRETHMIN_DIR)/build-openXC7/gateware/$(LITEX_TOP).v || { \
	  echo "run 'make vc707-litex-ddr-ethmin' first"; exit 2; }
	@scripts/pinned_yosys.sh >/dev/null
	mkdir -p $(LITEX_DDRETHMIN_DIR)/vivado-pnr/edif
	cd $(LITEX_DDRETHMIN_DIR)/build-openXC7/gateware && $(PINNED_YOSYS) -q -p \
		'synth_xilinx -flatten -abc9 -arch xc7 -top $(LITEX_TOP); delete t:$$scopeinfo; write_edif -pvector bra $(CURDIR)/$(LITEX_DDRETHMIN_DIR)/vivado-pnr/edif/$(LITEX_TOP).edif' \
		$(VEXRISCV_V) $(ETHMIN_PHY_V) $(LITEX_TOP).v
	$(VIVADO_BIN)/vivado -mode batch -nojournal -nolog -source scripts/vivado_pnr_netlist.tcl \
		-tclargs $(CURDIR)/$(LITEX_DDRETHMIN_DIR)/vivado-pnr/edif/$(LITEX_TOP).edif \
		$(CURDIR)/$(LITEX_DDRETHMIN_DIR)/build-openXC7/gateware/$(LITEX_TOP).xdc \
		$(CURDIR)/$(LITEX_DDRETHMIN_DIR)/vivado-pnr $(LITEX_PART)
	@echo "see $(LITEX_DDRETHMIN_DIR)/vivado-pnr/timing.rpt"

vc707-litex-ddr-ethmin-vivado:
	@test -x "$(PYTHON)" || { echo "Run 'make setup' first"; exit 2; }
	@$(PYTHON) -c 'import liteeth, litedram' 2>/dev/null || { \
	  echo "LiteEth and LiteDRAM must both be installed in $(PYTHON)"; exit 2; }
	rm -rf $(LITEX_DDRETHMIN_DIR)/build-vivado
	$(LITEX_GEN) --with-ddr --with-ethmin-phy --output-dir $(LITEX_DDRETHMIN_DIR)/build-vivado
	@echo "built $(LITEX_DDRETHMIN_DIR)/build-vivado/gateware/$(LITEX_TOP).bit"

vc707-litex-ddr-ethmin-flash-vivado:
	$(OFL) --cable digilent --freq 15000000 $(LITEX_DDRETHMIN_DIR)/build-vivado/gateware/$(LITEX_TOP).bit

vc707-litex-ddr-eth-flash-vivado:
	$(OFL) --cable digilent --freq 15000000 $(LITEX_DDRETH_DIR)/build-vivado/gateware/$(LITEX_TOP).bit

# A counter and nothing else -- no LUT logic at all, seven carry cells and an
# inverter.  Small, but the only example here that exercises the carry chain,
# which is a part of the fabric a design without one cannot check at all.
arty-blinky: tools nextpnr
	@scripts/pinned_yosys.sh >/dev/null
	cd $(ARTY_DIR) && $(PINNED_YOSYS) -p 'synth_xilinx -flatten -abc9 -nobram -arch xc7 -top blinky; write_json blinky.json' blinky.v
	$(NEXTPNR_BIN) --device $(ARTY_PART) -o xdc=$(ARTY_DIR)/blinky.xdc --json $(ARTY_DIR)/blinky.json \
		-o fasm=$(ARTY_DIR)/blinky.fasm -o placement=$(ARTY_DIR)/blinky_placement.json --router router2 $(NEXTPNR_FLAGS)
	$(PYTHON) scripts/convert.py --arch xilinx --family xc7 \
		--part $(ARTY_PART) --db $(PRJXRAY_DB) --fasm $(ARTY_DIR)/blinky.fasm --output $(ARTY_OUT)
ifeq ($(VERIFY),1)
	$(MAKE) verify-extraction V_NAME=arty-blinky V_FASM=$(ARTY_DIR)/blinky.fasm \
		V_JSON=$(ARTY_DIR)/blinky.json V_PLACE=$(ARTY_DIR)/blinky_placement.json \
		V_XDC=$(ARTY_DIR)/blinky.xdc V_TOP=blinky V_PART=$(ARTY_PART) \
		V_DEVICE=$(ARTY_DEVICE) V_FAMILY=$(ARTY_FAMILY) PRJXRAY_DB=$(PRJXRAY_DB)
endif

# The whole sweep: every example nextpnr ships that the tile model covers,
# built from source and proved against its own bitstream.  The ones it does
# not cover are printed with the reason rather than left out.
verify-examples: fasm2netlist nextpnr
	@scripts/pinned_yosys.sh >/dev/null
	@test -n "$(PRJXRAY_DB)" && test -d "$(PRJXRAY_DB)" || { echo "no Project X-Ray database at $(PRJXRAY_DB)"; echo "  git clone --depth 1 https://github.com/openXC7/prjxray-db .deps/prjxray-db"; echo "  (or build with PRJXRAY_DB=/path/to/prjxray-db)"; exit 2; }
	YOSYS=$(PINNED_YOSYS) NEXTPNR_BIN=$(NEXTPNR_BIN) PRJXRAY_DB=$(PRJXRAY_DB) \
		TILEVERILOG=$(TILEVERILOG) LVS_EQUIV=$(LVS_EQUIV) OUT=$(VERIFY_DIR)/examples \
		scripts/verify_examples.sh $(DESIGNS)

sonata:
	@test -x "$(PYTHON)" || { echo "Run 'make setup' first"; exit 2; }
	@test -n "$(FASM)" || { echo "FASM must name an existing implementation output"; exit 2; }
	@test -f "$(FASM)" || { echo "FASM not found: $(FASM)"; exit 2; }
	@test -n "$(PRJXRAY_DB)" && test -d "$(PRJXRAY_DB)" || { echo "no Project X-Ray database at $(PRJXRAY_DB)"; echo "  git clone --depth 1 https://github.com/openXC7/prjxray-db .deps/prjxray-db"; echo "  (or build with PRJXRAY_DB=/path/to/prjxray-db)"; exit 2; }
	$(PYTHON) scripts/convert.py --arch xilinx --family xc7 --board sonata \
		--part $(PART) --db $(PRJXRAY_DB) --fasm $(FASM) --output $(OUT)

vc707:
	@test -x "$(PYTHON)" || { echo "Run 'make setup' first"; exit 2; }
	@test -n "$(VC707_FASM)" || { echo "VC707_FASM must name an existing VC707 implementation output"; exit 2; }
	@test -f "$(VC707_FASM)" || { echo "VC707_FASM not found: $(VC707_FASM)"; exit 2; }
	@test -n "$(PRJXRAY_DB)" && test -d "$(PRJXRAY_DB)" || { echo "no Project X-Ray database at $(PRJXRAY_DB)"; echo "  git clone --depth 1 https://github.com/openXC7/prjxray-db .deps/prjxray-db"; echo "  (or build with PRJXRAY_DB=/path/to/prjxray-db)"; exit 2; }
	$(PYTHON) scripts/convert.py --arch xilinx --family xc7 \
		--part $(VC707_PART) --db $(PRJXRAY_DB) --fasm $(VC707_FASM) --output $(VC707_OUT)

validate-bitstream:
	@test -x "$(PYTHON)" || { echo "Run 'make setup' first"; exit 2; }
	@test -n "$(BIT)" && test -f "$(BIT)" || { echo "BIT must name an existing XC7 bitstream"; exit 2; }
	@test -n "$(TESTBENCH)" && test -f "$(TESTBENCH)" || { echo "TESTBENCH must name an existing Verilator testbench"; exit 2; }
	@test -n "$(PRJXRAY_DB)" && test -d "$(PRJXRAY_DB)" || { echo "no Project X-Ray database at $(PRJXRAY_DB)"; echo "  git clone --depth 1 https://github.com/openXC7/prjxray-db .deps/prjxray-db"; echo "  (or build with PRJXRAY_DB=/path/to/prjxray-db)"; exit 2; }
	$(PYTHON) scripts/validate_bitstream.py --part $(PART) --db $(PRJXRAY_DB) \
		--bit $(BIT) --testbench $(TESTBENCH) --output-dir $(VALIDATION_DIR)

# The extraction/equivalence flow.  fasm2netlist rebuilds a netlist from the
# FASM alone plus the fixed prjxray database; the checks below relate that
# reconstruction to the design's own gold synthesis.  johnson_placement.json,
# written by the same nextpnr run that wrote the FASM, is the ground truth
# that maps gold cell names to the physical sites the extraction names cells
# after.
fasm2netlist:
	cmake -S $(F2N_DIR) -B $(F2N_DIR)/build -DCMAKE_BUILD_TYPE=Release
	cmake --build $(F2N_DIR)/build --parallel 4

lvs: fasm2netlist
	@test -d .deps/prjxray-db || { echo "no database at .deps/prjxray-db; git clone --depth 1 https://github.com/openXC7/prjxray-db .deps/prjxray-db"; exit 2; }
	$(PYTHON) $(F2N_DIR)/tests/lvs/test_johnson_lvs.py --exe $(F2N_BIN) \
		--xc7-tools-dir $(CURDIR) --family $(VC707_FAMILY) --device $(VC707_DEVICE)

z3-prove: fasm2netlist
	@test -d .deps/prjxray-db || { echo "no database at .deps/prjxray-db; git clone --depth 1 https://github.com/openXC7/prjxray-db .deps/prjxray-db"; exit 2; }
	$(PYTHON) $(F2N_DIR)/tests/lvs/prove_z3_sop_equiv.py --exe $(F2N_BIN) \
		--xc7-tools-dir $(CURDIR) \
		--family $(VC707_FAMILY) --device $(VC707_DEVICE) --part $(VC707_PART)

sat-match: fasm2netlist
	@test -d .deps/prjxray-db || { echo "no database at .deps/prjxray-db; git clone --depth 1 https://github.com/openXC7/prjxray-db .deps/prjxray-db"; exit 2; }
	$(PYTHON) $(F2N_DIR)/tests/lvs/match_and_prove_sat.py --exe $(F2N_BIN) \
		--xc7-tools-dir $(CURDIR) \
		--family $(VC707_FAMILY) --device $(VC707_DEVICE) --part $(VC707_PART)

# Extract a bitstream's FASM back to a netlist and prove it equivalent to the
# synthesis it was built from.  Nothing here reads a placement or a routed dump
# for the extraction itself -- the placement is used only to relate the gold
# netlist's register names to the sites the extraction names its cells after,
# and the XDC only to label the pads.
#
#   V_NAME   label for the working directory
#   V_FASM   the design's FASM          V_JSON   its gold synthesis
#   V_PLACE  the placement dump         V_XDC    its constraints
#   V_TOP    top module in V_JSON       V_PART / V_DEVICE / V_FAMILY
#
# Two extractions are written: fabric.v names every net after the silicon it
# was read out of -- that is the one the proof runs on, so that the register
# correspondence has to come from the placement rather than from a coincidence
# of names -- and fabric_named.v carries the design's own names, for reading.
verify-extraction: fasm2netlist
	@test -n "$(V_FASM)" || { echo "verify-extraction needs V_FASM=..."; exit 2; }
	@test -n "$(PRJXRAY_DB)" && test -d "$(PRJXRAY_DB)" || { echo "no Project X-Ray database at $(PRJXRAY_DB)"; echo "  git clone --depth 1 https://github.com/openXC7/prjxray-db .deps/prjxray-db"; echo "  (or build with PRJXRAY_DB=/path/to/prjxray-db)"; exit 2; }
	@scripts/pinned_yosys.sh >/dev/null
	@mkdir -p $(VERIFY_DIR)/$(V_NAME)
	$(TILEVERILOG) --fasm $(V_FASM) --db $(PRJXRAY_DB)/$(V_FAMILY) --device $(V_DEVICE) \
		--xdc $(V_XDC) --part $(V_PART) \
		--out $(VERIFY_DIR)/$(V_NAME)/fabric.v --model-out $(VERIFY_DIR)/$(V_NAME)/tile_model.v
	$(TILEVERILOG) --fasm $(V_FASM) --db $(PRJXRAY_DB)/$(V_FAMILY) --device $(V_DEVICE) \
		--xdc $(V_XDC) --part $(V_PART) --placement $(V_PLACE) --gold-json $(V_JSON) \
		--out $(VERIFY_DIR)/$(V_NAME)/fabric_named.v
	$(PINNED_YOSYS) -q -p "read_json $(V_JSON); hierarchy -top $(V_TOP); splitnets; \
		select $(V_TOP); write_verilog -noattr -norename -selected $(VERIFY_DIR)/$(V_NAME)/gold.v"
	$(LVS_EQUIV) --gold $(VERIFY_DIR)/$(V_NAME)/gold.v --gold-top $(V_TOP) \
		--gate $(VERIFY_DIR)/$(V_NAME)/fabric.v --gate-top fabric \
		--placement $(V_PLACE) --gold-json $(V_JSON) \
		--db $(PRJXRAY_DB)/$(V_FAMILY) --device $(V_DEVICE) --quiet

# A FASM can contain features prjxray has no bits for.  fasm2frames drops those
# silently under XRAY_ALLOW_MISSING_FEATURES, so the bitstream is missing a
# connection the router believed it had made and the board comes up dead in a
# way nothing upstream reports.  This is the strict answer: assemble with the
# override OFF and fail if anything does not resolve.
#
#   make check-fasm FASM=.verify/examples/vc707-litex/design.fasm
# Defaults to the VC707, since that is the board these examples target;
# CHECK_FAMILY and CHECK_PART override it for anything else.
CHECK_FAMILY ?= virtex7
CHECK_PART ?= xc7vx485tffg1761-2
check-fasm:
	@test -n "$(FASM)" || { echo "check-fasm needs FASM=..."; exit 2; }
	@test -n "$(PRJXRAY_DB)" && test -d "$(PRJXRAY_DB)" || { echo "no Project X-Ray database at $(PRJXRAY_DB)"; echo "  git clone --depth 1 https://github.com/openXC7/prjxray-db .deps/prjxray-db"; echo "  (or build with PRJXRAY_DB=/path/to/prjxray-db)"; exit 2; }
	scripts/check_fasm_expressible.py $(PRJXRAY_DB)/$(CHECK_FAMILY) $(CHECK_PART) $(FASM)

clean:
	rm -rf .validation $(VERIFY_DIR)
	rm -f *.bit *.frames *.uf2
	rm -f $(VC707_DIR)/johnson.json $(VC707_DIR)/johnson.fasm