#!/usr/bin/env python3
"""Absolute assembler for the HP 2100 ASMB subset used by the HP 2000 TSB sources.

Usage: hpasm.py src.asm [-o out.mem] [-l out.lst] [-s out.sym]
Outputs a 32K-word image as one octal word per line ("addr word"), only for written cells.
"""
import re
import sys
import argparse

MEMREF = {'AND': 0o010000, 'XOR': 0o020000, 'IOR': 0o030000, 'JSB': 0o014000,
          'JMP': 0o024000, 'ISZ': 0o034000, 'ADA': 0o040000, 'ADB': 0o044000,
          'CPA': 0o050000, 'CPB': 0o054000, 'LDA': 0o060000, 'LDB': 0o064000,
          'STA': 0o070000, 'STB': 0o074000}

# Alter-skip group; B-register ops set bit 11.
ASG_COMMON = {'CLE': 0o100, 'CME': 0o200, 'CCE': 0o300, 'SEZ': 0o040, 'RSS': 0o001}
ASG_A = {'CLA': 0o400, 'CMA': 0o1000, 'CCA': 0o1400, 'SSA': 0o020, 'SLA': 0o010,
         'INA': 0o004, 'SZA': 0o002}
ASG_B = {'CLB': 0o400, 'CMB': 0o1000, 'CCB': 0o1400, 'SSB': 0o020, 'SLB': 0o010,
         'INB': 0o004, 'SZB': 0o002}

SHIFT_TYPES = ['LS', 'RS', 'RL', 'RR', 'LR', 'ER', 'EL', 'LF']  # ALS ARS RAL RAR ALR ERA ELA ALF
SRG = {}
for reg, bit in (('A', 0), ('B', 0o4000)):
    for i, t in enumerate(SHIFT_TYPES):
        if t.startswith('E'):
            name = t[:2] + reg            # ERA / ERB, ELA / ELB
        elif t in ('RL', 'RR'):
            name = 'R' + reg + t[1]       # RAL RAR / RBL RBR
        else:
            name = reg + t                # ALS ARS ALR ALF
        SRG[name] = (bit, i)
SRG_FLAGS = {'CLE': 0o40, 'SLA': 0o10, 'SLB': 0o10}

IO = {'HLT': 0o102000, 'STF': 0o102100, 'CLF': 0o103100, 'SFC': 0o102200,
      'SFS': 0o102300, 'MIA': 0o102400, 'MIB': 0o106400, 'LIA': 0o102500,
      'LIB': 0o106500, 'OTA': 0o102600, 'OTB': 0o106600, 'STC': 0o102700,
      'CLC': 0o106700, 'STO': 0o102101, 'CLO': 0o103101, 'SOC': 0o102201,
      'SOS': 0o102301}
IO_NOOPERAND = {'STO', 'CLO', 'SOC', 'SOS'}

EAG = {'MPY': 0o100200, 'DIV': 0o100400, 'DLD': 0o104200, 'DST': 0o104400}
EAG_SHIFT = {'ASR': 0o101020, 'ASL': 0o100020, 'LSR': 0o101040, 'LSL': 0o100040,
             'RRR': 0o101100, 'RRL': 0o100100}
FP_MEM = {'FAD': 0o105000, 'FSB': 0o105020, 'FMP': 0o105040, 'FDV': 0o105060}
FP_NOMEM = {'FIX': 0o105100, 'FLT': 0o105120}

IGNORED = {'HED', 'SKP', 'SPC', 'UNL', 'LST', 'SUP', 'UNS', 'NAM', 'ASMB', 'RPL'}


class AsmError(Exception):
    pass


def hp_float(text):
    """Encode a decimal string as a 2-word HP 2100 floating-point number."""
    v = float(text)
    if v == 0.0:
        return [0, 0]
    sign = v < 0
    m = abs(v)
    e = 0
    while m >= 1.0:
        m /= 2.0
        e += 1
    while m < 0.5:
        m *= 2.0
        e -= 1
    frac = int(round(m * (1 << 23)))
    if frac >= (1 << 23):
        frac >>= 1
        e += 1
    if sign:
        frac = (-frac) & 0xFFFFFF
        if frac == 0x800000 - 0 and False:
            pass
    ex = ((e & 0x7F) << 1) | (1 if e < 0 else 0)
    return [(frac >> 8) & 0xFFFF, ((frac & 0xFF) << 8) | ex]


