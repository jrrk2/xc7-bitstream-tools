# sd_model.sv

Imported from lowrisc-chip, src/test/verilog/sd_verilator_model.sv, which is
itself OpenCores' sdModel.v by Adam Edvardsson (ORSoC), from the
sdcard_mass_storage_controller project.  LGPL 2.1 or later; the copyright
notice and disclaimer at the head of the file are kept intact as that licence
requires.

Same lineage as rtl-deps/sd-card-controller, which is the controller side of
the same OpenCores project.

Modernisation applied here is recorded in the file itself, each change beside
the line it touches.  The interface is unchanged:

    sdClk, cmd, cmdOut, oeCmd, dat[3:0], datOut[3:0], oeDat

which is the split in/out/oe form, so the testbench owns the bidirectional
resolution rather than the model.
