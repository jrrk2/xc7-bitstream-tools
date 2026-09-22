#!/usr/bin/env python3
# A stand-in for openFPGALoader --user-dr: a 64x1024 openila that triggers at once.
import sys, json, os, random
W, D, AW = 64, 1024, 10
CW, SW = 2*W+AW+9, AW+11
state_p = os.path.join(os.path.dirname(__file__), 'state.json')
st = json.load(open(state_p)) if os.path.exists(state_p) else {'armed':0,'trig':0,'done':0,'waddr':0,'post':0}
spec = sys.argv[sys.argv.index('--user-dr')+1]
chain, nbits, hx = spec.split('/'); chain=int(chain); nbits=int(nbits); v=int(hx,16)
def status(): return (st['waddr'] | st['armed']<<AW | st['trig']<<(AW+1) | st['done']<<(AW+2) | 0x1A<<(AW+3))
if chain == 2:
    out = status()
    key = (v >> (2*W+AW+1)) & 0xff
    if key == 0x5A:
        arm = (v >> (2*W+AW)) & 1; post = (v >> (2*W)) & ((1<<AW)-1)
        if arm and not st['armed']:
            st.update(armed=1, trig=1, done=1, post=post, waddr=(post+1) % D)   # trigger at sample 0 of a fresh run
        elif not arm:
            st.update(armed=0, trig=0, done=0)
    json.dump(st, open(state_p,'w'))
    print(f"USER2 out {out:0{(nbits+3)//4}x}")
else:
    words = [status()]
    for i in range(D):
        t = (i - st['waddr']) % D          # sample index in time order
        cnt = t & 0xff; lfsr = (t*7919) & 0xffff
        words.append(cnt | lfsr<<8 | (t>>2 & 0xf)<<24 | (0x5 if (t//16)%2 else 0xa)<<28 | (t & 0x3)<<32 | (t*3 & 0x3ffff)<<36)
    val = 0
    for i,w in enumerate(words): val |= w << (W*i)
    print(f"USER3 out {val:0{(nbits+3)//4}x}")
