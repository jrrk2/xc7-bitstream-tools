# The open Linux FPGA flow: what to do next, in order

Linux 5.0.13 with an MMU boots to a buildroot root shell on a VC707 whose
bitstream was produced entirely by open tools -- yosys, nextpnr-himbaechel and
prjxray, no Vivado anywhere in the path.  DDR3 calibrates and passes memtest,
the SGMII link comes up, and the SoC netboots over TFTP.  Linux itself has no
network interface: the BIOS does the netboot, and the kernel comes up without a
NIC.

This is the order to build on that, and why each step sits where it does.

## Three findings that set the order

**The baseline is not reproducible by any command in this repository.**  The
kernel and rootfs now booting are f4pga-examples artifacts (Linux 5.0.13,
Buildroot 2020.02).  `LINUX_IMAGES` has no default and names a directory
outside the tree; nothing here can rebuild them.  Releasing them is
preservation, not packaging, which is why it leads.

*Being fixed.*  f4pga is a VPR flow -- a different place-and-route tool
altogether -- so there was never a shared lineage with this one; two prebuilt
binaries were the whole of the dependency.  With `linux-deps/linux` and
`linux-deps/buildroot` pinned here, both are built from this checkout and the
f4pga reference is retired.  It survives only in the known-good snapshot's
PROVENANCE, as a record of where the first booting image came from.

**Ethernet under Linux needs no gateware change.**  The SoC already exposes
everything `litex_liteeth` binds to: the `ethmac` CSR bank at `0xf0001800` and
its buffers at `0x80000000` (rx) and `0x80001000` (tx), 4096 bytes each.  The
device tree has no MAC node and the kernel has no driver -- both are software.

**The kernel now booting cannot drive our ethernet, and the reason is not the
driver.**  It has one: `litex,liteeth` is in the Image, along with liteuart,
gpio, pwm, spiflash, litespi, i2c and xadc -- it is a litex-hub tree, not a
stock 5.0.13.  Adding a device tree node makes `eth0` appear with no kernel
and no gateware rebuild, and the MAC receives: `writer_length` reads 232 with
`ev_pending` set.

What it cannot do is read that register.  `LITEX_SUBREG_SIZE` is compile-time,
and that kernel is built for Arty's 8-bit CSR bus while this SoC is 32-bit
("CSR: 32-bit data big ordering").  So `litex_read32` gathers four
consecutive words and concatenates their low bytes -- length, errors,
ev_status, ev_pending -- into `0xE88D0101`, and tries to allocate 3.9 GB for
every empty poll.  The UART survives the mismatch only because `rxtx` is
8 bits, where both layouts land on the same address.

`~/sonata-linux/linux-xip` is Linux 6.9.0 with `LITEX_SUBREG_SIZE 0x4`, which
matches this SoC, and carries `litex_mmc.c` as well -- which 5.0.13 genuinely
does lack.  So "localise the image repositories" is not tidying that can
happen whenever: it *is* the kernel migration, and ethernet and SDIO are both
downstream of it.

"Identical results in GitHub" is not a stage at all; it is the gate on every
stage, and it needs a definition before it can gate anything.

---

## 1. Keep a copy of what booted

**Why first.**  Not a release -- somewhere to come back to when a change
breaks something.  Most of it cannot be rebuilt, so if it is lost it is lost.

**Done**, at `~/xc7-vc707-known-good/2026-09-06-linux/`: the bitstream, the
four payload files, `SHA256SUMS`, and a `PROVENANCE` note recording the
submodule and database revisions it was built against, that the kernel and
rootfs are f4pga artifacts no target here can rebuild, that the emulator and
the dtb encode this bitstream's CSR addresses so the five files move
together, and how to flash and serve it again.

Kept outside the checkout: 28 MB of binaries do not belong in git.

## 1a. A release someone else can use -- later, and separately

