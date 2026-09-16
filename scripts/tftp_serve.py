#!/usr/bin/env python3
"""A read-only TFTP server that delivers per-MAC boot images.

Why this exists rather than the system's tftpd-hpa: more than one LiteX SoC
here network-boots, and the BIOS asks for "boot.json"/"boot.bin" by names it
does not let the target change.  Two boards therefore fetch each other's boot
image out of a shared root.  tftpd-hpa cannot dispatch on the client, and the
alternative -- dnsmasq's tftp-unique-root=mac -- would mean stopping the
server another triage depends on, and needs root.

This one resolves the requesting IP to a MAC through the host's ARP table and
prefers <root>/<mac>/<file> over <root>/<file>, so each board gets its own
payload and an unclaimed board still gets the default.  It needs no
privileges on a port above 1024.

    scripts/tftp_serve.py --root ~/tftp-vc707 --port 6969

Read requests only: it never accepts a write, and it refuses any path that
escapes the root.
"""

import argparse
import os
import re
import socket
import struct
import sys
import time

OP_RRQ, OP_WRQ, OP_DATA, OP_ACK, OP_ERROR, OP_OACK = 1, 2, 3, 4, 5, 6

ERR_NOT_FOUND    = 1
ERR_ACCESS       = 2
ERR_ILLEGAL      = 4


def mac_for_ip(ip):
    """The requesting board's MAC, from the host's ARP table, or None.

    A TFTP server sees an IP, not a MAC, so this is the only way to key
    delivery on the hardware address.  It can legitimately miss -- the entry
    may not be cached yet -- and the caller falls back to the shared root
    rather than failing the boot.
    """
    try:
        with open("/proc/net/arp") as f:
            for line in f.readlines()[1:]:
                fields = line.split()
                if len(fields) >= 4 and fields[0] == ip:
                    mac = fields[3].lower()
                    if mac != "00:00:00:00:00:00":
                        return mac
    except OSError:
        pass
    return None


def resolve(root, filename, client_ip):
    """Pick the file to serve, preferring the requester's own directory.

    Returns (path, mac, used_mac_dir).  Both the MAC-qualified name and the
    plain one are confined to the root: a filename containing .. or an
    absolute path is rejected before it is joined.
    """
    if os.path.isabs(filename) or ".." in filename.replace("\\", "/").split("/"):
        return None, None, False

    mac = mac_for_ip(client_ip)
    if mac:
        # Both spellings are in use in the wild; accept either as a directory
        # name so the operator can use whichever reads better.
        for name in (mac, mac.replace(":", "")):
            candidate = os.path.join(root, name, filename)
            if os.path.isfile(candidate):
                return candidate, mac, True

    candidate = os.path.join(root, filename)
    if os.path.isfile(candidate):
        return candidate, mac, False
    return None, mac, False


def send_error(sock, addr, code, message):
    sock.sendto(struct.pack("!HH", OP_ERROR, code) + message.encode() + b"\0", addr)


def parse_request(payload):
    """filename, mode and options out of an RRQ, which is NUL-separated."""
    parts = payload.split(b"\0")
    filename = parts[0].decode("ascii", "replace")
    mode = parts[1].decode("ascii", "replace").lower() if len(parts) > 1 else "octet"
    options = {}
    rest = [p for p in parts[2:] if p != b""]
    for i in range(0, len(rest) - 1, 2):
        options[rest[i].decode("ascii", "replace").lower()] = rest[i + 1].decode("ascii", "replace")
    return filename, mode, options


def serve_file(path, addr, options, log):
    """One transfer, on its own socket as the protocol requires."""
    with open(path, "rb") as f:
        data = f.read()

    xfer = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    xfer.settimeout(2.0)
    try:
        block_size = 512
        acked = {}
        if "blksize" in options:
            try:
                requested = int(options["blksize"])
                if 8 <= requested <= 65464:
                    block_size = requested
                    acked["blksize"] = str(block_size)
            except ValueError:
                pass
        if "tsize" in options:
            acked["tsize"] = str(len(data))

        if acked:
            # The client asked for options, so it must see an OACK before any
            # data; it acknowledges with block 0.
            packet = struct.pack("!H", OP_OACK)
            for k, v in acked.items():
                packet += k.encode() + b"\0" + v.encode() + b"\0"
            if not send_and_wait(xfer, packet, addr, 0, log):
                return False

        total = len(data)
        block = 1
        offset = 0
        while True:
            chunk = data[offset:offset + block_size]
            packet = struct.pack("!HH", OP_DATA, block & 0xFFFF) + chunk
            if not send_and_wait(xfer, packet, addr, block & 0xFFFF, log):
                return False
            offset += len(chunk)
            block += 1
            # A transfer ends with a block shorter than the block size, which
            # means a file that is an exact multiple needs a final empty one.
            if len(chunk) < block_size:
                break
        log(f"    sent {total} bytes in {block - 1} block(s) of {block_size}")
        return True
    finally:
        xfer.close()


def send_and_wait(sock, packet, addr, expect_block, log, retries=5):
    """Send, then wait for the matching ACK, retransmitting on timeout."""
    for attempt in range(retries):
        sock.sendto(packet, addr)
        try:
            while True:
                reply, from_addr = sock.recvfrom(1024)
                if from_addr[0] != addr[0]:
                    continue
                if len(reply) < 4:
                    continue
                opcode, block = struct.unpack("!HH", reply[:4])
                if opcode == OP_ERROR:
                    detail = reply[4:].split(b"\0")[0].decode("ascii", "replace")
                    log(f"    client reported error: {detail}")
                    return False
                if opcode == OP_ACK and block == expect_block:
                    return True
        except socket.timeout:
            if attempt + 1 < retries:
                log(f"    timeout waiting for ACK {expect_block}, retransmitting")
    log(f"    giving up waiting for ACK {expect_block}")
    return False


def main():
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--root", required=True, help="Directory to serve.")
    parser.add_argument("--port", type=int, default=6969, help="UDP port to listen on.")
    parser.add_argument("--bind", default="0.0.0.0", help="Address to listen on.")
    args = parser.parse_args()

    root = os.path.abspath(os.path.expanduser(args.root))
    if not os.path.isdir(root):
        sys.exit(f"not a directory: {root}")

    def log(message):
        print(f"[{time.strftime('%H:%M:%S')}] {message}", flush=True)

    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    sock.bind((args.bind, args.port))
    log(f"serving {root} on {args.bind}:{args.port} (read-only, per-MAC)")

    while True:
        try:
            payload, addr = sock.recvfrom(2048)
        except KeyboardInterrupt:
            log("stopped")
            return
        if len(payload) < 2:
            continue
        opcode = struct.unpack("!H", payload[:2])[0]
        if opcode == OP_WRQ:
            log(f"{addr[0]} tried to write; refused")
            send_error(sock, addr, ERR_ACCESS, "read-only server")
            continue
        if opcode != OP_RRQ:
            continue

        filename, mode, options = parse_request(payload[2:])
        path, mac, used_mac_dir = resolve(root, filename, addr[0])
        who = f"{addr[0]} [{mac or 'MAC unknown'}]"
        if path is None:
            log(f"{who} asked for {filename!r}: not found")
            send_error(sock, addr, ERR_NOT_FOUND, "file not found")
            continue
        where = "its own directory" if used_mac_dir else "the shared root"
        log(f"{who} asked for {filename!r} -> {os.path.relpath(path, root)} ({where})")
        try:
            serve_file(path, addr, options, log)
        except OSError as e:
            log(f"    transfer failed: {e}")


if __name__ == "__main__":
    main()
