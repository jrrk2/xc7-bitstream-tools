# Saved artifacts, 2026-09-07

Bitstreams are gitignored, so the binaries live outside the tree:

    ~/vc707-artifacts/2026-09-07-smpsd/     bitstreams, FASM, boot payload
    ~/vc707-build/                          buildroot and kernel build trees

Both are under $HOME deliberately: the working scratchpad is under /tmp,
which this machine clears at boot.

MANIFEST.md in the artifacts directory describes each file and carries
SHA256SUMS.  The short version:

  openxc7-smpsd.bit   open flow.  Boots Linux under OpenSBI with PLIC
                      interrupts, DDR3 and ethernet.  SD does not work.
  vivado-smpsd.bit    same RTL through Vivado.  Everything, including
                      4-bit SDIO at 25 MHz.  The known-good reference.
  vivado-smpsd.fasm   bit2fasm extraction of it -- the oracle that found
                      the missing IN_DIFF bits.

~/vc707-build holds br-build (6.6 GB) and linux-build-local.  Buildroot
bakes absolute paths into its host toolchain, so a tree used from the new
location may need a make pass to settle; the artifacts that matter --
Image, rootfs.cpio -- are saved separately in the artifacts directory and
staged in the per-MAC TFTP directory, which is also under $HOME.
