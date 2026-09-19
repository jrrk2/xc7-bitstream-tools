#!/bin/sh

# 
# Vivado(TM)
# runme.sh: a Vivado-generated Runs Script for UNIX
# Copyright 1986-2020 Xilinx, Inc. All Rights Reserved.
# 

if [ -z "$PATH" ]; then
  PATH=/NFS/apps/Xilinx/Vivado/2020.1/ids_lite/ISE/bin/lin64:/NFS/apps/Xilinx/Vivado/2020.1/bin
else
  PATH=/NFS/apps/Xilinx/Vivado/2020.1/ids_lite/ISE/bin/lin64:/NFS/apps/Xilinx/Vivado/2020.1/bin:$PATH
fi
export PATH

if [ -z "$LD_LIBRARY_PATH" ]; then
  LD_LIBRARY_PATH=
else
  LD_LIBRARY_PATH=:$LD_LIBRARY_PATH
fi
export LD_LIBRARY_PATH

HD_PWD='/home/jonathan/xc7-bitstream-tools/examples/vc707-sdtest/ip/sdtest_ila.runs/sdtest_ila_synth_1'
cd "$HD_PWD"

HD_LOG=runme.log
/bin/touch $HD_LOG

ISEStep="./ISEWrap.sh"
EAStep()
{
     $ISEStep $HD_LOG "$@" >> $HD_LOG 2>&1
     if [ $? -ne 0 ]
     then
         exit
     fi
}

EAStep vivado -log sdtest_ila.vds -m64 -product Vivado -mode batch -messageDb vivado.pb -notrace -source sdtest_ila.tcl
