// A netbooted self-test for the VC707 LiteX SoC triages.
//
// The BIOS already proves it can reach the DDR3 and the network -- it
// calibrates the PHY, runs a 2 MiB memtest and answers ARP before it ever
// looks for a boot image.  What it does NOT prove is that a program fetched
// over the network runs from DDR3 and finds the machine intact, which is a
// different claim and the one that matters if anything larger is ever going
// to be booted here.
//
// So this executable is deliberately not a hello-world.  It reports what it
// is running on, walks a far larger span of DDR3 than the BIOS does with a
// pattern that catches address aliasing as well as stuck bits, and says PASS
// or FAIL in a form that is unambiguous on a serial log.
//
// It is built against one specific SoC's headers (its CSR map, its memory
// map, its MAC address) and delivered to that SoC alone; see the README.

#include <stdio.h>
#include <stdint.h>
#include <string.h>

#include <irq.h>
#include <libbase/uart.h>
#include <libbase/console.h>
#include <generated/csr.h>
#include <generated/soc.h>
#include <generated/mem.h>

#ifndef MAIN_RAM_BASE
#error "This test needs a main RAM region: build it against a DDR3 variant."
#endif

// Leave the top of main RAM alone: this program was loaded into it, and its
// .data/.bss/stack live there too on a SoC whose sram region is small.  The
// window below starts well clear of the load address and is sized to be a
// real test rather than a token one.
#define TEST_OFFSET   (16u * 1024 * 1024)
#define TEST_BYTES    (64u * 1024 * 1024)
#define TEST_WORDS    (TEST_BYTES / 4)

// A value that depends on the address, so a write that lands at the wrong
// address is caught as well as a bit that will not hold.  Plain incrementing
// data cannot tell those apart: with aliased address lines the readback of a
// counter still looks like a counter.
static inline uint32_t pattern_for(uint32_t index)
{
	return (index * 2654435761u) ^ (index << 3);
}

static int memory_test(volatile uint32_t *base, uint32_t words)
{
	uint32_t errors = 0;
	uint32_t first_bad_index = 0;
	uint32_t first_bad_expected = 0, first_bad_got = 0;

	printf("  writing  %lu MiB...", (unsigned long)(words / (1024 * 1024 / 4)));
	for (uint32_t i = 0; i < words; i++)
		base[i] = pattern_for(i);
	printf(" done\n");

	printf("  reading  %lu MiB...", (unsigned long)(words / (1024 * 1024 / 4)));
	for (uint32_t i = 0; i < words; i++) {
		uint32_t got = base[i];
		uint32_t expected = pattern_for(i);
		if (got != expected) {
			if (errors == 0) {
				first_bad_index    = i;
				first_bad_expected = expected;
				first_bad_got      = got;
			}
			errors++;
		}
	}
	printf(" done\n");

	if (errors) {
		// Report the first failure concretely.  "N errors" alone does not
		// distinguish a single weak bit from a wholly unmapped region, and
		// the address and the two values say which it was.
		printf("  FAIL: %lu word(s) differ\n", (unsigned long)errors);
		printf("        first at +0x%08lx: expected 0x%08lx, read 0x%08lx\n",
		       (unsigned long)(first_bad_index * 4),
		       (unsigned long)first_bad_expected,
		       (unsigned long)first_bad_got);
		return 0;
	}
	return 1;
}

int main(void)
{
#ifdef CONFIG_CPU_HAS_INTERRUPT
	irq_setmask(0);
	irq_setie(1);
#endif
	uart_init();

	printf("\n");
	printf("=======================================================\n");
	printf(" VC707 LiteX SoC self-test -- netbooted\n");
	printf("=======================================================\n");
	printf(" SoC:       %s\n", CONFIG_CPU_HUMAN_NAME);
	printf(" Clock:     %u MHz\n", (unsigned)(CONFIG_CLOCK_FREQUENCY / 1000000));
	printf(" Main RAM:  0x%08lx, %lu MiB\n",
	       (unsigned long)MAIN_RAM_BASE,
	       (unsigned long)(MAIN_RAM_SIZE / (1024 * 1024)));
#ifdef CSR_ETHMAC_BASE
	printf(" Ethernet:  present\n");
#else
	printf(" Ethernet:  absent\n");
#endif
	printf("\n");

	// It reached here at all, which is the first result: the image was
	// fetched over TFTP, written to DDR3 and executed from it.
	printf("[1/2] netboot ....... PASS (this code is running from main RAM)\n");

	printf("[2/2] DDR3 %lu MiB at 0x%08lx\n",
	       (unsigned long)(TEST_BYTES / (1024 * 1024)),
	       (unsigned long)(MAIN_RAM_BASE + TEST_OFFSET));

	int ok = 0;
	if (TEST_OFFSET + TEST_BYTES > MAIN_RAM_SIZE) {
		printf("  SKIP: main RAM is smaller than the test window\n");
	} else {
		ok = memory_test((volatile uint32_t *)(MAIN_RAM_BASE + TEST_OFFSET),
		                 TEST_WORDS);
		if (ok)
			printf("  PASS\n");
	}

	printf("\n");
	printf("-------------------------------------------------------\n");
	printf(" RESULT: %s\n", ok ? "PASS" : "FAIL");
	printf("-------------------------------------------------------\n");

	// Returning would fall back into the BIOS, which reboots and netboots
	// again -- an endless loop that scrolls the result off the screen.  Stop
	// here instead, so the verdict stays on the terminal.
	// Say what a reset will actually do.  While this image is still the one
	// the TFTP server offers, CPU_RESET re-runs the BIOS, which network-boots
	// it again -- it does not leave you at the console.  Move the image aside
	// on the server for that.
	printf("\nHalted.  CPU_RESET reboots and netboots this image again;\n");
	printf("move boot.bin aside on the server to reach the BIOS console.\n");
	while (1)
		;

	return 0;
}
