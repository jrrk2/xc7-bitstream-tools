#!/bin/sh
# Buildroot copies rootfs overlays with "--chmod=u=rwX,go=rX", which turns
# the 0600 on a private host key into 0644.  Nothing enforces host-key
# permissions in dropbear, so this is not what makes ssh work -- it is just
# that a private key has no business being world-readable.  Post-build runs
# after the overlay is applied, which is why the mode is set here and not on
# the file in the repository.
set -e
TARGET="$1"
if [ -d "$TARGET/etc/dropbear" ]; then
    chmod 700 "$TARGET/etc/dropbear"
    find "$TARGET/etc/dropbear" -name 'dropbear_*_host_key' -exec chmod 600 {} +
fi

# Dropbear refuses a key when ~/.ssh or authorized_keys is group- or
# world-writable.  The overlay copy makes them 0644/0755, which happens to
# pass, but set the conventional modes rather than depend on that.
if [ -d "$TARGET/root/.ssh" ]; then
    chmod 700 "$TARGET/root/.ssh"
    [ -f "$TARGET/root/.ssh/authorized_keys" ] && chmod 600 "$TARGET/root/.ssh/authorized_keys"
fi