**An interim FPGA-only release exists**, at `~/xc7-vc707-release/fpga-6a21aff/`:
the bitstream, `csr.json`, `io.fasm`, the timing table, and a README recording
the commit, all 14 submodule revisions and the database revision it was built
from, plus the two `diff` commands that verify a rebuild.  The kernel and
rootfs are deliberately absent -- bundling artifacts this repository cannot
rebuild would make a release that is mostly not reproducible.

What remains below is the rest, and it is not urgent.  What it needs beyond the
snapshot is portability, because the board's addresses are compiled in:

- **BOOTP/DHCP, so no address is baked into the bitstream.**  Two gaps, both
  small:
  - The SoC never asks.  `dynamic_ip` is not passed, so `ETH_DYNAMIC_IP` is
    off and even the existing `eth_dhcp` command is not compiled in.  Turning
    it on replaces `--local-ip` (LiteX rejects both together).
  - Upstream learns only half of what DHCP tells it.  `dhcp_resolve()` returns
    `yiaddr` and nothing else, though the packet struct already carries
    `siaddr` -- the BOOTP next-server -- and `dhcp_get_u32_option()` is right
    there for option 66.  Return it, and have `boot.c` prefer it over the
    compiled-in remote.  Upstreamable to LiteX.

  **The hub cannot supply a boot server, so this host must answer too.**  A
  consumer hub does DHCP but knows nothing about TFTP, so two servers answer
  the same DHCPDISCOVER and the board has to pick.  It currently cannot:
  `dhcp.c:287` accepts the first offer whose transaction ID matches, without
  asking whether the offer is of any use.

  The discriminator needs no vendor class and no coordination -- *an offer
  carrying no boot server is not for us*.  Read `siaddr`, fall back to option
  66, and if both are empty ignore the offer and keep waiting.  The hub
  disqualifies itself on its own merits, and on a network whose DHCP server
  does set next-server, the same code just works.  The protocol handles the
  rest: `dhcp.c:211` puts `server_id` into the DHCPREQUEST, so the hub sees a
  request naming another server and withdraws.

  Server side is `scripts/dhcp_serve.py` beside `tftp_serve.py`, both behind
  one `make netboot-serve`.  It answers only known MACs, and hands out a fixed
  address per MAC that must sit *outside* the hub's pool.  Port 67 needs root
  or `CAP_NET_BIND_SERVICE`.

- `LINUX_TFTP_DIR` hardcodes `10:e2:d5:00:00:07`; derive it from
  `--mac-address`.
- A tag-triggered workflow that publishes it.

**Done when** a machine with no checkout, on a network that is not ours, can
flash and boot from the release assets alone.

## 2. Lock down what already works

**Why here.**  The two-machine ARP divergence is not a side quest, it is
evidence that this result is not yet reproducible.  `make vc707-litex-linux`
from clean has never been verified end to end -- the booting bitstream came
from hand-run commands -- and `build-linux.yml` has never once executed.  With
stage 1 done, there is now a released artifact to reproduce *against*.

- Commit the `prjxray-db` pin (`scripts/prjxray_db.sh`, `PRJXRAY_DB_REV`,
  `make prjxray-db`).  Written and tested, uncommitted.
- Push the superproject and its branches.  The second machine builds from an
  older superproject commit, which is what records every submodule SHA.
- Resolve the macOS divergence by comparing the XDC-pinned I/O FASM lines
  between hosts.  Whole-file FASM differs legitimately; the I/O lines must not.
- Run `make vc707-litex-linux` from clean and boot the result.

**Done so far.**  A from-scratch rebuild at `6a21aff` -- the commit HEAD was at
when the known-good bitstream was written -- was flashed and booted Linux to a
buildroot root shell.  It booted the *previous day's* emulator and dtb
unchanged, because the CSR map did not move: `csr.json` differed only in
`constants.config_identifier`, which carries the build timestamp.  DDR3
calibrated, memtest passed at 62.1/64.3 MiB/s, the link came up, the SoC
netbooted.

That is the reproducibility that matters, and it holds.  The bitstream itself
did not match byte for byte, and cannot -- see the contract.

**Still open**: the macOS divergence.  Every declared input is now verified
identical between the two hosts -- all 14 submodules, and `prjxray-db` at
`5099b9e` -- so what remains is the host toolchain.  The outstanding
measurement is the Mac's `io.fasm` against this host's.

