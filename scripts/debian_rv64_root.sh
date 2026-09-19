#!/usr/bin/env bash
# Build a Debian riscv64 NFS root for the Rocket SoC.  Run with sudo.
#
#   sudo scripts/debian_rv64_root.sh [export-dir] [board-ip] [suite]
#
# Debian rather than buildroot because riscv64 is a release architecture from
# trixie onwards, so apt gives us a native toolchain, a package manager and
# everything else without a second cross-build.  Rocket's `linux` variant is
# rv64imafdc, which meets the rv64gc baseline Debian requires.
#
# This does NOT touch the rv32 export: it is a separate directory, so the
# VexRiscv board keeps working while this one is brought up.
set -eu

EXPORT=${1:-/home/jonathan/vc707-nfsroot-rv64}
BOARD=${2:-192.168.1.50}
SUITE=${3:-trixie}
MIRROR=http://deb.debian.org/debian

[ "$(id -u)" = 0 ] || { echo "run this with sudo"; exit 2; }
command -v debootstrap >/dev/null || { echo "debootstrap not installed"; exit 2; }
QEMU=$(command -v qemu-riscv64-static) || { echo "qemu-riscv64-static not installed"; exit 2; }

# systemd-sysv provides /sbin/init -> systemd.  minbase does not pull
# it in, and without it the kernel finds no init and falls through to
# /bin/sh, which looks like a rootfs problem and is a packaging one.
PKGS=systemd-sysv,ifupdown,iproute2,net-tools,ca-certificates,openssh-server,nfs-common,gcc,make,file,less,vim-tiny

echo "== first stage: $SUITE/riscv64 -> $EXPORT"
# --foreign stops after unpacking, because the maintainer scripts are riscv64
# binaries this machine cannot execute.  qemu-user runs them in the second
# stage below.
rm -rf "$EXPORT"
mkdir -p "$EXPORT"
debootstrap --arch=riscv64 --foreign --variant=minbase --include="$PKGS" \
    "$SUITE" "$EXPORT" "$MIRROR"

echo "== second stage, under qemu-user"
cp "$QEMU" "$EXPORT/usr/bin/"
chroot "$EXPORT" /debootstrap/debootstrap --second-stage

echo "== configuring"
echo vc707 > "$EXPORT/etc/hostname"
cat > "$EXPORT/etc/hosts" <<HOSTS
127.0.0.1	localhost
127.0.1.1	vc707
HOSTS
# The kernel configures eth0 from ip= before userspace starts, so ifupdown
# must leave it alone -- bringing it down to reconfigure would drop the NFS
# root out from under the process doing it.
cat > "$EXPORT/etc/network/interfaces" <<NET
auto lo
iface lo inet loopback
NET
# A root password, since a serial console with no way in is no use.
chroot "$EXPORT" /bin/sh -c 'echo "root:vc707" | chpasswd'
sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin yes/' "$EXPORT/etc/ssh/sshd_config" || true
# / is already mounted by the kernel; an entry for it here only invites fsck.
cat > "$EXPORT/etc/fstab" <<FSTAB
proc  /proc proc  defaults 0 0
sysfs /sys  sysfs defaults 0 0
FSTAB

echo "== exporting to $BOARD"
LINE="$EXPORT $BOARD(rw,sync,no_subtree_check,no_root_squash,insecure)"
touch /etc/exports
grep -qF "$EXPORT " /etc/exports && sed -i "s|^$EXPORT .*|$LINE|" /etc/exports || echo "$LINE" >> /etc/exports
exportfs -ra
exportfs -v | grep -F "$EXPORT" | sed 's/^/   /'
echo
echo "Debian $SUITE riscv64 ready at $EXPORT for $BOARD"
du -sh "$EXPORT" | sed 's/^/   /'
