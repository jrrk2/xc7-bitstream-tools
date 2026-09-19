#!/bin/sh
# Partition an SD card for the VC707: a small FAT boot partition the LiteX
# BIOS can read boot.json from, and ext4 for root.
#
# CHECK THE DEVICE FIRST.  /dev/sda below is a USB card reader on the machine
# this was written on; on another it is very often the system disk.  Run
# `lsblk -o NAME,SIZE,TYPE,TRAN,RM` and confirm TRAN=usb and RM=1 before
# running any of this.
#
# The resulting layout is what CVA6's bootrom read back correctly -- GPT with
# entries named "boot" (lba 0x800) and "root" (lba 0x80800).
sudo sgdisk --zap-all /dev/sda
sudo sgdisk -n1:0:+256M -t1:0700 -c1:boot /dev/sda
sudo sgdisk -n2:0:0     -t2:8300 -c2:root /dev/sda
sudo mkfs.vfat -F32 -n BOOT /dev/sda1
sudo mkfs.ext4 -L root      /dev/sda2
sudo mount /dev/sda1 /mnt
S=/tmp/claude-1000/-home-jonathan-xc7-bitstream-tools-fasm2netlist/9eea2739-33c0-4061-a027-a392b29c20d9/scratchpad
sudo cp $S/linux-build-local/arch/riscv/boot/Image                          /mnt/Image
sudo cp $S/rv32-sdroot.dtb                                                  /mnt/rv32.dtb
sudo cp ~/xc7-bitstream-tools/examples/vc707-litex-linux/emulator/emulator.bin /mnt/emulator.bin
printf '{\n\t"Image":        "0x40000000",\n\t"rv32.dtb":     "0x41000000",\n\t"emulator.bin": "0x50000000"\n}\n' | sudo tee /mnt/boot.json
sync; sudo umount /mnt
sudo mount /dev/sda2 /mnt
sudo tar xpf $S/br-build/images/rootfs.tar -C /mnt
sync; sudo umount /mnt