class Assembler:
    def __init__(self):
        self.sym = {}
        self.segs = []
        self.listing = []
        self.errors = []

    # ---------------- expressions ----------------
    def number(self, tok):
        if re.fullmatch(r'[0-7]+B', tok):
            return int(tok[:-1], 8)
        if re.fullmatch(r'[0-9]+', tok):
            return int(tok)
        if re.fullmatch(r'[0-9]+D', tok):
            return int(tok[:-1])
        return None

    def term(self, tok, loc, pass2):
        if tok == '*':
            return loc
        n = self.number(tok)
        if n is not None:
            return n
        key = tok[:5]
        if key in self.sym:
            return self.sym[key]
        if pass2:
            raise AsmError('undefined symbol ' + tok)
        return 0

    def expr(self, text, loc, pass2):
        text = text.strip()
        if not text:
            raise AsmError('empty expression')
        toks = re.findall(r"\*|[+\-]|[^+\-*]+", text)
        # A '*' directly after an operator or at start is the location counter.
        # Re-join: tokens other than operators/'*' are operands.
        val = 0
        op = '+'
        expect_term = True
        sign = 1
        i = 0
        while i < len(toks):
            t = toks[i]
            if expect_term and t in '+-' and len(t) == 1:
                sign = -sign if t == '-' else sign
                i += 1
                continue
            if expect_term:
                v = self.term(t, loc, pass2) * sign
                if op == '+':
                    val += v
                elif op == '-':
                    val -= v
                elif op == '*':
                    val *= v
                sign = 1
                expect_term = False
            else:
                if t not in ('+', '-'):
                    raise AsmError('bad expression ' + text)
                op = t
                expect_term = True
            i += 1
        return val

    # ---------------- line parsing ----------------
    def split(self, line):
        """Return (label, opcode, operand, rawtail) for a source line."""
        line = line.rstrip('\r\n').expandtabs(8)
        if not line.strip() or line[0] == '*':
            return None
        label = ''
        if line.startswith('ASMB'):
            return None
        if line[0] != ' ':
            parts = line.split(None, 1)
            label = parts[0]
            rest = parts[1] if len(parts) > 1 else ''
            if not rest:
                return label, '', '', ''
            # find the exact position after the label for ASC handling
            rest = line[len(label):]
        else:
            rest = line
        rest = rest.lstrip(' ')
        parts = rest.split(' ', 1)
        opcode = parts[0]
        tail = parts[1] if len(parts) > 1 else ''
        return label, opcode, tail.lstrip(' ') if opcode not in ('ASC',) else tail, tail

    def assemble(self, lines):
        for pass2 in (False, True):
            self.segs = []
            loc = 0
            self.loc_hist = []
            rep = 0
            skipping = False
            stop = False
            for n, line in enumerate(lines, 1):
                if stop:
                    break
                try:
                    line = ''.join(c if c == '\n' or 32 <= ord(c) < 127 else ' ' for c in line)
                    if skipping:
                        if line.split()[:1] == ['XIF'] or line[6:9] == 'XIF':
                            skipping = False
                        continue
                    r = self.split(line)
                    if r is None:
                        continue
                    label, op, tail, raw = r
                    if label and not pass2 and op != 'EQU':
                        self.sym[label[:5]] = loc
                    if label and op == 'EQU':
                        pass
                    if not op:
                        continue
                    if op in ('IFZ', 'IFN'):
                        skipping = True   # only used for 2000C-only code; condition not modelled
                        continue
                    if op == 'XIF':
                        continue
                    count = 1
                    if rep:
                        count, rep = rep, 0
                    for _ in range(count):
                        loc, flag = self.stmt(label, op, tail, raw, loc, pass2, n)
                        if flag == 'END':
                            stop = True
                            break
                        if isinstance(flag, tuple) and flag[0] == 'REP':
                            rep = flag[1]
                except (AsmError, ValueError) as e:
                    if pass2:
                        self.errors.append('%d: %s: %s' % (n, e, line.strip()))
        return self.errors

    # ---------------- statements ----------------
    def emit(self, loc, word, pass2):
        """Append a word. Output is a list of segments because TSB overlays library
        routines at the same origin (ORG LIBRA); each ORG/BSS gap starts a new segment."""
        if pass2:
            if not self.segs or self.segs[-1][0] + len(self.segs[-1][1]) != loc:
                self.segs.append((loc, []))
            self.segs[-1][1].append(word & 0xFFFF)
        return loc + 1

    def addr_field(self, operand, loc, pass2):
        """Parse 'expr[,I]' returning (addr, indirect)."""
        ind = False
        o = operand.split(' ')[0]
        if o.endswith(',I'):
            ind = True
            o = o[:-2]
        return self.expr(o, loc, pass2), ind

    def stmt(self, label, op, tail, raw, loc, pass2, lineno):
        opfield = op.split(',')
        base = opfield[0]
        operand = tail.split(' ')[0] if tail else ''
        e = lambda s: self.expr(s, loc, pass2)

        if base in IGNORED and len(opfield) >= 1 and base in IGNORED:
            return loc, None
        if base == 'ORG':
            return e(operand), None
        if base == 'EQU':
            self.sym[label[:5]] = e(operand)
            return loc, None
        if base == 'END':
            return loc, 'END'
        if base == 'REP':
            return loc, ('REP', e(operand))
        if base == 'BSS':
            return loc + e(operand), None
        if base == 'ABS':
            return self.emit(loc, e(operand), pass2), None
        if base == 'DEF':
            a, ind = self.addr_field(operand, loc, pass2)
            return self.emit(loc, (a & 0x7FFF) | (0x8000 if ind else 0), pass2), None
        if base == 'OCT':
            for t in operand.split(','):
                t = t.strip()
                v = int(t, 8) if not t.startswith('-') else -int(t[1:], 8)
                loc = self.emit(loc, v, pass2)
            return loc, None
        if base == 'DEC':
            for t in operand.split(','):
                t = t.strip()
                if re.search(r'[.E]', t):
                    m = re.fullmatch(r'([-+]?[0-9.]+(?:E[-+]?[0-9]+)?)', t)
                    if not m:
                        raise AsmError('bad DEC ' + t)
                    for w in hp_float(t):
                        loc = self.emit(loc, w, pass2)
                elif t.endswith('D'):
                    v = int(t[:-1]) & 0xFFFFFFFF
                    loc = self.emit(loc, v >> 16, pass2)
                    loc = self.emit(loc, v, pass2)
                else:
                    loc = self.emit(loc, int(t), pass2)
            return loc, None
        if base == 'ASC':
            m = re.match(r'(\d+),(.*)$', tail.rstrip('\n'))
            if not m:
                raise AsmError('bad ASC')
            nw = int(m.group(1))
            text = m.group(2).ljust(2 * nw)[:2 * nw]
            for i in range(nw):
                loc = self.emit(loc, (ord(text[2 * i]) << 8) | ord(text[2 * i + 1]), pass2)
            return loc, None
        if base == 'NOP' and len(opfield) == 1:
            return self.emit(loc, 0, pass2), None

        # memory reference
        if base in MEMREF:
            a, ind = self.addr_field(operand, loc, pass2)
            w = MEMREF[base] | (0o100000 if ind else 0)
            if a < 0o2000:
                w |= a
            elif (a >> 10) == (loc >> 10):
                w |= 0o2000 | (a & 0o1777)
            elif pass2:
                raise AsmError('page error: %o from %o' % (a, loc))
            return self.emit(loc, w, pass2), None
        # I/O group
        if base in IO:
            w = IO[base]
            if base not in IO_NOOPERAND and operand:
                parts = operand.split(',')
                w |= self.expr(parts[0], loc, pass2) & 0o77
                if len(parts) > 1 and parts[1] == 'C':
                    w |= 0o1000
            elif base == 'HLT' and not operand:
                pass
            return self.emit(loc, w, pass2), None
        if base in EAG or base in FP_MEM:
            loc = self.emit(loc, EAG.get(base) or FP_MEM[base], pass2)
            a, ind = self.addr_field(operand, loc, pass2)
            return self.emit(loc, (a & 0x7FFF) | (0x8000 if ind else 0), pass2), None
        if base == 'SWP':
            return self.emit(loc, 0o101100, pass2), None
        if base in EAG_SHIFT:
            n = e(operand) & 0o17
            return self.emit(loc, EAG_SHIFT[base] | n, pass2), None
        if base in FP_NOMEM:
            return self.emit(loc, FP_NOMEM[base], pass2), None

        # micro-op groups (ASG / SRG), comma separated in the opcode field
        w = 0
        reg_b = False
        kind = None
        shifts = []
        for o in opfield:
            if o in ASG_COMMON or o in ASG_A or o in ASG_B:
                if kind == 'SRG' and o in ('CLE', 'SLA', 'SLB'):
                    pass
                else:
                    kind = kind or 'ASG'
            if o in SRG:
                kind = 'SRG'
        if kind == 'SRG':
            # Micro-ops execute in hardware order: shift1, CLE, SLx, shift2.  The assembler places each
            # shift in the first slot unless a CLE/SLx has already been written (or slot 1 is taken).
            flag_seen = False
            slot1 = slot2 = None
            for o in opfield:
                if o in SRG:
                    b, t = SRG[o]
                    if b:
                        w |= 0o4000
                    if slot1 is None and not flag_seen:
                        slot1 = t
                    elif slot2 is None:
                        slot2 = t
                    else:
                        raise AsmError('too many shifts')
                elif o in SRG_FLAGS:
                    w |= SRG_FLAGS[o]
                    flag_seen = True
                elif o == 'NOP':
                    pass
                else:
                    raise AsmError('bad shift micro-op ' + o)
            if slot1 is not None:
                w |= 0o1000 | (slot1 << 6)
            if slot2 is not None:
                w |= 0o20 | slot2
            return self.emit(loc, w, pass2), None
        if kind == 'ASG':
            w = 0o2000
            for o in opfield:
                if o in ASG_A:
                    w |= ASG_A[o]
                elif o in ASG_B:
                    w |= ASG_B[o]
                    reg_b = True
                elif o in ASG_COMMON:
                    w |= ASG_COMMON[o]
                elif o == 'NOP':
                    pass
                else:
                    raise AsmError('bad ASG micro-op ' + o)
            if reg_b:
                w |= 0o4000
            return self.emit(loc, w, pass2), None
        raise AsmError('unknown opcode ' + op)


