BOARD?=sim
BUILD_DIR=../build/$(BOARD)

include $(BUILD_DIR)/software/include/generated/variables.mak
include $(SOC_DIRECTORY)/software/common.mak

OBJECTS=crt0.o isr.o main.o

all: emulator.bin

# pull in dependency info for *existing* .o files
-include $(OBJECTS:.o=.d)

%.bin: %.elf
	$(OBJCOPY) -O binary $< $@
	chmod -x $@

# Link through $(CC), not $(LD): LiteX's LDFLAGS now carry compiler flags
# (-mabi=ilp32) that ld does not accept.  Same pattern the in-tree software
# Makefiles use.
COMMA = ,
REGULAR_LIBS = $(filter-out $(ALWAYS_LINK_LIBS),$(LIBS))
ALWAYS_LINK_LIBFLAGS = $(if $(ALWAYS_LINK_LIBS),-Wl$(COMMA)--whole-archive $(ALWAYS_LINK_LIBS:lib%=-l%) -Wl$(COMMA)--no-whole-archive)

# Link the way the in-tree software Makefiles do: through $(CC), with the
# whole package set in a group.  The 2020-era rule linked with $(LD) against
# libbase alone, which this LiteX no longer satisfies -- libbase's isr.o
# needs printf from libc.
emulator.elf: $(OBJECTS)
	$(CC) $(LDFLAGS) -T linker.ld -N -o $@ \
		$(OBJECTS) \
		$(PACKAGES:%=-L$(BUILD_DIR)/software/%) \
		-Wl,--start-group \
		$(REGULAR_LIBS:lib%=-l%) \
		$(ALWAYS_LINK_LIBFLAGS) \
		-Wl,--end-group \
		-Wl,--gc-sections \
		-Wl,--allow-multiple-definition
	chmod -x $@

main.o: main.c
	$(compile)

%.o: %.c
	$(compile)

%.o: %.S
	$(assemble)

clean:
	$(RM) $(OBJECTS) $(OBJECTS:.o=.d) emulator.elf emulator.bin .*~ *~

.PHONY: all main.o clean load

VPATH = $(CPU_DIRECTORY)
