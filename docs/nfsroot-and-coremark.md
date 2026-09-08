# NFS root, and the first CPU number

## Root over NFS

The board mounts `/` from the host instead of unpacking a cpio into RAM.  A
change to the root filesystem is now an edit on the host, live on the next
open() -- no rebuild, no restage, no reboot.  It also drops ~4 MB from every
netboot, since `rootfs.cpio` is no longer transferred at all.

Set the export up once, as root:

    sudo scripts/nfsroot_setup.sh

then stage a payload with `make vc707-litex-linux-nfsroot`, or for the SMP
SoC in service patch its device tree directly:

    scripts/nfsroot_dtb.py smpsd-nonrem.dtb smpsd-nfs.dtb 192.168.1.106:/home/jonathan/vc707-nfsroot

The dtb is PATCHED rather than regenerated on purpose.  The one in service
encodes the SoC's CSR addresses, the PLIC layout and the exact `ip=` string
this board is known to autoconfigure with; regenerating it would re-derive
all of that to arrive at the same answer, with more ways to be wrong.  The
patch changes `root=` and deletes the two initrd properties, and a diff of
the decompiled trees shows nothing else moved.

Deleting the initrd properties is not optional.  A kernel that finds an
initramfs mounts it and never consults `root=`, so leaving them in place
boots the old ramdisk and looks exactly like the NFS mount failing quietly.

Kernel side: `CONFIG_NFS_FS`, `NFS_V2`, `NFS_V3`, `ROOT_NFS`.  `IP_PNP` and
`LITEX_LITEETH` were already `=y` and both are required -- `ip=` runs long
before userspace, so the ethernet driver cannot be a module.

### A bug this turned up

`scripts/linux_payload.py` retargeted the UART by substituting **every**
address matching `0x..f0xxxxxx`, which is every CSR bank in the tree.  The
ethernet MAC's `reg` became the UART's, so any board booted from a dtb that
script generated had no network at all.  It went unnoticed because the dtb
in service came from another route.  Now scoped to the serial node.

## CoreMark

    CoreMark 1.0 : 169.83 / GCC13.4.0 -O2 -g0 -D_FORTIFY_SOURCE=1 / Heap

    169.83 iterations/s at 100 MHz  =  1.70 CoreMark/MHz   (single core)

Valid and repeatable: 17.7 s against the 10 s minimum, `Correct operation
validated`, and two runs 0.3% apart.  rv32ima, ilp32 soft-float -- which
costs nothing here, CoreMark being integer-only.

1.70 CoreMark/MHz is unremarkable for a Linux-capable VexRiscv with MMU and
caches; the family spans roughly 1.2-2.5 depending on cache sizes, the
multiplier and branch prediction.  Nothing suggests a misconfigured core.

Quote the score with the flags and the clock or it means nothing.  Note the
flags came from buildroot's own defaults -- `BR2_TARGET_OPTIMIZATION` is
empty in the defconfig, which looks like "unoptimised" and is not: `-O2`
arrives anyway.

`BR2_PACKAGE_COREMARK=y` is in `rootfs/vc707_defconfig`, so it survives a
rebuild and a re-extract of the export.
