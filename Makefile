.PHONY: help setup tools nextpnr vc707-johnson sonata vc707 validate-bitstream fasm2netlist lvs z3-prove sat-match verify-extraction clean
.DEFAULT_GOAL := help

DESIGN ?= johnson_sonata
FASM ?=
PART ?= xc7a50tcsg324-1
PRJXRAY_DB ?=
OUT ?= $(DESIGN).uf2
PYTHON ?= $(abspath .venv/bin/python)
NEXTPNR_DIR ?= nextpnr
NEXTPNR_BUILD ?= build
NEXTPNR_BIN ?= $(NEXTPNR_BUILD)/nextpnr-himbaechel
YOSYS ?= yosys
VC707_DIR ?= examples/vc707-johnson
VC707_FASM ?=
VC707_PART ?= xc7vx485tffg1761-2
VC707_OUT ?= johnson_vc707.bit
BIT ?=
TESTBENCH ?=
VALIDATION_DIR ?= .validation
F2N_DIR ?= fasm2netlist
F2N_BIN ?= $(F2N_DIR)/build/fasm2netlist
VC707_DEVICE ?= xc7vx485t
VC707_FAMILY ?= virtex7

# Every example verifies itself: the bitstream's FASM is extracted back to a
# netlist and proved equivalent to the synthesis it came from.  A build that
# produces a bitstream nobody has checked is a build that can be quietly wrong,
# and this is cheap -- under a second for the VC707 Johnson counter.  Set
# VERIFY=0 to skip, e.g. when bringing up a design whose primitives the tile
# model does not cover yet.
VERIFY ?= 1
VERIFY_DIR ?= .verify
TILEVERILOG ?= $(F2N_DIR)/build/tileverilog
LVS_EQUIV ?= $(F2N_DIR)/build/lvs_equiv

help:
	@printf '%s\n' 'Targets:' \
	  '  make setup                              Create the local Python environment' \
	  '  make tools                              Build Project X-Ray conversion tools' \
	  '  make vc707-johnson PRJXRAY_DB=...        Build VC707 Johnson from source to raw bitstream' \
	  '  make sonata FASM=... PRJXRAY_DB=...     Convert an Artix-7 FASM to Sonata UF2' \
	  '  make vc707 VC707_FASM=... PRJXRAY_DB=... Convert a Virtex-7 FASM to raw bitstream' \
	  '  make validate-bitstream PART=... BIT=... TESTBENCH=... PRJXRAY_DB=...' \
	  '  make fasm2netlist                       Build the FASM-to-netlist extractor' \
	  '  make lvs                                LVS-check the extraction against the placement' \
	  '  make z3-prove                           Prove extraction == gold synthesis with Z3' \
	  '  make sat-match                          Match registers with no placement oracle' \
	  '  make verify-extraction V_*=...          Extract a bitstream and prove it equals its synthesis' \
	  '' \
	  'Examples verify themselves by default; pass VERIFY=0 to skip that step.'

setup:
	python3 -m venv .venv
	cd prjxray && $(PYTHON) -m pip install -r requirements.txt -e third_party/fasm
	$(PYTHON) -m pip install z3-solver

tools:
	cmake -S prjxray -B prjxray/build -DCMAKE_BUILD_TYPE=Release
	cmake --build prjxray/build --target bitread xc7frames2bit --parallel 4

nextpnr:
	@test -n "$(PRJXRAY_DB)" && test -d "$(PRJXRAY_DB)" || { echo "PRJXRAY_DB must name a Project X-Ray database checkout"; exit 2; }
	cmake -S $(NEXTPNR_DIR) -B $(NEXTPNR_BUILD) -DARCH=himbaechel -DHIMBAECHEL_UARCH=xilinx \
		-DBUILD_GUI=OFF -DBUILD_PYTHON=OFF -DHIMBAECHEL_XILINX_DEVICES="xc7a50t;xc7vx485t" \
		-DHIMBAECHEL_PRJXRAY_DB=$(PRJXRAY_DB)
	cmake --build $(NEXTPNR_BUILD) --target nextpnr-himbaechel --parallel 4

vc707-johnson: tools nextpnr
	@command -v "$(YOSYS)" >/dev/null || { echo "YOSYS not found: $(YOSYS)"; exit 2; }
	cd $(VC707_DIR) && $(YOSYS) -p 'synth_xilinx -flatten -abc9 -nobram -arch xc7 -top top; write_json johnson.json' top.v counter25_core.v
	$(NEXTPNR_BIN) --device $(VC707_PART) -o xdc=$(VC707_DIR)/top.xdc --json $(VC707_DIR)/johnson.json \
		-o fasm=$(VC707_DIR)/johnson.fasm -o placement=$(VC707_DIR)/johnson_placement.json --router router2
	$(MAKE) vc707 VC707_FASM=$(VC707_DIR)/johnson.fasm PRJXRAY_DB=$(PRJXRAY_DB) VC707_OUT=$(VC707_OUT)
ifeq ($(VERIFY),1)
	$(MAKE) verify-extraction V_NAME=vc707-johnson V_FASM=$(VC707_DIR)/johnson.fasm \
		V_JSON=$(VC707_DIR)/johnson.json V_PLACE=$(VC707_DIR)/johnson_placement.json \
		V_XDC=$(VC707_DIR)/top.xdc V_TOP=top V_PART=$(VC707_PART) \
		V_DEVICE=$(VC707_DEVICE) V_FAMILY=$(VC707_FAMILY) PRJXRAY_DB=$(PRJXRAY_DB)
