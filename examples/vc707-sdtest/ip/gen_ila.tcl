# Generate the ILA IP, following the pattern in cva6's xlnx_ila.
# Probes, in order:
#   0  step        4   which command the FSM is on
#   1  stop        3   why it stopped
#   2  cmd_event   4   the core's command status: done/timeout/CRC
#   3  data_event  4   the same for the data phase
#   4  send        1   the FSM's write strobe into the core
#   5  phy_init    1   the PHY initialisation strobe
#   6  command    16   opcode and response type as issued
#   7  sd_bus      8   clk, cmd o/oe/i, dat i[3:0] on the fabric side of the pads
#   8  clocker     2   the SD clock and its enable
set ipName sdtest_ila
create_project $ipName . -force -part xc7vx485tffg1761-2
create_ip -name ila -vendor xilinx.com -library ip -module_name $ipName
set_property -dict [list CONFIG.C_NUM_OF_PROBES {9} \
                         CONFIG.C_PROBE0_WIDTH {4} \
                         CONFIG.C_PROBE1_WIDTH {3} \
                         CONFIG.C_PROBE2_WIDTH {4} \
                         CONFIG.C_PROBE3_WIDTH {4} \
                         CONFIG.C_PROBE4_WIDTH {1} \
                         CONFIG.C_PROBE5_WIDTH {1} \
                         CONFIG.C_PROBE6_WIDTH {16} \
                         CONFIG.C_PROBE7_WIDTH {8} \
                         CONFIG.C_PROBE8_WIDTH {2} \
                         CONFIG.C_DATA_DEPTH {16384} \
                         CONFIG.C_INPUT_PIPE_STAGES {1} \
                         CONFIG.C_EN_STRG_QUAL {1} \
                         CONFIG.C_ADV_TRIGGER {true} \
                   ] [get_ips $ipName]
generate_target all [get_files ./$ipName.srcs/sources_1/ip/$ipName/$ipName.xci]
create_ip_run [get_files -of_objects [get_fileset sources_1] ./$ipName.srcs/sources_1/ip/$ipName/$ipName.xci]
launch_run -jobs 8 ${ipName}_synth_1
wait_on_run ${ipName}_synth_1
