#!/usr/bin/env python3
"""openila.py -- drive an openila (examples/openila) over JTAG with openFPGALoader.

  openila.py [opts] arm [--mask HEX] [--value HEX] [--post N]   arm (re-arm) the trigger
  openila.py [opts] disarm
  openila.py [opts] status                                      armed / triggered / done, waddr
  openila.py [opts] read [--vcd out.vcd] [--map out.json.map]   dump the buffer, oldest sample first

opts: --width W (64) --depth D (1024) --ctl 2 --dat 3 --ofl PATH --cable digilent --freq HZ
      --clk-ns NS (for the VCD timescale)
--map is the file openila_merge.py writes next to its output (bit -> net name);
with it, `read` prints a column per probed net and the VCD names them.
"""
import argparse, os, subprocess, sys

ap = argparse.ArgumentParser()
ap.add_argument('--width', type=int, default=64)
ap.add_argument('--depth', type=int, default=1024)
ap.add_argument('--ctl', type=int, default=2)
ap.add_argument('--dat', type=int, default=3)
ap.add_argument('--ofl', default=os.path.expanduser('~/openFPGALoader/build-ofl/openFPGALoader'))
ap.add_argument('--cable', default='digilent')
ap.add_argument('--freq', type=int, default=15000000)
ap.add_argument('--clk-ns', type=float, default=8.0)
sub = ap.add_subparsers(dest='cmd', required=True)
a = sub.add_parser('arm'); a.add_argument('--mask', default='0'); a.add_argument('--value', default='0'); a.add_argument('--post', type=int, default=None)
sub.add_parser('disarm'); sub.add_parser('status')
r = sub.add_parser('read'); r.add_argument('--vcd'); r.add_argument('--map'); r.add_argument('--raw', action='store_true')
o = ap.parse_args()

W, D = o.width, o.depth
AW = max(1, (D - 1).bit_length())
CW = 2 * W + AW + 9
SW = AW + 11

def user_dr(chain, nbits, value):
    cmd = [o.ofl, '--cable', o.cable, '--freq', str(o.freq), '--user-dr', f'{chain}/{nbits}/{value:x}']
    p = subprocess.run(cmd, capture_output=True, text=True)
    for l in (p.stdout + p.stderr).splitlines():
        if f'USER{chain} out' in l:
            return int(l.split()[-1], 16)
    sys.exit(f'openFPGALoader gave no USER{chain} data:\n{p.stdout}{p.stderr}')

def ctl_word(mask, value, post, arm):
    return (mask & ((1 << W) - 1)) | ((value & ((1 << W) - 1)) << W) | ((post & ((1 << AW) - 1)) << (2 * W)) \
        | (arm << (2 * W + AW)) | (0x5A << (2 * W + AW + 1))

def decode_status(s):
    s &= (1 << SW) - 1
    key = s >> (AW + 3)
    return {'waddr': s & ((1 << AW) - 1), 'armed': (s >> AW) & 1, 'trig': (s >> (AW + 1)) & 1,
            'done': (s >> (AW + 2)) & 1, 'key_ok': key == 0x1A}

def show_status(st):
    print(f"{'armed' if st['armed'] else 'idle'}{', triggered' if st['trig'] else ''}{', done' if st['done'] else ''}; "
          f"waddr={st['waddr']}{'' if st['key_ok'] else '  (BAD KEY: wrong chain or no ILA?)'}")

if o.cmd == 'status':
    show_status(decode_status(user_dr(o.ctl, CW, 0)))
elif o.cmd == 'disarm':
    user_dr(o.ctl, CW, ctl_word(0, 0, 0, 0)); print('disarmed')
elif o.cmd == 'arm':
    post = o.post if o.post is not None else D // 2
    mask, value = int(o.mask, 16), int(o.value, 16)
    user_dr(o.ctl, CW, ctl_word(mask, value, post, 0))          # drop a previous arm
    st = decode_status(user_dr(o.ctl, CW, ctl_word(mask, value, post, 1)))  # the CAPTURE of this shift shows the disarmed state
    print(f'armed: mask={mask:x} value={value:x} post={post}')
elif o.cmd == 'read':
    names = {}
    if o.map:
        for l in open(o.map):
            k, n = l.split(); names[int(k)] = n
    raw = user_dr(o.dat, (D + 1) * W, 0)
    words = [(raw >> (W * i)) & ((1 << W) - 1) for i in range(D + 1)]
    st = decode_status(words[0]); show_status(st)
    samples = words[1:]
    if not o.raw:
        samples = samples[st['waddr']:] + samples[:st['waddr']]   # oldest first
    cols = [(k, names[k]) for k in sorted(names)] if names else [(k, f'p{k}') for k in range(W)]
    # group bus bits: name[k] -> bus
    buses = []
    for k, n in cols:
        b = n.rsplit('[', 1)[0] if n.endswith(']') else n
        if buses and buses[-1][0] == b: buses[-1][1].append(k)
        else: buses.append((b, [k]))
    def field(v, bits): return sum(((v >> b) & 1) << i for i, b in enumerate(bits))
    hdr = ' '.join(f'{b:>{max(len(b), (len(bits)+3)//4)}}' for b, bits in buses)
    print(f'{"#":>5} {hdr}')
    for i, v in enumerate(samples):
        print(f'{i:5d} ' + ' '.join(f'{field(v, bits):>{max(len(b), (len(bits)+3)//4)}x}' for b, bits in buses))
    if o.vcd:
        with open(o.vcd, 'w') as f:
            f.write(f'$timescale 1ps $end\n$scope module ila $end\n')
            ids = {}
            for j, (b, bits) in enumerate(buses):
                ids[b] = chr(33 + j) if j < 90 else f'v{j}'
                f.write(f'$var wire {len(bits)} {ids[b]} {b} $end\n')
            f.write('$upscope $end\n$enddefinitions $end\n')
            last = {}
            for i, v in enumerate(samples):
                f.write(f'#{int(i * o.clk_ns * 1000)}\n')
                for b, bits in buses:
                    x = field(v, bits)
                    if last.get(b) != x:
                        f.write((f'{x}{ids[b]}\n' if len(bits) == 1 else f'b{x:b} {ids[b]}\n')); last[b] = x
        print(f'wrote {o.vcd}', file=sys.stderr)
