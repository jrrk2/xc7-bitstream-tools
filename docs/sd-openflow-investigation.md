# Why the SD card works through Vivado and not through the open flow

State as of 2026-09-07 evening.  The open-flow bitstream boots Linux with
interrupts, DDR3 and ethernet; the SD card fails to initialise.  The same
RTL through Vivado drives the card fine.  Both bitstreams are saved under
~/vc707-artifacts/2026-09-07-smpsd/, with docs/artifacts-2026-09-07.md
pointing at them.

## The finding

For every SD pad, Vivado configures the OLOGIC output and tristate path:

    LIOI_X82Y10.OLOGIC_Y0.OMUX.D1
    LIOI_X82Y10.OLOGIC_Y0.OQUSED
    LIOI_X82Y10.OLOGIC_Y0.OSERDES.DATA_RATE_TQ.BUF
    LIOI_X82Y10.OLOGIC_Y0.ZINV_T1
    ... and the same for OLOGIC_Y1, X82Y12 both halves, and
        LIOI_TBYTESRC_X82Y8.OLOGIC_Y1

The open flow emits 53 entries across those three tiles and every one of
them is ILOGIC.  Not a single OLOGIC feature.  The input side of the pads
is configured and the output and tristate sides are not.

That fits the measured behaviour better than any bit-level theory.
Driving the core by hand through /dev/mem: CMD0, CMD8 and CMD55 all
return event=DONE with no timeout and no CRC error, and the response
register reads zero every time.  The event register reads DONE before any
command is issued at all.  Nothing is being transacted, because the pins
are inert rather than misconfigured.

nextpnr does configure OLOGIC with ZINV_T1 for the DDR3 pins on the right
side (36 RIOI tiles), and DDR3 works, so the uarch can do this.  Whatever
is missing is specific to how these SD pads were packed.

## What has been ruled out

Two hypotheses tested and rejected, both by experiment rather than
argument:

**The IOB input-enable bit.**  bit2fasm on both bitstreams shows the SD
IOB tiles differ in exactly one physical bit, 38_126, on X81Y10 and
X81Y12.  Patched into the FASM and rebuilt (openxc7-smpsd-indiff.bit,
saved); flashed; the card still fails identically.  Not the cause.

**ZINV_T1 alone.**  Vivado sets it on five left-side tiles the open flow
leaves clear -- but the open flow sets it on 36 right-side DDR3 tiles
where Vivado does not, and DDR3 works in both.  Inverting T in the
driving LUT and inverting it in the OLOGIC are equivalent, so the bit is
only meaningful together with the logic feeding it.  patched2.fasm
carries this experiment; the bitstream had not finished converting.

**A methodological correction worth keeping.**  The first diff compared
nextpnr's generated FASM against a bit2fasm extraction.  Those are not
comparable: nextpnr lists what it chose to write, bit2fasm lists every
feature whose bit pattern matches, and several of these features are
defined with negated bits, so bit2fasm reports phantoms.  That produced a
confident and wrong claim that sdcard_cmd's input buffer was disabled.
Comparing both bitstreams through bit2fasm showed the cmd tile is in fact
bit-identical between the two flows.  Always compare like with like.

## Where to pick up

The SD pads carry no OLOGIC configuration, so the next question is why:
whether the packer never assigned an OLOGIC bel for a plain bidirectional
IOBUF, or assigned one and fasm.cc skipped emitting it.  Start in
nextpnr/himbaechel/uarch/xilinx/ -- pack_io.cc for the assignment and
fasm.cc for the emission -- and compare against how the DDR3 pads, which
do get OLOGIC, differ.  The generated SoC verilog has no explicit IOBUF
or ODDR on the sdcard signals, so the pads come from inference rather
than instantiation, which is the likely dividing line.

The fast experiment loop, worth reusing: patch the FASM by hand, run
scripts/convert.py (minutes), flash, and let the BIOS boot_sequence come
up on its own.  That beats a 40-minute nextpnr rebuild per hypothesis.
The board can then be examined over ssh with no console: "ssh vc707",
key auth, /dev/mem present for reading CSRs with busybox devmem.
