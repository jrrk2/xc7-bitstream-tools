# The SMP+SD SoC: VexRiscv-SMP, DDR3, LiteEth and an SD card, the design
# that boots Linux over NFS root with a native toolchain on it.  This is
# the system in service, so a regression here is one that would be felt.
# The SGMII PHY is a hand-written core kept beside vc707-ethmin, not part of
# the generated gateware -- LiteX instantiates it by name and leaves the
# implementation to the platform.
../../../vc707-ethmin/rtl/liteeth_sgmii_phy.v
# VexRiscv-SMP's RAM primitive lives in the pythondata package, not in the
# generated gateware -- the Makefile target passes it as SMPSD_RAM.
../../../../litex-deps/pythondata-cpu-vexriscv-smp/pythondata_cpu_vexriscv_smp/verilog/Ram_1w_1rs_Generic.v
VexRiscvLitexSmpCluster_Cc1_Iw32Is4096Iy1_Dw32Ds4096Dy1_ITs4DTs4_Ood_Wm.v
xilinx_vc707.v