**Done when** the two hosts agree on `csr.json` and `io.fasm`, and both boot.

## 3. The canonical boot message, as a test

**Why here.**  Stage 1 captured the transcript; stage 2 made builds repeatable.
Only now can a diff mean something.  It must exist before the kernel jump, so
the migration has a baseline to be judged against.

- Compare with volatile fields masked: BIOS build date (`bios/main.c:214`
  compiles in `__DATE__`/`__TIME__`), DDR3 delay taps, MAC and IP, timing
  figures.
- `make vc707-litex-linux-check` drives it over the UART at 115200.

**Done when** a boot either matches the golden transcript or prints a diff.

## 4. Localise the image repositories

**Why here.**  Everything remaining needs a kernel that is ours to change, and
now there is a release to fall back to and a test to detect breakage.

- Add `linux-deps/` as pinned submodules, mirroring `litex-deps/`, from the
  working set in `~/sonata-linux`:

  | repository | pin | branch |
  |---|---|---|
  | `buildroot` | `aa98f08` | `sonata` |
  | `linux-xip` | `af93851` | `rv32-sonata-litex` (6.9.0) |
  | `litesdcard` | `80a3004` | 2025.12 |
  | `linux-on-litex-vexriscv` | `9817acd` | `sonata` |

  All four pins are reachable on their remotes, so nothing here is local-only.
  Two things about *how* they are added, both cheaper decided now:

  - **URLs must be `https://`.**  sonata-linux records three of the four as
    `git@github.com:` , which works for one account and fails for CI and for
    anyone else cloning.  Every submodule in this repository is already
    `https://`; these follow that, and pushing stays a local rewrite rule.
  - **1.6 GB of that is `linux-xip`.**  Hanging it off every clone, and every
    CI job doing `submodules: recursive`, is a real cost.  Prefer a
    `--filter=blob:none` fetch, or keep the kernel out of the submodule set
    and fetch it only in the image-build target.

- `make linux-images` builds `Image` and `rootfs.cpio` from the pinned
  buildroot and becomes the default for `LINUX_IMAGES`.
- Keep the 5.0.13 release as the known-good reference until 6.9 boots.

**Done when** `make linux-images` from clean produces a bootable image with no
path outside the repository.

**Risk.**  An rv32 buildroot build is hours, not minutes -- which is why the
artifacts are release assets rather than something CI rebuilds.

## 5. Ethernet under Linux

**Why here.**  Needs the 6.9 kernel from stage 4 and the baseline from stage 3.
It needs no gateware, which makes it the first stage that adds a capability
rather than securing one.

- Device tree gains an `ethernet@f0001800` node: `compatible = "litex,liteeth"`,
  `reg` covering the CSR bank plus the rx/tx buffers.
- No `fixed-link`, and no PHY handling of any kind.  The driver never
  registers an MDIO bus or attaches phylib -- `liteeth_open()` simply calls
  `netif_carrier_on()`.  The earlier plan to declare a fixed link was wrong.
- No `interrupts` either, at least at first: `platform_get_irq()` failing sets
  `use_polling`, and a 50 ms timer removes any dependence on getting the 6.9
  interrupt controller right before the datapath works.
- Note LiteX's own `litex_json2dts_linux.py` emits *no* ethernet node for this
  SoC: it is gated on an `ethphy` CSR, which a black-box PHY does not have.
  The node has to be written by hand, or that generator taught about PHYs it
  cannot see.
- MAC address plumbed from the SoC rather than assumed.

**Risk.**  The kernel jump is the real work, not the driver.
`irq-litex-vexriscv.c` must suit a SoC with neither a CLINT nor a PLIC, and the
stage 3 golden transcript has to be rebased onto 6.9.

**DONE.**  Linux 6.9 on the open-flow bitstream, ethernet working both ways:

    liteeth f0001800.mac eth0: irq 0 slots: tx 2 rx 2 size 2048
    64 bytes from 192.168.1.106: seq=0 ttl=64 time=35.028 ms

