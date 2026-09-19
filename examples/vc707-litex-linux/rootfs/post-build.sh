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

# A compiler on the target needs a sysroot, and target-finalize has just
# deleted it: buildroot removes /usr/include and every *.a as a matter of
# course, on the reasonable assumption that a target does not compile
# anything.  With gcc installed that assumption no longer holds, so put back
# what it needs -- after the deletion, which is why this lives in post-build
# and not in the package or a finalize hook (those run BEFORE the rm).
if [ -x "$TARGET/usr/bin/gcc" ] && [ -n "$STAGING_DIR" ]; then
    echo "post-build: restoring the sysroot for the native gcc"
    mkdir -p "$TARGET/usr/include"
    cp -a "$STAGING_DIR/usr/include/." "$TARGET/usr/include/"

    # The C++ headers are not in staging at all: they live in the cross
    # toolchain's own sysroot, host/<tuple>/include/c++, because that is
    # where gcc-final put them when it built libstdc++.
    CXXINC=$(ls -d "$HOST_DIR"/*/include/c++ 2>/dev/null | head -1)
    [ -n "$CXXINC" ] && cp -a "$CXXINC" "$TARGET/usr/include/"

    # Startup files and the static libc the linker wants.
    # libc.so is a linker script naming libc_nonshared.a by absolute path,
    # so the link fails without it even though nothing references it
    # directly -- which is exactly how it was missed.
    for f in crt1.o crti.o crtn.o libc.a libc_nonshared.a libm.a libpthread.a; do
        [ -f "$STAGING_DIR/usr/lib/$f" ] && cp -a "$STAGING_DIR/usr/lib/$f" "$TARGET/usr/lib/"
    done

    # libgcc.a and the crtbegin/crtend pair are TARGET objects that live in
    # the cross compiler's own tree, not in staging -- host/lib/gcc/<tuple>/
    # is where gcc keeps the support files it emits code against.
    GCCLIB=$(ls -d "$HOST_DIR"/lib/gcc/*/[0-9]* 2>/dev/null | head -1)
    TGCCLIB=$(ls -d "$TARGET"/usr/lib/gcc/*/[0-9]* 2>/dev/null | head -1)
    if [ -n "$GCCLIB" ] && [ -n "$TGCCLIB" ]; then
        for f in crtbegin.o crtbeginS.o crtbeginT.o crtend.o crtendS.o libgcc.a libgcc_eh.a; do
            [ -f "$GCCLIB/$f" ] && cp -a "$GCCLIB/$f" "$TGCCLIB/"
        done
    fi
fi
