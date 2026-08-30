.PHONY: help setup tools nextpnr vc707-johnson sonata vc707 validate-bitstream clean
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

help:
	@printf '%s\n' 'Targets:' \
	  '  make setup                              Create the local Python environment' \
	  '  make tools                              Build Project X-Ray conversion tools' \
	  '  make vc707-johnson PRJXRAY_DB=...        Build VC707 Johnson from source to raw bitstream' \
	  '  make sonata FASM=... PRJXRAY_DB=...     Convert an Artix-7 FASM to Sonata UF2' \
	  '  make vc707 VC707_FASM=... PRJXRAY_DB=... Convert a Virtex-7 FASM to raw bitstream' \
	  '  make validate-bitstream PART=... BIT=... TESTBENCH=... PRJXRAY_DB=...'

setup:
	python3 -m venv .venv
	cd prjxray && $(PYTHON) -m pip install -r requirements.txt -e third_party/fasm

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
		-o fasm=$(VC707_DIR)/johnson.fasm --router router2
	$(MAKE) vc707 VC707_FASM=$(VC707_DIR)/johnson.fasm PRJXRAY_DB=$(PRJXRAY_DB) VC707_OUT=$(VC707_OUT)

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

clean:
	rm -rf .validation
	rm -f *.bit *.frames *.uf2
	rm -f $(VC707_DIR)/johnson.json $(VC707_DIR)/johnson.fasm