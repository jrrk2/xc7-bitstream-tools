# The ROM unpacker and the ROM test, built against one SoC's generated headers
# (the UART's CSR addresses come from its csr.h).  The ROM test also needs the
# expected.h and romsig.h that romtest_data.py writes into OUT.
#
#   make BUILD_DIR=<litex output dir> ROM_BOOT_ADDRESS=0x20000 ROM_TEST_ADDRESS=0x28000 \
#        PAYLOAD_ADDRESS=0x30000 [unpacker|romtest]
BUILD_DIR        ?= ../build
ROM_BOOT_ADDRESS ?= 0x20000
PAYLOAD_ADDRESS  ?= 0x30000
ROM_TEST_ADDRESS ?= 0x28000
UNPACKER_SIZE    ?= $(shell printf '0x%x' $$(($(ROM_TEST_ADDRESS) - $(ROM_BOOT_ADDRESS))))
ROMTEST_SIZE     ?= $(shell printf '0x%x' $$(($(PAYLOAD_ADDRESS) - $(ROM_TEST_ADDRESS))))
SCRATCH_ADDRESS  ?= 0x7ff00000
SRAM_ADDRESS     ?= 0x10000000
SRAM_SIZE        ?= 0x2000
CROSS            ?= riscv64-unknown-elf-
OUT              ?= .

XZ     = ../../../linux-deps/linux/lib/xz
SOC    = $(shell sed -n 's/^SOC_DIRECTORY=//p' $(BUILD_DIR)/software/include/generated/variables.mak)
CFLAGS = -march=rv32ima -mabi=ilp32 -mcmodel=medany -Os -ffreestanding -fno-builtin -nostdlib \
         -ffunction-sections -fdata-sections -Wall -I. -I$(XZ) \
         -I$(BUILD_DIR)/software/include -I$(SOC)/software/include \
         -I$(SOC)/cores/cpu/vexriscv_smp -DPAYLOAD_ADDRESS=$(PAYLOAD_ADDRESS)
XZSRCS = $(XZ)/xz_crc32.c $(XZ)/xz_dec_stream.c $(XZ)/xz_dec_lzma2.c

unpacker: $(OUT)/unpacker.bin
romtest: $(OUT)/romtest.bin
.PHONY: unpacker romtest clean

$(OUT)/%.bin: $(OUT)/%.elf
	$(CROSS)objcopy -O binary $< $@

$(OUT)/unpacker.elf: start.S main.c $(XZSRCS) linker.ld xz_config.h
	$(CROSS)gcc $(CFLAGS) -Wl,--gc-sections -Wl,--defsym=PART_ADDRESS=$(ROM_BOOT_ADDRESS) \
		-Wl,--defsym=PART_SIZE=$(UNPACKER_SIZE) -Wl,--defsym=SCRATCH_ADDRESS=$(SCRATCH_ADDRESS) \
		-Wl,--defsym=SCRATCH_SIZE=0x100000 -T linker.ld -o $@ start.S main.c $(XZSRCS) -lgcc
	$(CROSS)size $@

# -fno-delete-null-pointer-checks: the ROM starts at address 0
$(OUT)/romtest.elf: start.S romtest.c $(XZSRCS) linker.ld xz_config.h $(OUT)/expected.h $(OUT)/romsig.h
	$(CROSS)gcc $(CFLAGS) -I$(OUT) -fno-delete-null-pointer-checks -DROM_BOOT_ADDRESS=$(ROM_BOOT_ADDRESS) \
		-Wl,--gc-sections -Wl,--defsym=PART_ADDRESS=$(ROM_TEST_ADDRESS) \
		-Wl,--defsym=PART_SIZE=$(ROMTEST_SIZE) -Wl,--defsym=SCRATCH_ADDRESS=$(SRAM_ADDRESS) \
		-Wl,--defsym=SCRATCH_SIZE=$(SRAM_SIZE) -T linker.ld -o $@ start.S romtest.c $(XZSRCS) -lgcc
	$(CROSS)size $@

clean:
	rm -f $(OUT)/unpacker.elf $(OUT)/unpacker.bin $(OUT)/romtest.elf $(OUT)/romtest.bin
