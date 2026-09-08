#!/usr/bin/env bash
# Set up an NFS root export for the VC707 Linux board.  Run with sudo: it
# needs root to create device nodes with the right ownership and to write
# /etc/exports.  Everything else in the flow is unprivileged.
#
#   sudo scripts/nfsroot_setup.sh [export-dir] [rootfs.tar] [board-ip]
#
# Re-running it is safe and is how you install a rebuilt buildroot rootfs:
# the export directory is replaced wholesale.
set -eu

EXPORT=${1:-/home/jonathan/vc707-nfsroot}
TARBALL=${2:-/home/jonathan/vc707-build/br-build/images/rootfs.tar}
BOARD=${3:-192.168.1.50}

[ "$(id -u)" = 0 ] || { echo "run this with sudo -- it needs to create device nodes"; exit 2; }
[ -f "$TARBALL" ] || { echo "no rootfs tarball at $TARBALL"; exit 2; }

echo "== unpacking $TARBALL into $EXPORT"
# As root, so ownership is root:root and the device nodes in the archive are
# actually created.  Unpacked as a normal user every file belongs to that user
# and every mknod is skipped -- which mostly works, because the kernel mounts
# devtmpfs over /dev anyway, and then fails in ways that look like NFS faults.
mkdir -p "$EXPORT"
find "$EXPORT" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
tar -xf "$TARBALL" -C "$EXPORT"

# A root filesystem the board can actually write to.
chown -R 0:0 "$EXPORT"

echo "== exporting to $BOARD"
# no_root_squash: the board runs as root and a root filesystem it cannot write
# as root is not a root filesystem.  This export is a development convenience
# on a local network -- it grants that one host full write access to this
# directory tree, so keep it pointed at the board's address and not a subnet.
LINE="$EXPORT $BOARD(rw,sync,no_subtree_check,no_root_squash,insecure)"
touch /etc/exports
if grep -qF "$EXPORT " /etc/exports; then
    sed -i "s|^$EXPORT .*|$LINE|" /etc/exports
else
    echo "$LINE" >> /etc/exports
fi
exportfs -ra
systemctl enable --now nfs-kernel-server >/dev/null 2>&1 || service nfs-kernel-server restart

echo "== exported:"
exportfs -v | sed 's/^/   /'
echo
echo "root filesystem ready at $EXPORT for $BOARD"
