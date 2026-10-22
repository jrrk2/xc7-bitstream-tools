/* Code and constants execute in place from the program's ROM partition; bss
 * and stack go in SCRATCH: for the unpacker the last MiB of DDR, which nothing
 * has used yet, for the ROM test the SRAM. */
OUTPUT_ARCH(riscv)
ENTRY(_start)

MEMORY {
	rom : ORIGIN = PART_ADDRESS, LENGTH = PART_SIZE
	ram : ORIGIN = SCRATCH_ADDRESS,  LENGTH = SCRATCH_SIZE
}

SECTIONS {
	.text : {
		KEEP(*(.text.start))
		*(.text .text.*)
		*(.rodata .rodata.* .srodata .srodata.*)
	} > rom
	.data : { *(.data .data.* .sdata .sdata.*) } > ram AT > rom
	ASSERT(SIZEOF(.data) == 0, "no initialised data -- start.S does not copy it")
	.bss (NOLOAD) : {
		_bss_start = .;
		*(.bss .bss.* .sbss .sbss.* COMMON)
		. = ALIGN(4);
		_bss_end = .;
	} > ram
	_stack_top = ORIGIN(ram) + LENGTH(ram);
	/DISCARD/ : { *(.eh_frame .comment .riscv.attributes) }
}
