#!/usr/bin/env python3
"""Build a TSB-loader paper tape (absolute binary records) from hpasm .seg files.

Record format (as read by the 2000F TSB loader):
  frame: word count n (1..255)   frame: 0 (feed/flag)
  word: load origin              n data words
  word: checksum = (origin + sum(data)) & 0xFFFF
Words are two frames, high byte first.  Leader of zero frames precedes the data and the
last record has origin 0 (loader treats it as end of the system).
Usage: mktape.py out.tap in.seg [in2.seg ...] [--chunk N] [--leader N]
"""
import sys, argparse

def read_seg(path):
    segs, cur = [], None
    for line in open(path):
        line = line.strip()
        if not line:
            continue
        if line[0] == '@':
            cur = [int(line[1:], 8), []]
            segs.append(cur)
        else:
            cur[1].extend(int(t, 8) for t in line.split())
    return segs

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('out')
    ap.add_argument('segs', nargs='+')
    ap.add_argument('--chunk', type=int, default=64)
    ap.add_argument('--leader', type=int, default=64)
    ap.add_argument('--no-end', action='store_true', help='omit the origin-0 end record')
    a = ap.parse_args()
    out = bytearray(a.leader)
    def word(w):
        out.append((w >> 8) & 0xFF); out.append(w & 0xFF)
    nrec = 0
    for path in a.segs:
        for origin, words in read_seg(path):
            for i in range(0, len(words), a.chunk):
                chunk = words[i:i + a.chunk]
                org = origin + i
                out.append(len(chunk)); out.append(0)
                word(org)
                for w in chunk:
                    word(w)
                word((org + sum(chunk)) & 0xFFFF)
                nrec += 1
    if not a.no_end:
        out.append(1); out.append(0); word(0)
    open(a.out, 'wb').write(out)
    print('%s: %d records, %d frames' % (a.out, nrec, len(out)), file=sys.stderr)

main()
