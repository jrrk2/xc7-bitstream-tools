#!/usr/bin/env python3
"""Make the IOP accept a terminal BREAK while the line is waiting for input.

The original multiplexer driver (ABORT in tsb_f_iop.asm) ignores BREAK unless the line is in output mode, so a program sitting at an
INPUT prompt (e.g. the *LANDER game) cannot be interrupted.  Three NOPs replace `AND NIBT / SZA,RSS / JMP MPXEP`; paper-tape mode is
still ignored by the test before them.  usage: patch_iop_break.py src/tsb_f_iop.asm build/iop_brk.asm"""
import sys
s = open(sys.argv[1]).read()
old = """      AND NIBT      CHECK FOR 
      SZA,RSS         OUTPUT MODE 
      JMP MPXEP     INPUT MODE - IGNORE 
"""
new = """      NOP           (PATCH) BREAK IS ACCEPTED IN INPUT MODE TOO 
      NOP 
      NOP 
"""
assert s.count(old) == 1, "IOP source does not match the expected ABORT routine"
open(sys.argv[2], "w").write(s.replace(old, new))
