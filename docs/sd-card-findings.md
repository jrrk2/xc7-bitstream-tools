# SD card on the VC707: what was actually wrong

Working, as of the VexRiscv-SMP + OpenSBI build: 4-bit SDIO at 25 MHz,
3.3 V, both partitions readable and writable, verified by md5 round-trip
of 10.9 MB written from the host and read back on the card.

    mmc0: new SDHC card at address aaaa
    mmcblk0: mmc0:aaaa SL32G 29.7 GiB
     mmcblk0: p1 p2

## The cause was the card

Not the encoding, not the open-vs-Vivado flow, not interrupts, not DMA
coherency.  A full-size SDHC card failed identification; a micro-SDHC in
the same slot, on the same bitstream, enumerated immediately.  Everything
else had already been eliminated: CVA6 drove the same pins with the same
LVCMOS18 constraints in SPI mode and read the GPT and both partitions, so
pins, I/O standard, slot and wiring were never in question.

## Diagnoses that were wrong along the way

**"The card-detect line is lying."**  It is not.  SD_PHY_CARD_DET reads
0x00000000 -- inserted -- and get_cd always reported the card present.
The silence in dmesg came from mmc_rescan failing quietly, as it does for
a removable card, and retrying; "power off, clock 0" in
/sys/kernel/debug/mmc0/ios is the state *between* retries, not evidence
that nothing was attempted.  Setting non-removable did not fix a broken
detect line, it made an existing failure print a message.

**"The gateware needs --with-coherent-dma."**  The driver header says it
is required, and it is not: the driver allocates its buffer with
dma_alloc_coherent, which yields uncached memory on a non-coherent
system.  Everything above works on a bitstream built without the flag.
The build with it exists in build-smpsd-dma-vivado and is unused.

Coherent DMA also cannot explain the original failure, which happened
during card identification at CLK_DIV 0x100 (100 MHz / 256 = 390 kHz) in
1-bit mode -- short command responses, no DMA involved at all.  That
matches the BIOS looping forever on ACMD41: the same failure, in the same
place, in both the BIOS and Linux.

## Transport, measured

Timing anything on this machine has to be done on-device with nothing
else running.  A uniprocessor at 100 MHz cannot host a benchmark and an
sshd at the same time; polling for results over ssh while a test runs
moved a write measurement between 124 and 355 KB/s.

    raw TCP (iperf3)   7.8 Mbit/s, 0 retransmits
    ssh pipe           ~1.2 Mbit/s   -- sshd crypto costs about 6x
    busybox tftp       ~0.45 Mbit/s  -- 2.6x slower than ssh

TFTP loses despite doing no crypto because it is lock-step: 512-byte
blocks, one ACK each, no windowing.  At the measured 8.2 ms RTT, 32768
blocks come to ~288 s, which is what it takes.  It is round-trip-bound,
not CPU-bound, and it is why netboot of an 11 MB payload is slow.

## Worth trying next

Reads beat writes by an order of magnitude, and 64 KB blocks beat 1 MB
in both directions.  That inversion matches max_blk_count = 128 in the
driver: 128 x 512 B = 64 KB per request, so a 1 MB request is split into
sixteen, each with its own bounce-buffer copy.  Raising max_blk_count is
the obvious experiment -- but re-measure cleanly first, detached, with no
ssh session in the loop.
