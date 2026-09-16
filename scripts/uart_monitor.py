#!/usr/bin/env python3
"""Log a board's serial output to a file and to stdout.

picocom and screen are interactive; this is for an unattended run that has to
leave a record behind -- the boot of a bitstream nobody has seen boot before.
It timestamps the first byte of each line, so a log shows not just what the
board said but how long it took to say it, which is what tells a slow boot
apart from a hung one.

    scripts/uart_monitor.py --port /dev/ttyUSB2 --baud 115200 --seconds 120

Exits when the idle timeout passes with no new data, or on --seconds.
"""

import argparse
import sys
import time

try:
    import serial
except ImportError:
    sys.exit("pyserial is not installed: pip install pyserial")


def main():
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--port", default="/dev/ttyUSB2")
    parser.add_argument("--baud", type=int, default=115200)
    parser.add_argument("--seconds", type=float, default=120.0,
                        help="Total time to listen for.")
    parser.add_argument("--idle", type=float, default=0.0,
                        help="Stop after this many seconds with no data (0 = never).")
    parser.add_argument("--log", default=None, help="Also append to this file.")
    args = parser.parse_args()

    try:
        port = serial.Serial(args.port, args.baud, timeout=0.2)
    except serial.SerialException as e:
        sys.exit(f"cannot open {args.port}: {e}")

    log = open(args.log, "a", buffering=1) if args.log else None
    start = time.monotonic()
    last_data = start
    line = bytearray()
    total = 0

    def flush_line():
        if not line:
            return
        text = line.decode("utf-8", "replace").rstrip("\r\n")
        stamp = f"[{time.monotonic() - start:7.2f}s] "
        print(stamp + text, flush=True)
        if log:
            log.write(stamp + text + "\n")
        line.clear()

    try:
        while True:
            now = time.monotonic()
            if now - start >= args.seconds:
                break
            if args.idle and total and (now - last_data) >= args.idle:
                break
            chunk = port.read(256)
            if chunk:
                total += len(chunk)
                last_data = now
                for byte in chunk:
                    if byte == 0x0A:
                        flush_line()
                    else:
                        line.append(byte)
    except KeyboardInterrupt:
        pass
    finally:
        flush_line()
        port.close()
        if log:
            log.close()

    print(f"--- {total} bytes in {time.monotonic() - start:.1f}s", flush=True)
    # A silent port is a result, not an error, so say so and exit cleanly.
    if total == 0:
        print("--- NOTHING RECEIVED", flush=True)


if __name__ == "__main__":
    main()
