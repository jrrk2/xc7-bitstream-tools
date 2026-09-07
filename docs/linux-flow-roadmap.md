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

**Ethernet under Linux needs no gateware change.**  The SoC already exposes
everything `litex_liteeth` binds to: the `ethmac` CSR bank at `0xf0001800` and
its buffers at `0x80000000` (rx) and `0x80001000` (tx), 4096 bytes each.  The
device tree has no MAC node and the kernel has no driver -- both are software.

**The kernel now booting cannot host either new driver.**  5.0.13 contains
neither `litex_liteeth.c` nor `litex_mmc.c`.  `~/sonata-linux/linux-xip` is
Linux 6.9.0 and carries both, plus `fixed_phy.c` and `irq-litex-vexriscv.c`.
So "localise the image repositories" is not tidying that can happen whenever --
it *is* the kernel migration, and ethernet and SDIO are both downstream of it.

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

Distinct from the copy above, and not urgent.  What it needs beyond the
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

**Done when** a clean build on two machines reproduces the released bitstream's
I/O FASM lines, and both boot.

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
- A `fixed-link` subnode at 1000/full.  This is the answer to ethmin's PHY
  being a black box with no MDIO: `fixed_phy.c` is present, and the earlier
  `libphy: Fixed MDIO Bus: probed` line confirms kernel support.
- MAC address plumbed from the SoC rather than assumed.

**Risk.**  The kernel jump is the real work, not the driver.
`irq-litex-vexriscv.c` must suit a SoC with neither a CLINT nor a PLIC, and the
stage 3 golden transcript has to be rebased onto 6.9.

**Done when** `ip link` shows the interface and userspace can TFTP from the board.

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

---

## The reproducibility contract

**The goal is identical place-and-route results between platforms.**  Not a
weaker equivalence -- the same FASM, byte for byte, from the same inputs on any
host.  Where nextpnr does not currently deliver that, the cause is
nondeterministic container iteration, which is a bug class to be fixed rather
than a property to design around.

**The near-term gate is this host and GitHub.**  Both are Linux x86-64, so
there is no excuse for them to differ at all, and that is what CI asserts:

1. **The whole FASM identical**, not merely the I/O lines.  Same inputs, same
   file, on this host and on the runner.
2. **Software binaries identical** modulo the compiled-in `__DATE__`/`__TIME__`
   (`bios/main.c:214`).  Compare sizes and date-masked content, never raw hashes.
3. **Every clock at or above its constraint** on setup.  Hold is excluded
   deliberately: this flow's hold STA reports violations on designs that
   demonstrably run, which is why the target passes `--timing-allow-fail`.
4. **The extraction sweep unchanged** -- proved/differ counts from
   `verify_examples.sh`.
5. **Every input pinned**: all submodules, plus `PRJXRAY_DB_REV`.  The segbits
   database decides which bits a FASM line sets, and was the only build input
   not fixed by a submodule.

**The database is the deliberate exception, and it runs on two tracks.**  CI
tracks the *tip* of prjxray-db, because noticing the day upstream changes
which bits a FASM line sets is the point of running it there; the revision
check reports the difference in one line and carries on.  The pin is what
makes a *release* reproducible, and there the same check fails the build.

So a CI result and a local result are comparable only when the database
revisions agree, and CI prints which one it used.  When they disagree and the
FASM does too, that is upstream news rather than our regression -- and worth
knowing either way.  The first run of this check found the runner on
`6b8695ea3456` against `5099b9e` here, so every CI result before it was
quoted against a database nobody had recorded.

**Cross-platform, until determinism lands.**  macOS builds nextpnr against
libc++ rather than libstdc++, and today that changes placement.  Until it does
not, the cross-platform check is narrowed to the XDC-pinned I/O lines --
`LIOB18`, `RIOB18`, `LIOI`, `RIOI` -- which are host-independent by
construction, and which is the check that would have caught the dead RX path.
Narrowing it is a concession to a present defect, not the definition of done.

## Open items carried alongside

- `main_ram` is 512 MiB, not the gigabyte asked for.  Worth revisiting when
  stage 6 touches the gateware anyway.
- The `.IN` both-halves-input case on `LIOB18_X81Y81` is worked around by
  driving the PHY management pins, not fixed.  A collaborator offered to take it.
- `create_pblock` region support was offered too; valuable for ingesting Vivado
  constraints, not as a timing fix -- clock LOCs measurably made timing worse
  here (60.0 vs 91.3 MHz).
- **nextpnr placement is not deterministic across platforms.**  This is the
  open bug behind the narrowed cross-platform check above, and closing it is
  what makes the contract's stated goal reachable.  Likely culprits are
  pointer-keyed or hash-ordered containers whose iteration order feeds
  placement decisions.
- `build-linux.yml` has never run.  Hosted runners may not have the memory or
  the time for this design; stage 2 finds out.
