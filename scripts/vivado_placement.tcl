# vivado_placement.tcl <routed.dcp> <out.tsv> -- every placed cell's site and BEL.
#
# The extractor names what it finds in a bitstream by tile and site; a
# design's own names come from a placement.  nextpnr writes one (-o
# placement=), Vivado does not, so this dumps the equivalent from a routed
# checkpoint, and scripts/vivado_place2json.py turns it into the JSON the
# extractor and the LVS read.
#
#   vivado -mode batch -source scripts/vivado_placement.tcl -tclargs routed.dcp place.tsv
set dcp [lindex $argv 0]
set out [lindex $argv 1]
open_checkpoint $dcp
set fh [open $out w]
puts $fh "cell\tref\tbel\tsite"
foreach c [get_cells -hierarchical -filter {IS_PRIMITIVE && PRIMITIVE_LEVEL != INTERNAL}] {
    set site [get_property LOC $c]
    if {$site eq ""} continue
    puts $fh "[get_property NAME $c]\t[get_property REF_NAME $c]\t[get_property BEL $c]\t$site"
}
close $fh
puts "PLACEMENT_DUMP_DONE"
