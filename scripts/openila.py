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

The Openila class below is the whole driver; openila_gui.py uses it too.
"""
import argparse, os, subprocess, sys


class Openila:
    def __init__(self, width=64, depth=1024, ctl=2, dat=3, ofl=None, cable='digilent', freq=15000000):
        self.W, self.D, self.ctl, self.dat = width, depth, ctl, dat
        self.ofl = ofl or os.path.expanduser('~/openFPGALoader/build-ofl/openFPGALoader')
        self.cable, self.freq = cable, freq
        self.AW = max(1, (depth - 1).bit_length())
        self.CW = 2 * width + self.AW + 9
        self.SW = self.AW + 11

    # ---- JTAG ----
    def user_dr(self, chain, nbits, value):
        cmd = [self.ofl, '--cable', self.cable, '--freq', str(self.freq), '--user-dr', f'{chain}/{nbits}/{value:x}']
        p = subprocess.run(cmd, capture_output=True, text=True)
        for l in (p.stdout + p.stderr).splitlines():
            if f'USER{chain} out' in l:
                return int(l.split()[-1], 16)
        raise RuntimeError(f'openFPGALoader gave no USER{chain} data:\n{p.stdout}{p.stderr}')

    # ---- register formats ----
    def ctl_word(self, mask, value, post, arm):
        W, AW = self.W, self.AW
        return (mask & ((1 << W) - 1)) | ((value & ((1 << W) - 1)) << W) | ((post & ((1 << AW) - 1)) << (2 * W)) \
            | (arm << (2 * W + AW)) | (0x5A << (2 * W + AW + 1))

    def decode_status(self, s):
        AW = self.AW
        s &= (1 << self.SW) - 1
        return {'waddr': s & ((1 << AW) - 1), 'armed': (s >> AW) & 1, 'trig': (s >> (AW + 1)) & 1,
                'done': (s >> (AW + 2)) & 1, 'key_ok': (s >> (AW + 3)) == 0x1A}

    @staticmethod
    def status_text(st):
        return (f"{'armed' if st['armed'] else 'idle'}{', triggered' if st['trig'] else ''}{', done' if st['done'] else ''}; "
                f"waddr={st['waddr']}{'' if st['key_ok'] else '  (BAD KEY: wrong chain or no ILA?)'}")

    # ---- operations ----
    def status(self):
        return self.decode_status(self.user_dr(self.ctl, self.CW, 0))

    def disarm(self):
        self.user_dr(self.ctl, self.CW, self.ctl_word(0, 0, 0, 0))

    def arm(self, mask, value, post):
        self.user_dr(self.ctl, self.CW, self.ctl_word(mask, value, post, 0))   # drop a previous arm
        self.user_dr(self.ctl, self.CW, self.ctl_word(mask, value, post, 1))

    def read(self, raw=False):
        """(status, samples): DEPTH words, oldest first unless raw."""
        W, D = self.W, self.D
        v = self.user_dr(self.dat, (D + 1) * W, 0)
        words = [(v >> (W * i)) & ((1 << W) - 1) for i in range(D + 1)]
        st = self.decode_status(words[0])
        samples = words[1:]
        if not raw:
            samples = samples[st['waddr']:] + samples[:st['waddr']]
        return st, samples


# ---- the probe map and its grouping into buses ----
def load_map(path):
    names = {}
    for l in open(path):
        k, n = l.split(); names[int(k)] = n
    return names


def buses_of(names, width):
    """[(bus name, [bit indices low..high])] from the map, or one per bit if none."""
    cols = [(k, names[k]) for k in sorted(names)] if names else [(k, f'p{k}') for k in range(width)]
    buses = []
    for k, n in cols:
        b = n.rsplit('[', 1)[0] if n.endswith(']') else n
        if buses and buses[-1][0] == b: buses[-1][1].append(k)
        else: buses.append((b, [k]))
    return buses


def field(v, bits):
    return sum(((v >> b) & 1) << i for i, b in enumerate(bits))


def write_vcd(path, buses, samples, clk_ns):
    with open(path, 'w') as f:
        f.write('$timescale 1ps $end\n$scope module ila $end\n')
        ids = {}
        for j, (b, bits) in enumerate(buses):
            ids[b] = chr(33 + j) if j < 90 else f'v{j}'
            f.write(f'$var wire {len(bits)} {ids[b]} {b} $end\n')
        f.write('$upscope $end\n$enddefinitions $end\n')
        last = {}
        for i, v in enumerate(samples):
            f.write(f'#{int(i * clk_ns * 1000)}\n')
            for b, bits in buses:
                x = field(v, bits)
                if last.get(b) != x:
                    f.write(f'{x}{ids[b]}\n' if len(bits) == 1 else f'b{x:b} {ids[b]}\n'); last[b] = x


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--width', type=int, default=64)
    ap.add_argument('--depth', type=int, default=1024)
    ap.add_argument('--ctl', type=int, default=2)
    ap.add_argument('--dat', type=int, default=3)
    ap.add_argument('--ofl', default=None)
    ap.add_argument('--cable', default='digilent')
    ap.add_argument('--freq', type=int, default=15000000)
    ap.add_argument('--clk-ns', type=float, default=8.0)
    sub = ap.add_subparsers(dest='cmd', required=True)
    a = sub.add_parser('arm'); a.add_argument('--mask', default='0'); a.add_argument('--value', default='0'); a.add_argument('--post', type=int, default=None)
    sub.add_parser('disarm'); sub.add_parser('status')
    r = sub.add_parser('read'); r.add_argument('--vcd'); r.add_argument('--map'); r.add_argument('--raw', action='store_true')
    o = ap.parse_args()
    ila = Openila(o.width, o.depth, o.ctl, o.dat, o.ofl, o.cable, o.freq)
    try:
        if o.cmd == 'status':
            print(Openila.status_text(ila.status()))
        elif o.cmd == 'disarm':
            ila.disarm(); print('disarmed')
        elif o.cmd == 'arm':
            post = o.post if o.post is not None else o.depth // 2
            mask, value = int(o.mask, 16), int(o.value, 16)
            ila.arm(mask, value, post)
            print(f'armed: mask={mask:x} value={value:x} post={post}')
        elif o.cmd == 'read':
            names = load_map(o.map) if o.map else {}
            st, samples = ila.read(o.raw)
            print(Openila.status_text(st))
            buses = buses_of(names, o.width)
            wid = {b: max(len(b), (len(bits) + 3) // 4) for b, bits in buses}
            print(f'{"#":>5} ' + ' '.join(f'{b:>{wid[b]}}' for b, _ in buses))
            for i, v in enumerate(samples):
                print(f'{i:5d} ' + ' '.join(f'{field(v, bits):>{wid[b]}x}' for b, bits in buses))
            if o.vcd:
                write_vcd(o.vcd, buses, samples, o.clk_ns)
                print(f'wrote {o.vcd}', file=sys.stderr)
    except RuntimeError as e:
        sys.exit(str(e))


if __name__ == '__main__':
    main()
