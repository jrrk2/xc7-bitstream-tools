#!/usr/bin/env python3
"""readback2bit.py design.bit readback.rb out.bit [--report]

Turns a raw readback stream (openFPGALoader --readback, 32-bit LE words,
one dummy frame first) into a .bit with the same headers and packets as
the design's bitstream but the frames the device just read back.  Every
prjxray tool then works on it unchanged: bitread lists the bits, bit2fasm
names them, and a flip-flop's INIT feature in that FASM is the value the
flip-flop held at GCAPTURE.

--report: how many payload words differ from the original, as a first check
that the stream is aligned (a right alignment differs in few words -- the
registers and RAMs that moved -- a wrong one in most).
"""
import struct, sys

bit, rb, out = sys.argv[1:4]
report = '--report' in sys.argv
data = open(bit, 'rb').read()
# Xilinx .bit: fields a..e, 'e' carries a 4-byte length then the config stream
pos = 0
def field(tag):
    global pos
    assert data[pos:pos + 1] == tag, (tag, data[pos:pos + 4])
    pos += 1
    if tag == b'e':
        n = struct.unpack('>I', data[pos:pos + 4])[0]; pos += 4
        return pos, n
    n = struct.unpack('>H', data[pos:pos + 2])[0]; pos += 2
    s = data[pos:pos + n]; pos += n
    return s
hdr_len = struct.unpack('>H', data[0:2])[0]; pos = 2 + hdr_len
assert struct.unpack('>H', data[pos:pos + 2])[0] == 1; pos += 2
for t in (b'a', b'b', b'c', b'd'): field(t)
cfg_start, cfg_len = field(b'e')
cfg = bytearray(data[cfg_start:cfg_start + cfg_len])
words = struct.unpack('>%dI' % (len(cfg) // 4), cfg)
# find the type-2 FDRI payload after the sync word
i = words.index(0xAA995566) + 1
payload = None
while i < len(words):
    w = words[i]
    typ = w >> 29
    if typ == 1:
        op = (w >> 27) & 3; reg = (w >> 13) & 0x3FFF; cnt = w & 0x7FF
        i += 1
        if op == 2 and reg == 2 and cnt == 0 and (words[i] >> 29) == 2:   # write FDRI, then type 2
            n = words[i] & 0x07FFFFFF; payload = (i + 1, n); break
        i += cnt
    else:
        i += 1
assert payload, 'no FDRI type-2 packet found'
start, n = payload
rbw = struct.unpack('<%dI' % (len(open(rb, 'rb').read()) // 4), open(rb, 'rb').read())
FRAME = 101
assert len(rbw) >= FRAME + n, f'readback has {len(rbw)} words, need {FRAME + n}'
new = rbw[FRAME:FRAME + n]
if report:
    diff = sum(1 for a, b in zip(words[start:start + n], new) if a != b)
    print(f'{n} payload words, {diff} differ from the bitstream')
struct.pack_into('>%dI' % n, cfg, start * 4, *new)
open(out, 'wb').write(data[:cfg_start] + bytes(cfg) + data[cfg_start + cfg_len:])
print('wrote', out)
