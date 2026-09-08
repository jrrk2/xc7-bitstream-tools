################################################################################
# IO constraints
################################################################################
# clk200:0.p
set_property LOC E19 [get_ports {clk200_p}]
set_property IOSTANDARD LVDS [get_ports {clk200_p}]

# clk200:0.n
set_property LOC E18 [get_ports {clk200_n}]
set_property IOSTANDARD LVDS [get_ports {clk200_n}]

# sdcard:0.clk
set_property LOC AN30 [get_ports {sdcard_clk}]
set_property IOSTANDARD LVCMOS18 [get_ports {sdcard_clk}]

# sdcard:0.cmd
set_property LOC AP30 [get_ports {sdcard_cmd}]
set_property IOSTANDARD LVCMOS18 [get_ports {sdcard_cmd}]

# sdcard:0.det
set_property LOC AP32 [get_ports {sdcard_det}]
set_property IOSTANDARD LVCMOS18 [get_ports {sdcard_det}]

# sdcard:0.wp
set_property LOC AR32 [get_ports {sdcard_wp}]
set_property IOSTANDARD LVCMOS18 [get_ports {sdcard_wp}]

# sdcard:0.data
set_property LOC AR30 [get_ports {sdcard_data[0]}]
set_property IOSTANDARD LVCMOS18 [get_ports {sdcard_data[0]}]

# sdcard:0.data
set_property LOC AU31 [get_ports {sdcard_data[1]}]
set_property IOSTANDARD LVCMOS18 [get_ports {sdcard_data[1]}]

# sdcard:0.data
set_property LOC AV31 [get_ports {sdcard_data[2]}]
set_property IOSTANDARD LVCMOS18 [get_ports {sdcard_data[2]}]

# sdcard:0.data
set_property LOC AT30 [get_ports {sdcard_data[3]}]
set_property IOSTANDARD LVCMOS18 [get_ports {sdcard_data[3]}]

# user_led:0
set_property LOC AM39 [get_ports {user_led0}]
set_property IOSTANDARD LVCMOS18 [get_ports {user_led0}]

# user_led:1
set_property LOC AN39 [get_ports {user_led1}]
set_property IOSTANDARD LVCMOS18 [get_ports {user_led1}]

# user_led:2
set_property LOC AR37 [get_ports {user_led2}]
set_property IOSTANDARD LVCMOS18 [get_ports {user_led2}]

# user_led:3
set_property LOC AT37 [get_ports {user_led3}]
set_property IOSTANDARD LVCMOS18 [get_ports {user_led3}]

# user_led:4
set_property LOC AR35 [get_ports {user_led4}]
set_property IOSTANDARD LVCMOS18 [get_ports {user_led4}]

# user_led:5
set_property LOC AP41 [get_ports {user_led5}]
set_property IOSTANDARD LVCMOS18 [get_ports {user_led5}]

# user_led:6
set_property LOC AP42 [get_ports {user_led6}]
set_property IOSTANDARD LVCMOS18 [get_ports {user_led6}]

# user_led:7
set_property LOC AU39 [get_ports {user_led7}]
set_property IOSTANDARD LVCMOS18 [get_ports {user_led7}]

################################################################################
# Design constraints
################################################################################

set_property CFGBVS VCCO [current_design]

set_property CONFIG_VOLTAGE 2.5 [current_design]

################################################################################
# Clock constraints
################################################################################


create_clock -name sys_clk -period 20.0 [get_nets sys_clk]

create_clock -name clk200_p -period 5.0 [get_ports clk200_p]

################################################################################
# False path constraints
################################################################################


set_false_path -quiet -to [get_cells -hierarchical -filter {mr_ff == TRUE}]

set_false_path -quiet -to [get_pins -filter {REF_PIN_NAME == PRE} -of_objects [get_cells -hierarchical -filter {ars_ff1 == TRUE || ars_ff2 == TRUE}]]

set_max_delay 2 -quiet -from [get_pins -filter {REF_PIN_NAME == C} -of_objects [get_cells -hierarchical -filter {ars_ff1 == TRUE}]] -to [get_pins -filter {REF_PIN_NAME == D} -of_objects [get_cells -hierarchical -filter {ars_ff2 == TRUE}]]