endif

sonata:
	@test -x "$(PYTHON)" || { echo "Run 'make setup' first"; exit 2; }
	@test -n "$(FASM)" || { echo "FASM must name an existing implementation output"; exit 2; }
	@test -f "$(FASM)" || { echo "FASM not found: $(FASM)"; exit 2; }
	@test -n "$(PRJXRAY_DB)" && test -d "$(PRJXRAY_DB)" || { echo "PRJXRAY_DB must name a Project X-Ray database checkout"; exit 2; }
	$(PYTHON) scripts/convert.py --arch xilinx --family xc7 --board sonata \
		--part $(PART) --db $(PRJXRAY_DB) --fasm $(FASM) --output $(OUT)

vc707:
	@test -x "$(PYTHON)" || { echo "Run 'make setup' first"; exit 2; }
	@test -n "$(VC707_FASM)" || { echo "VC707_FASM must name an existing VC707 implementation output"; exit 2; }
	@test -f "$(VC707_FASM)" || { echo "VC707_FASM not found: $(VC707_FASM)"; exit 2; }
	@test -n "$(PRJXRAY_DB)" && test -d "$(PRJXRAY_DB)" || { echo "PRJXRAY_DB must name a Project X-Ray database checkout"; exit 2; }
	$(PYTHON) scripts/convert.py --arch xilinx --family xc7 \
		--part $(VC707_PART) --db $(PRJXRAY_DB) --fasm $(VC707_FASM) --output $(VC707_OUT)

validate-bitstream:
	@test -x "$(PYTHON)" || { echo "Run 'make setup' first"; exit 2; }
	@test -n "$(BIT)" && test -f "$(BIT)" || { echo "BIT must name an existing XC7 bitstream"; exit 2; }
	@test -n "$(TESTBENCH)" && test -f "$(TESTBENCH)" || { echo "TESTBENCH must name an existing Verilator testbench"; exit 2; }
	@test -n "$(PRJXRAY_DB)" && test -d "$(PRJXRAY_DB)" || { echo "PRJXRAY_DB must name a Project X-Ray database checkout"; exit 2; }
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
	@test -d .deps/prjxray-db || { echo "run 'make vc707-johnson PRJXRAY_DB=...' first: the checks read .deps/prjxray-db"; exit 2; }
	$(PYTHON) $(F2N_DIR)/tests/lvs/test_johnson_lvs.py --exe $(F2N_BIN) \
		--xc7-tools-dir $(CURDIR) --family $(VC707_FAMILY) --device $(VC707_DEVICE)

z3-prove: fasm2netlist
	@test -d .deps/prjxray-db || { echo "run 'make vc707-johnson PRJXRAY_DB=...' first: the checks read .deps/prjxray-db"; exit 2; }
	$(PYTHON) $(F2N_DIR)/tests/lvs/prove_z3_sop_equiv.py --exe $(F2N_BIN) \
		--xc7-tools-dir $(CURDIR) \
		--family $(VC707_FAMILY) --device $(VC707_DEVICE) --part $(VC707_PART)

sat-match: fasm2netlist
	@test -d .deps/prjxray-db || { echo "run 'make vc707-johnson PRJXRAY_DB=...' first: the checks read .deps/prjxray-db"; exit 2; }
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
	@test -n "$(PRJXRAY_DB)" && test -d "$(PRJXRAY_DB)" || { echo "PRJXRAY_DB must name a Project X-Ray database checkout"; exit 2; }
	@command -v "$(YOSYS)" >/dev/null || { echo "YOSYS not found: $(YOSYS)"; exit 2; }
	@mkdir -p $(VERIFY_DIR)/$(V_NAME)
	$(TILEVERILOG) --fasm $(V_FASM) --db $(PRJXRAY_DB)/$(V_FAMILY) --device $(V_DEVICE) \
		--xdc $(V_XDC) --part $(V_PART) \
		--out $(VERIFY_DIR)/$(V_NAME)/fabric.v --model-out $(VERIFY_DIR)/$(V_NAME)/tile_model.v
	$(TILEVERILOG) --fasm $(V_FASM) --db $(PRJXRAY_DB)/$(V_FAMILY) --device $(V_DEVICE) \
		--xdc $(V_XDC) --part $(V_PART) --placement $(V_PLACE) --gold-json $(V_JSON) \
		--out $(VERIFY_DIR)/$(V_NAME)/fabric_named.v
	$(YOSYS) -q -p "read_json $(V_JSON); hierarchy -top $(V_TOP); splitnets; \
		select $(V_TOP); write_verilog -noattr -selected $(VERIFY_DIR)/$(V_NAME)/gold.v"
	$(LVS_EQUIV) --gold $(VERIFY_DIR)/$(V_NAME)/gold.v --gold-top $(V_TOP) \
		--gate $(VERIFY_DIR)/$(V_NAME)/fabric.v --gate-top fabric \
		--placement $(V_PLACE) --gold-json $(V_JSON) \
		--db $(PRJXRAY_DB)/$(V_FAMILY) --device $(V_DEVICE) --quiet

clean:
	rm -rf .validation $(VERIFY_DIR)
	rm -f *.bit *.frames *.uf2
	rm -f $(VC707_DIR)/johnson.json $(VC707_DIR)/johnson.fasm