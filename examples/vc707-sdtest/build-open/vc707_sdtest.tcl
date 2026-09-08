
# Create Project

create_project -force -name vc707_sdtest -part xc7vx485tffg1761-2
set_msg_config -id {Common 17-55} -new_severity {Warning}

# Add project commands


# Add Sources

read_verilog {/home/jonathan/xc7-bitstream-tools/examples/vc707-sdtest/build-open/vc707_sdtest.v}

# Add EDIFs


# Add IPs


# Add constraints

read_xdc vc707_sdtest.xdc
set_property PROCESSING_ORDER EARLY [get_files vc707_sdtest.xdc]

# Add pre-synthesis commands


# Synthesis

synth_design -directive default -top vc707_sdtest -part xc7vx485tffg1761-2

# Synthesis report

report_timing_summary -file vc707_sdtest_timing_synth.rpt
report_utilization -hierarchical -file vc707_sdtest_utilization_hierarchical_synth.rpt
report_utilization -file vc707_sdtest_utilization_synth.rpt
write_checkpoint -force vc707_sdtest_synth.dcp

# Add pre-optimize commands


# Optimize design

opt_design -directive default

# Add pre-placement commands


# Placement

place_design -directive default

# Placement report

report_utilization -hierarchical -file vc707_sdtest_utilization_hierarchical_place.rpt
report_utilization -file vc707_sdtest_utilization_place.rpt
report_io -file vc707_sdtest_io.rpt
report_control_sets -verbose -file vc707_sdtest_control_sets.rpt
report_clock_utilization -file vc707_sdtest_clock_utilization.rpt
write_checkpoint -force vc707_sdtest_place.dcp

# Add pre-routing commands


# Routing

route_design -directive default
phys_opt_design -directive default
write_checkpoint -force vc707_sdtest_route.dcp

# Routing report

report_timing_summary -no_header -no_detailed_paths
report_route_status -file vc707_sdtest_route_status.rpt
report_drc -file vc707_sdtest_drc.rpt
report_timing_summary -datasheet -max_paths 10 -file vc707_sdtest_timing.rpt
report_power -file vc707_sdtest_power.rpt

# Bitstream generation

write_bitstream -force vc707_sdtest.bit 

# End

quit