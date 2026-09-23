"""A line-oriented reader for FASM, in place of the fasm package's textX parser.

The fasm package ships two parsers: an ANTLR one behind a Cython extension
(`fasm/parser/antlr_to_tuple.pyx`), and a textX fallback.  The wheel installed
here has the .pyx but no built extension, so every import prints "Unable to
import fast Antlr4 parser implementation" and silently takes the fallback.

That fallback costs 5356 lines/s.  A Rocket bitstream's FASM is 1.7M lines, so
it spends ~325s of a 391s FASM-to-bitstream conversion just parsing -- 83% of
the total, on a grammar whose every line is "tile.feature[range] = value".  The
same file read with a regex, in the same Python, takes 1.4 seconds.  The gap is
not the language; it is asking a parser generator to build a model per line.

So this reads the lines directly and yields the fasm package's own namedtuples,
which is all `prjxray.fasm_assembler` wants -- it hands them straight back to
`fasm.canonical_features` and `fasm.fasm_line_to_string`.

Deliberately NOT a complete FASM implementation.  Anything outside the subset
below raises, because a reader that quietly mis-parsed a line would produce a
bitstream that differs from the reference one in ways nothing downstream would
catch.  Unsupported: annotations ({ .. }), and any line this regex rejects.
"""

import re

from fasm import FasmLine, SetFasmFeature, ValueFormat

# tile.feature, optionally [i] or [hi:lo], optionally "= value", optionally a
# "# comment"; a bare comment or a blank line has neither feature nor value.
_LINE = re.compile(
    r"""^[ \t]*
        (?:
          (?P<feature>[A-Za-z_][A-Za-z0-9_.]*)
          (?:\[(?P<hi>\d+)(?::(?P<lo>\d+))?\])?
          (?:[ \t]*=[ \t]*(?P<value>[^#\s][^#]*?))?
        )?
        [ \t]*
        (?:\#(?P<comment>.*))?
        $""",
    re.VERBOSE,
)

# 64'b1010..., 8'hff, 4'd9 -- underscores are legal separators in all of them.
_SIZED = re.compile(r"^(?P<width>\d+)'(?P<base>[bodhBODH])(?P<digits>[0-9a-fA-F_]+)$")

_BASES = {
    "b": (2, ValueFormat.VERILOG_BINARY),
    "o": (8, ValueFormat.VERILOG_OCTAL),
    "d": (10, ValueFormat.VERILOG_DECIMAL),
    "h": (16, ValueFormat.VERILOG_HEX),
}


def _parse_value(text, lineno):
    sized = _SIZED.match(text)
    if sized:
        radix, value_format = _BASES[sized.group("base").lower()]
        return int(sized.group("digits").replace("_", ""), radix), value_format
    if re.fullmatch(r"[0-9_]+", text):
        return int(text.replace("_", "")), ValueFormat.PLAIN
    raise ValueError("line %d: cannot read FASM value %r" % (lineno, text))


def parse_fasm_line(text, lineno=0):
    if "{" in text or "}" in text:
        raise ValueError(
            "line %d: FASM annotations are not supported by this reader; "
            "use fasm.parse_fasm_filename instead" % lineno)
    match = _LINE.match(text.rstrip("\n"))
    if match is None:
        raise ValueError("line %d: cannot read FASM line %r" % (lineno, text.rstrip("\n")))

    comment = match.group("comment")
    feature = match.group("feature")
    if feature is None:
        return FasmLine(set_feature=None, annotations=None, comment=comment)

    # "[hi:lo]" is start=lo end=hi; a single "[i]" is start=i end=None; no
    # brackets at all is start=None end=None.  (Matched against the reference
    # parser, which is the only definition of this that matters.)
    hi, lo = match.group("hi"), match.group("lo")
    if hi is None:
        start = end = None
    elif lo is None:
        start, end = int(hi), None
    else:
        start, end = int(lo), int(hi)

    raw = match.group("value")
    if raw is None:
        value, value_format = 1, None
    else:
        value, value_format = _parse_value(raw.strip(), lineno)
        # The reference parser asserts this, and a FASM that trips it is
        # malformed rather than merely unusual -- so fail here too rather than
        # let a too-wide value through to the assembler.
        width = (end - start + 1) if end is not None else 1
        if value >= (1 << width):
            raise ValueError("line %d: value %d does not fit in %d bit(s)"
                             % (lineno, value, width))

    return FasmLine(
        set_feature=SetFasmFeature(feature=feature, start=start, end=end,
                                   value=value, value_format=value_format),
        annotations=None,
        comment=comment,
    )


def parse_fasm_filename(filename, *args, **kwargs):
    with open(filename) as handle:
        for lineno, text in enumerate(handle, 1):
            yield parse_fasm_line(text, lineno)


def install():
    """Point fasm.parse_fasm_filename, and prjxray's copy of it, at this reader.

    Only the filename entry point: parse_fasm_string is left alone because its
    callers in fasm2frames pass a handful of lines each, so it is not worth the
    risk of a second implementation for no measurable gain.
    """
    import fasm
    fasm.parse_fasm_filename = parse_fasm_filename
    cache_grid()
    try:
        from prjxray import fasm_assembler
        fasm_assembler.fasm.parse_fasm_filename = parse_fasm_filename
    except ImportError:
        pass


def cache_grid():
    """Build prjxray's Grid once per Database, not once per call.

    Database.grid() constructs a fresh Grid every time, and fasm2frames calls
    it inside a loop over tiles: 46 builds of the same object at ~1.4s each,
    two thirds of the conversion.  The Grid is read-only once built, so one
    per database serves every caller.  A monkeypatch rather than a change to
    prjxray, for the reason at the top of fasm2frames_fast.py.
    """
    try:
        from prjxray import db as prjxray_db
    except ImportError:
        return
    if getattr(prjxray_db.Database, "_grid_cached", False):
        return
    original = prjxray_db.Database.grid

    def grid(self):
        cached = self.__dict__.get("_grid_cache")
        if cached is None:
            cached = self.__dict__["_grid_cache"] = original(self)
        return cached

    prjxray_db.Database.grid = grid
    prjxray_db.Database._grid_cached = True
