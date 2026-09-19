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

## A native toolchain

gcc 13.4.0 and g++ run on the board.  `BR2_PACKAGE_GCC_NATIVE=y`.

Buildroot has no option for this -- `package/gcc` builds the CROSS compiler
and `gcc-final`'s target install copies only runtime libraries -- so
`package/gcc-native` Canadian-crosses it: built here, running on the target,
emitting target code, which is the shape `package/binutils` already uses to
put `as` and `ld` on the board.  Only the compiler proper is built; libgcc
and libstdc++ are already there from the identical version.

    time gcc hello.c     14.55s on the board (cached)
                          0.04s cross-compiled on the host
                           383x

About what the hardware predicts: ~40x on clock alone, the rest
microarchitecture.  20% of it is sys time -- process creation and page
faults across cc1/as/collect2/ld -- so a larger file scales better than the
ratio suggests.  Cross-compiling stays the default for real work.

### Four things this needed, none of them obvious

**The rootfs went from 6 MB to 210 MB**, and rootfs.cpio to 195 MB, which
would be hopeless as an initramfs in 512 MB of DDR3.  NFS root is not a
convenience here, it is what makes a native toolchain possible at all.

**BR2_INSTALL_LIBSTDCPP is not settable.**  It is a bool with no prompt,
selected by BR2_TOOLCHAIN_BUILDROOT_CXX.  Setting it in a defconfig is
silently dropped, the toolchain rebuilds without C++, and gcc's configure
dies with `CXX='no'` an hour later.  gcc-native now selects the right symbol
so the package cannot be enabled without it.

**target-finalize deletes the sysroot.**  It removes /usr/include and every
*.a as a matter of course, reasonably enough for a target that does not
compile.  Restoring them has to happen in BR2_ROOTFS_POST_BUILD_SCRIPT: a
package install or a TARGET_FINALIZE_HOOK both run BEFORE the deletion.
libc.so is a linker script naming libc_nonshared.a by absolute path, so the
link fails without a library nothing appears to reference.  The C++ headers
are not in staging at all -- they live in the cross toolchain's own sysroot,
host/<tuple>/include/c++.

**An empty --with-arch does not fail, it picks the wrong machine.**  The
extraction used `:=`, which expands when the .mk is PARSED, before TARGET_CC
exists; it produced an empty string, buildroot's `ifneq` guard skipped the
flag, and gcc fell back to its riscv32 default of rv32imafdc/ilp32d -- hard
float double, on a soft-float rv32ima CPU, linked against a loader that does
not exist on the board.  None of that is visible in the compiler binary:
`file` reports a correct riscv32 executable, and only the code it emits is
wrong.  It surfaced when something first tried to link.

Now deferred with `=`, and a pre-configure hook prints the target and
refuses to build if it cannot determine it.  A wrong answer that looks like
success is worth failing loudly for.