def split_programs(lines):
    progs, cur = [], []
    for ln in lines:
        if ln.startswith('ASMB') and cur:
            progs.append(cur)
            cur = []
        cur.append(ln)
    if cur:
        progs.append(cur)
    return progs


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('src')
    ap.add_argument('-o', help='output prefix; writes PREFIX.N.mem and PREFIX.N.sym per program')
    a = ap.parse_args()
    with open(a.src, errors='replace') as f:
        lines = f.readlines()
    rc = 0
    for n, prog in enumerate(split_programs(lines)):
        asm = Assembler()
        errs = asm.assemble(prog)
        for e in errs[:50]:
            print('ERROR prog%d %s' % (n, e), file=sys.stderr)
        print('prog%d: %d words, %d symbols, %d errors' % (n, sum(len(w) for _, w in asm.segs), len(asm.sym), len(errs)),
              file=sys.stderr)
        rc |= bool(errs)
        if a.o:
            with open('%s.%d.seg' % (a.o, n), 'w') as f:
                for start, words in asm.segs:
                    f.write('@%05o\n' % start)
                    for i in range(0, len(words), 8):
                        f.write(' '.join('%06o' % w for w in words[i:i + 8]) + '\n')
            with open('%s.%d.sym' % (a.o, n), 'w') as f:
                for k, v in sorted(asm.sym.items(), key=lambda kv: kv[1]):
                    f.write('%-6s %06o\n' % (k, v & 0xFFFF))
    return rc


if __name__ == '__main__':
    sys.exit(main())
