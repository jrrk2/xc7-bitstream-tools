# HP 2000F bitstream assets: the three things the SoC's ROM embeds, built from
# HP's copyright sources (fetched from Bitsavers, never committed) by the repo's
# `make vc707-hp2000` target before it runs the LiteX generator.
#
#   make bios-assets    fetch the HP sources and assemble:
#                          build/iss_rom.0.seg   the 2883 disc boot ROM (boot/iss_rom.asm)
#                          build/iop_brk.2.seg   the IOP program, BREAK-at-INPUT patched
#                          build/tape.hex        the system tape for hp_sysgen (photoreader)
#   make clean          remove build/ and the fetched sources
#
# The machine itself, the emulator and the disc-image tooling live in ~/hp2000;
# this directory holds only what a bitstream build needs.

.PHONY: bios-assets fetch-source clean

# HP sources -> src/*.asm (fetch_sources.sh regenerates them on every run, and
# downloads the pinned Bitsavers tarball once).
src/tsb_f_system.asm src/tsb_f_iop.asm:
	tools/fetch_sources.sh

fetch-source:
	tools/fetch_sources.sh

# One hpasm run emits PREFIX.N.seg per program (0-based) -- the suffixes below
# are the ones ~/hp2000's Makefile already relies on.
build/%.1.seg build/%.2.seg: src/%.asm tools/hpasm.py
	@mkdir -p build
	python3 tools/hpasm.py $< -o build/$*

build/iss_rom.0.seg: boot/iss_rom.asm tools/hpasm.py
	@mkdir -p build
	python3 tools/hpasm.py $< -o build/iss_rom

build/iop_brk.2.seg: src/tsb_f_iop.asm tools/patch_iop_break.py tools/hpasm.py
	@mkdir -p build
	python3 tools/patch_iop_break.py src/tsb_f_iop.asm build/iop_brk.asm
	python3 tools/hpasm.py build/iop_brk.asm -o build/iop_brk

build/tsb_f_system.tap: build/tsb_f_system.1.seg tools/mktape.py
	python3 tools/mktape.py $@ build/tsb_f_system.1.seg

build/tape.hex: build/tsb_f_system.tap
	python3 -c "d=open('build/tsb_f_system.tap','rb').read(); open('build/tape.hex','w').write('\n'.join('%02x'%b for b in d)+'\n')"

bios-assets: build/iss_rom.0.seg build/iop_brk.2.seg build/tape.hex

clean:
	rm -rf build src tsb_src lib __pycache__