and from the host, 3/3 with the neighbour entry REACHABLE.  The interface also
picked up a global IPv6 address by SLAAC without being asked, which is
independent evidence the receive path works rather than just the ping.

It needed no gateware, as predicted.  What it did need was the kernel: the
5.0.13 image has the driver but is compiled for an 8-bit CSR bus, and the
2020 userspace predates the time32/time64 split so its libc calls syscall 73
(`ppoll`), which riscv32 does not have.  Both were fixed by building rather
than patching -- see `examples/vc707-litex-linux/kernel/` and `rootfs/`.

Two things left on the interface itself, neither blocking:

- It polls.  `platform_get_irq()` fails because no interrupt controller is
  described, so the driver falls back to a 50 ms timer.  Latency is 7-16 ms
  round trip against a host on the same switch.  Wiring the interrupt would
  need `irq-litex-vexriscv` and a DT node.
- `syslogd` takes a SIGSEGV at startup -- a word store to 0x13 inside busybox,
  `cause: 0x0f`.  The boot survives it and continues, but it is a real defect
  and may be a busybox/glibc rv32 interaction rather than a one-off.

## 6. Four-bit SDIO for mass storage

**Why last.**  It is the only stage that changes the gateware, on a design that
already carries the MMU CPU, 99 DDR3 serialisers and a transceiver, and that
only closes timing with `--placer-heap-timingweight 60`.

- The pins already exist in the VC707 platform: `sdcard` with `clk` AN30,
  `cmd` AP30, `data` AR30/AU31/AV31/AT30, `det` AP32, `wp` AR32, all LVCMOS18.
  Four data lines, so 4-bit width needs no new pin work.
- Generator gains `--with-sdcard` (LiteSDCard), adding CSRs and DMA.
- Kernel side is `litex_mmc.c`, present in 6.9, plus a device tree node.

**Risk.**  This is the stage that can break timing closure.  Budget placement
work, not just integration.

**Done when** a filesystem mounts off the card at 4-bit width.

**But mounting is not the goal.**  The point of mass storage here is
self-hosting -- running nextpnr on the board to bootstrap its own bitstream --
and that changes what stage 6 has to deliver:

- **Root on SD, not an initramfs.**  Everything today unpacks into RAM, so the
  rootfs competes with the working set.  A toolchain cannot live there.
- **Swap on SD.**  A 100 MHz rv32 doing place-and-route will need it, and it
  is the cheapest way to survive a peak that exceeds DRAM.
- The 1 GiB variant is optional for the flow but probably not for this: it
  stays optional, and self-hosting is the argument for attempting it.

Sizing, so the ambition is checked against arithmetic rather than hope.
nextpnr needs 142 MB before it sees a design -- 74.9 MB of chipdb for
xc7vx485t plus a 67.3 MB binary -- against 512 MiB now.  Peak RSS during
place-and-route of the Linux SoC is the figure that decides feasibility and
has never been measured; record it (`/usr/bin/time -v`) on the next run.

Worth separating two ambitions that sound alike: *running* a prebuilt nextpnr
on the board is a memory question, and plausible at 1 GiB with swap.
*Building* nextpnr there is harder -- C++ template instantiation peaks in the
gigabytes per translation unit.

On a VexRiscv rv32ima at 100 MHz that is about two orders of magnitude slower
than one host core, not three; a Rocket RV64 would be at the better end of
that.  But speed is the smaller obstacle.  **rv32 caps user address space at
around 3 GiB**, and a translation unit that wants more than that does not
compile slowly -- it does not compile.  Swap does not help, because the limit
is address space rather than memory.

So native compilation is an argument for a 64-bit core rather than for more
RAM, and that is a much larger change than stage 6: Rocket is a far bigger
design than VexRiscv, on a flow that only just closes timing with the CPU we
have.  The nearer path is cross-compiled binaries on the card, with native
*running* as the target and native *building* left as a separate question.

---

## The reproducibility contract

