#!/usr/bin/env bash
# Stage the rv64 Rocket payload for netboot, keeping the rv32 one recoverable.
#
#   scripts/stage_rv64.sh [payload-dir] [tftp-dir]
#
# The rv32 payload is saved once, under .rv32 suffixes, the first time this
# runs.  Going back is a copy, not a rebuild.
set -eu
SRC=${1:-$HOME/vc707-work/rv64-payload}
# boot.bin mode: one self-contained image (OpenSBI + embedded dtb + kernel)
# copied to main_ram base and entered there.  Preferred over boot.json --
# the BIOS validates nothing about the latter, r1 defaults to 0, and the
# gaps between separately-loaded images are never written, so they hold
# whatever the last boot left in DRAM.  One image makes the memory state
# identical every time.
MODE=${MODE:-bin}
DST=${2:-$HOME/tftp-vc707/10:e2:d5:00:00:07}

for f in Image opensbi.bin rv64.dtb boot.json; do
    [ -f "$SRC/$f" ] || { echo "missing $SRC/$f"; exit 2; }
done

# The BIOS validates nothing about boot.json beyond parsing it: r1 defaults
# to 0, and jumping to OpenSBI with a null FDT pointer is a perfectly legal
# payload that produces total silence -- no console, no CPU list, nothing to
# distinguish it from a dead core.  It cost a boot cycle to find.  Check here
# what nothing downstream will.
echo "== checking the payload"
python3 - "$SRC" <<'CHECK'
import json, os, sys
src = sys.argv[1]
b = json.load(open(os.path.join(src, "boot.json")))
addrs = {k: int(v, 16) for k, v in b.items() if k not in ("r1","r2","r3","addr")}
regs  = []
for name, a in addrs.items():
    path = os.path.join(src, name)
    if not os.path.isfile(path):
        sys.exit("boot.json names %s, which is not in the payload" % name)
    regs.append((a, a + os.path.getsize(path), name))
regs.sort()
for (a1_, e1, n1), (a2, e2, n2) in zip(regs, regs[1:]):
    if e1 > a2:
        sys.exit("%s (ends 0x%x) overlaps %s (starts 0x%x)" % (n1, e1, n2, a2))
# A dtb in the payload must be handed to the firmware, or it is never read.
dtb = [n for n in addrs if n.endswith(".dtb")]
if dtb:
    if "r1" not in b:
        sys.exit("payload has %s but boot.json sets no r1: the firmware would "
                 "be entered with a null FDT pointer and say nothing" % dtb[0])
    if int(b["r1"], 16) != addrs[dtb[0]]:
        sys.exit("r1 is 0x%x but %s loads at 0x%x" %
                 (int(b["r1"],16), dtb[0], addrs[dtb[0]]))
    with open(os.path.join(src, dtb[0]), "rb") as f:
        if f.read(4) != b"\xd0\x0d\xfe\xed":
            sys.exit("%s is not a device tree blob (bad magic)" % dtb[0])
print("   %d images, no overlaps, r1 -> %s, dtb magic ok" % (len(regs), dtb[0] if dtb else "n/a"))
CHECK
[ $? -eq 0 ] || exit 1

echo "== saving the rv32 payload (once)"
for f in Image boot.json opensbi.bin; do
    [ -f "$DST/$f" ] && [ ! -f "$DST/$f.rv32" ] && cp -a "$DST/$f" "$DST/$f.rv32" && echo "   kept $f.rv32"
done

echo "== staging rv64"
cp -a "$SRC"/Image "$SRC"/opensbi.bin "$SRC"/rv64.dtb "$SRC"/boot.json "$DST/"
# The rv32 dtb and initramfs must not be reachable: the BIOS boots whatever
# boot.json names, but a stale rootfs.cpio alongside is how a "fixed" board
# quietly boots the old world.
rm -f "$DST/rootfs.cpio"

echo "== staged:"
for f in Image opensbi.bin rv64.dtb boot.json; do
    printf "   %-12s %s bytes\n" "$f" "$(stat -c%s "$DST/$f")"
done
echo "== boot.json:"; sed 's/^/   /' "$DST/boot.json"
