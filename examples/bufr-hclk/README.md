# Testing the virtex7 HCLK regional-clock rows on hardware

*2026-09-23.*  prjxray's virtex7 database gained the HCLK regional-clock
rows -- the `HCLK_L.ENABLE_BUFFER.HCLK_CK_BUFRCLK*` bits and the
`HCLK_IOI` BUFR/BUFIO rows -- from the fuzzer campaigns in
openXC7/nextpnr#32.  Nothing in the flow used a BUFR, so nothing exercised
them.  This does, and on a VC707.

`vc707_bufr.v` takes the 200 MHz board clock through `IBUFDS` into a
**BUFR** dividing by 8, and that regional clock -- nothing else -- drives a
28-bit counter whose top bits are the LEDs.  If the enable-buffer or
HCLK_IOI rows are wrong, the regional clock is dead and the LEDs stand
still.

    vivado -mode batch -source build.tcl                       # out/vc707_bufr.bit
    bit2fasm.py --db-root ~/prjxray/database/virtex7 ... > bufr.fasm
    fasm2frames.py --db-root ~/prjxray/database/virtex7 ... bufr.fasm bufr.frames
    xc7frames2bit --part_file .../part.yaml --frm_file bufr.frames --output_file bufr_rt.bit
    openFPGALoader --cable digilent bufr_rt.bit

The point of the round trip is that `bufr_rt.bit` is built **only** from
what the database knows: Vivado's bitstream is decoded to FASM and the
FASM assembled again.  The decode names the new rows

    HCLK_L_X195Y286.ENABLE_BUFFER.HCLK_CK_BUFRCLK3
    HCLK_IOI_X311Y286.BUFR_Y1.IN_USE
    HCLK_IOI_X311Y286.BUFR_Y1.BUFR_DIVIDE.D8
    HCLK_IOI_X311Y286.HCLK_IOI_RCLK_BEFORE_DIV3.HCLK_IOI_RCLK0

and re-decoding `bufr_rt.bit` gives the same 864 features but one
(`IBUFDS_BANK_GLUE`, which the assembler adds).  On the board the
re-assembled bitstream counts: the LEDs walk, and two state captures
(`openFPGALoader --readback --capture`) differ in the same handful of
flip-flops each time.

**Not covered:** the BUFIO rows.  A BUFIO output can only clock IO logic,
so exercising those needs an ODDR on a pin in the BUFIO's own bank; this
design is about the BUFR path.