**The goal is identical place-and-route results between platforms.**  Where
nextpnr does not deliver that, the cause is nondeterministic container
iteration -- a bug class to be fixed, not a property to design around.

**But the near-term gate cannot be the whole FASM, and this was measured.**
Three builds from identical inputs, identical flags, on one machine produced
three different fabrics, differing in thousands of `INT_R`/`INT_L`
interconnect and `CLBLM` logic lines and in total line count.  This host does
not agree with itself, so "this host and GitHub agree on the whole FASM" is
unreachable rather than merely unmet.

What *is* reproducible was measured in the same experiment, and is what CI
asserts:

1. **`csr.json` identical**, except `constants.config_identifier` which
   carries the build timestamp.  This is the SoC's register map -- the
   contract the emulator and the device tree depend on.  It is what let a
   rebuilt bitstream boot the previous day's payload unchanged.
2. **`io.fasm` identical** -- every `LIOB18`/`RIOB18`/`LIOI`/`RIOI` line,
   sorted.  Byte-identical across all three runs despite the fabric churn
   beneath it, and identical between the Linux and non-Linux variants of this
   SoC, so it is a property of the board and its peripherals rather than of
   one run.  This is the check that would have caught a dead RX path.
3. **Software binaries identical** modulo the compiled-in `__DATE__`/`__TIME__`
   (`bios/main.c:214`).  Compare sizes and date-masked content, never raw
   hashes.
4. **Every clock at or above its constraint** on setup.  Hold is excluded
   deliberately: this flow's hold STA reports violations on designs that
   demonstrably run, which is why the target passes `--timing-allow-fail`.
5. **The extraction sweep unchanged** -- proved/differ counts from
   `verify_examples.sh`.
6. **Every input pinned**: all submodules, plus `PRJXRAY_DB_REV`.

A rebuilt `.bit` differing from a released one is expected and is not a
regression.  Saying so is part of the contract, because the alternative is
chasing it.

**The database is the deliberate exception, and it runs on two tracks.**  CI
tracks the *tip* of prjxray-db, because noticing the day upstream changes
which bits a FASM line sets is the point of running it there; the revision
check reports the difference in one line and carries on.  The pin is what
makes a *release* reproducible, and there the same check fails the build.

So a CI result and a local result are comparable only when the database
revisions agree, and CI prints which one it used.  The first run of this check
found the runner on `6b8695ea3456` against `5099b9e` here, so every CI result
before it was quoted against a database nobody had recorded.

## Open items carried alongside

- `main_ram` 512 MiB -> 1 GiB: **an optional variant, not a step.**  It
  perturbs the layout of the I/O blocks, which is medium risk on the design
  that is already hardest to close, and it moves the `io.fasm` signature that
  the contract above uses as its reproducibility check -- so that variant
  needs its own baseline rather than sharing this one.

  Nothing on the critical path should depend on it.  If it is attempted, do it
  alongside stage 6 so there is one place-and-route rather than two, and treat
  a timing regression as a reason to drop it rather than to chase it.

  Note it is *not* needed to fix the two things currently sized for 512 MiB:
  the `STRICT_KERNEL_RWX` trade below is already wrong at 512, and the payload
  addresses (rootfs 8 MiB above the kernel, inherited from a 4.6 MB kernel)
  can move today.
- The `.IN` both-halves-input case on `LIOB18_X81Y81` is worked around by
  driving the PHY management pins, not fixed.  A collaborator offered to take it.
- `create_pblock` region support was offered too; valuable for ingesting Vivado
  constraints, not as a timing fix -- clock LOCs measurably made timing worse
  here (60.0 vs 91.3 MHz).
- **nextpnr placement is not deterministic, even on one machine.**  Measured:
  three builds, identical inputs and flags, three different fabrics.  Not a
  cross-platform quirk -- a property of the tool.  Closing it is what makes
  the contract's stated goal reachable; likely culprits are pointer-keyed or
  hash-ordered containers whose iteration order feeds placement.
- `build-linux.yml` has never run.  Hosted runners may not have the memory or
  the time for this design; stage 2 finds out.
