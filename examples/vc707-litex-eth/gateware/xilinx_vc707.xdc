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

# eth:0.rst_n
set_property LOC AJ33 [get_ports {eth_rst_n}]
set_property IOSTANDARD LVCMOS18 [get_ports {eth_rst_n}]

# eth:0.int_n
set_property LOC AL31 [get_ports {eth_int_n}]
set_property IOSTANDARD LVCMOS18 [get_ports {eth_int_n}]

# eth:0.mdio
set_property LOC AK33 [get_ports {eth_mdio}]
set_property IOSTANDARD LVCMOS18 [get_ports {eth_mdio}]

# eth:0.mdc
set_property LOC AH31 [get_ports {eth_mdc}]
set_property IOSTANDARD LVCMOS18 [get_ports {eth_mdc}]

# eth:0.rx_p
set_property LOC AM8 [get_ports {eth_rx_p}]

# eth:0.rx_n
set_property LOC AM7 [get_ports {eth_rx_n}]

# eth:0.tx_p
set_property LOC AN2 [get_ports {eth_tx_p}]

# eth:0.tx_n
set_property LOC AN1 [get_ports {eth_tx_n}]

# sgmii_clock:0.p
set_property LOC AH8 [get_ports {sgmii_clock_p}]

# sgmii_clock:0.n
set_property LOC AH7 [get_ports {sgmii_clock_n}]

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

create_clock -name sgmii_clock_p -period 8.0 [get_ports sgmii_clock_p]

create_clock -name eth_tx_clk -period 8.0 [get_nets eth_tx_clk]

create_clock -name eth_rx_clk -period 8.0 [get_nets eth_rx_clk]

################################################################################
# False path constraints
################################################################################


set_false_path -quiet -to [get_cells -hierarchical -filter {mr_ff == TRUE}]

set_false_path -quiet -to [get_pins -filter {REF_PIN_NAME == PRE} -of_objects [get_cells -hierarchical -filter {ars_ff1 == TRUE || ars_ff2 == TRUE}]]

set_max_delay 2 -quiet -from [get_pins -filter {REF_PIN_NAME == C} -of_objects [get_cells -hierarchical -filter {ars_ff1 == TRUE}]] -to [get_pins -filter {REF_PIN_NAME == D} -of_objects [get_cells -hierarchical -filter {ars_ff2 == TRUE}]]

set_clock_groups -group [get_clocks -of [get_nets eth_tx_clk]] -group [get_clocks -of [get_nets eth_rx_clk]] -asynchronous

set_clock_groups -group [get_clocks -of [get_nets eth_tx_clk]] -group [get_clocks -of [get_nets sys_clk]] -asynchronous

set_clock_groups -group [get_clocks -of [get_nets eth_rx_clk]] -group [get_clocks -of [get_nets sys_clk]] -asynchronous
# Hard-block placement, taken from the Vivado implementation of THIS design
# (examples/vc707-litex/build-eth/gateware/xilinx_vc707_clock_utilization.rpt,
# which emits its own set_property LOC lines; the MMCM rows name the instance
# in their last column).
#
# The transceiver's clocks reach only a few clock buffers, and which region a
# buffer sits in decides whether they reach it at all.  Left to itself the
# placer put them where the GT could not drive them.
#
# The three BUFHs are BUFGs here (see README): a BUFH drives one clock region
# and its loads must be placed inside it, which needs region-constrained
# placement; a BUFG drives the whole device and needs none.  So they carry no
# LOC -- the placer is free to choose among the global buffers.
set_property LOC GTXE2_CHANNEL_X1Y1 [get_cells GTXE2_CHANNEL]
set_property LOC MMCME2_ADV_X1Y5 [get_cells MMCME2_ADV]
set_property LOC MMCME2_ADV_X0Y0 [get_cells MMCME2_ADV_1]
set_property LOC MMCME2_ADV_X0Y3 [get_cells MMCME2_ADV_2]
set_property LOC BUFGCTRL_X0Y16 [get_cells BUFG]
set_property LOC BUFGCTRL_X0Y2 [get_cells BUFG_1]
set_property LOC BUFGCTRL_X0Y0 [get_cells BUFG_2]
set_property LOC BUFGCTRL_X0Y1 [get_cells BUFG_3]
