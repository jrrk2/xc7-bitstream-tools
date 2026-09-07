################################################################################
# IO constraints
################################################################################
# clk200:0.p
set_property LOC E19 [get_ports {clk200_p}]
set_property IOSTANDARD LVDS [get_ports {clk200_p}]

# clk200:0.n
set_property LOC E18 [get_ports {clk200_n}]
set_property IOSTANDARD LVDS [get_ports {clk200_n}]

# serial:0.rx
set_property LOC AU33 [get_ports {serial_rx}]
set_property IOSTANDARD LVCMOS18 [get_ports {serial_rx}]

# serial:0.tx
set_property LOC AU36 [get_ports {serial_tx}]
set_property IOSTANDARD LVCMOS18 [get_ports {serial_tx}]

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


create_clock -name sys_clk -period 40.0 [get_nets sys_clk]

create_clock -name clk200_p -period 5.0 [get_ports clk200_p]

################################################################################
# False path constraints
################################################################################


set_false_path -quiet -to [get_cells -hierarchical -filter {mr_ff == TRUE}]

set_false_path -quiet -to [get_pins -filter {REF_PIN_NAME == PRE} -of_objects [get_cells -hierarchical -filter {ars_ff1 == TRUE || ars_ff2 == TRUE}]]

set_max_delay 2 -quiet -from [get_pins -filter {REF_PIN_NAME == C} -of_objects [get_cells -hierarchical -filter {ars_ff1 == TRUE}]] -to [get_pins -filter {REF_PIN_NAME == D} -of_objects [get_cells -hierarchical -filter {ars_ff2 == TRUE}]]