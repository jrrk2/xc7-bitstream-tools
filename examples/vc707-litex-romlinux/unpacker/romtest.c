/* ROM test: the BIOS's "romtest" command (ROM_TEST_ADDRESS).  Checks the ROM
 * as the CPU reads it, 1 KiB at a time, against the host's signatures; checks
 * and unpacks each payload image, naming its first 64 KiB block that unpacks
 * wrongly; then tests all of DDR with address-in-data and its complement.
 * romtest_data.py writes expected.h and romsig.h from the built ROM.  The
 * stack is in SRAM, so a faulty DDR cannot take the test down with it. */
#include <stddef.h>
#include <stdint.h>
#include <generated/csr.h>
#include "xz_config.h"

struct image {
	uint32_t dest, offset, csize, usize;   /* offset is from the header */
};
struct payload {
	char     magic[4];                     /* "LXRP" */
	uint32_t count, entry, reserved;
	struct image image[];
};

static void putc_(char c)
{
	if (c == '\n')
		putc_('\r');
	while (uart_txfull_read())
		;
	uart_rxtx_write(c);
}

static void puts_(const char *s)
{
	while (*s)
		putc_(*s++);
}

static void puthex(uint32_t v)
{
	for (int i = 28; i >= 0; i -= 4)
		putc_("0123456789abcdef"[(v >> i) & 15]);
}

static void putdec(uint32_t v)
{
	char b[11];
	int i = sizeof b;
	b[--i] = 0;
	do b[--i] = '0' + v % 10; while (v /= 10);
	puts_(b + i);
}

/* xz's allocations: one decoder, made once, so a bump allocator in .bss */
#define heap ((uint8_t *)0x7ff00000)   /* too big for the SRAM; DDR is tested last */
static size_t heap_used;

void *xz_alloc(size_t size)
{
	void *p = heap + heap_used;
	heap_used += (size + 7) & ~(size_t)7;
	return heap_used <= 0x100000 ? p : NULL;
}

void *memcpy(void *dst, const void *src, size_t n)
{
	uint8_t *d = dst;
	const uint8_t *s = src;
	while (n--)
		*d++ = *s++;
	return dst;
}

void *memmove(void *dst, const void *src, size_t n)
{
	uint8_t *d = dst;
	const uint8_t *s = src;
	if (d < s)
		while (n--)
			*d++ = *s++;
	else
		while (n--)
			d[n] = s[n];
	return dst;
}

void *memset(void *dst, int c, size_t n)
{
	uint8_t *d = dst;
	while (n--)
		*d++ = c;
	return dst;
}

int xz_memcmp(const void *a, const void *b, size_t n)
{
	const uint8_t *x = a, *y = b;
	for (; n; n--, x++, y++)
		if (*x != *y)
			return *x - *y;
	return 0;
}

#include "expected.h"
#include "romsig.h"

static void hexline(const char *what, uint32_t v)
{
	puts_(what);
	puts_("0x");
	puthex(v);
}

/* Write every word of [lo, hi) with f(addr), then read it all back; reports
 * the first few mismatches and which data and address bits are involved. */
static uint32_t memtest(uint32_t lo, uint32_t hi, uint32_t inv)
{
	volatile uint32_t *p;
	uint32_t errs = 0, xbits = 0, abits_or = 0, abits_and = ~0u;

	for (p = (volatile uint32_t *)lo; (uint32_t)p < hi; p++)
		*p = (uint32_t)p ^ inv;
	for (p = (volatile uint32_t *)lo; (uint32_t)p < hi; p++) {
		uint32_t want = (uint32_t)p ^ inv, got = *p;
		if (got == want)
			continue;
		if (errs < 12) {
			hexline("\n  at ", (uint32_t)p);
			hexline(" want ", want);
			hexline(" got ", got);
			hexline(" xor ", got ^ want);
		}
		errs++;
		xbits |= got ^ want;
		abits_or |= (uint32_t)p;
		abits_and &= (uint32_t)p;
	}
	puts_("\n  errors ");
	putdec(errs);
	if (errs) {
		hexline(", data bits ", xbits);
		hexline(", address bits set in all ", abits_and);
		hexline(", in any ", abits_or);
	}
	putc_('\n');
	return errs;
}

int main(void)
{
	const struct payload *p = (const struct payload *)PAYLOAD_ADDRESS;

	puts_("\nromtest: payload at 0x");
	puthex(PAYLOAD_ADDRESS);
	putc_('\n');
	xz_crc32_init();

	/* 0. The whole ROM, 256 words at a time: runs of blocks that read
	 * wrongly, with the data bits involved */
	{
		const volatile uint32_t *rom = (const volatile uint32_t *)0;
		uint32_t nb = (ROM_WORDS + 255) / 256, run = 0, rmask = 0, bad = 0;
		for (uint32_t b = 0; b <= nb; b++) {
			uint32_t m = 0;
			/* (the unpacker and this program: their signatures would include themselves) */
			if (b * 1024 >= ROM_BOOT_ADDRESS && b * 1024 < PAYLOAD_ADDRESS)
				m = rmask;
			else if (b < nb) {
				uint32_t v = 0, n = ROM_WORDS - b * 256 < 256 ? ROM_WORDS - b * 256 : 256;
				for (uint32_t k = 0; k < n; k++)
					v ^= rom[b * 256 + k];
				m = v ^ rom_xor[b];
			}
			if (m == rmask && b < nb)
				continue;
			if (rmask) {
				hexline("romtest: rom bytes ", run * 1024);
				hexline("-", b * 1024 - 1);
				hexline(" bits ", rmask);
				putc_('\n');
				bad += b - run;
			}
			run = b;
			rmask = m;
		}
		puts_("romtest: rom blocks bad ");
		putdec(bad);
		puts_(" of ");
		putdec(nb);
		putc_('\n');
	}

	/* 1. The compressed images as the CPU reads them from the ROM */
	for (uint32_t i = 0; i < NIMAGES; i++) {
		const struct image *im = &p->image[i];
		uint32_t c = xz_crc32((const uint8_t *)p + im->offset, im->csize, 0);
		puts_("romtest: image ");
		putdec(i);
		hexline(" rom crc ", c);
		puts_(c == rom_crc[i] ? " ok\n" : " BAD\n");
	}

	/* 2. Each unpack, and its first 64 KiB block that differs */
	struct xz_dec *dec = xz_dec_init(XZ_SINGLE, 0);
	const uint32_t *bc = blk_crc;
	for (uint32_t i = 0; i < NIMAGES; i++) {
		const struct image *im = &p->image[i];
		struct xz_buf b = {
			.in = (const uint8_t *)p + im->offset, .in_pos = 0, .in_size = im->csize,
			.out = (uint8_t *)im->dest, .out_pos = 0, .out_size = im->usize,
		};
		xz_dec_reset(dec);
		enum xz_ret r = xz_dec_run(dec, &b);
		puts_("romtest: unpack ");
		putdec(i);
		hexline(" to ", im->dest);
		puts_(" ret ");
		putdec(r);
		puts_(" in ");
		putdec(b.in_pos);
		puts_(" out ");
		putdec(b.out_pos);
		for (uint32_t k = 0; k < nblocks[i]; k++) {
			uint32_t off = k * 65536, n = im->usize - off < 65536 ? im->usize - off : 65536;
			if (off >= b.out_pos)
				break;
			if (xz_crc32((const uint8_t *)im->dest + off, n, 0) != bc[k]) {
				hexline(", first bad block at ", im->dest + off);
				break;
			}
		}
		bc += nblocks[i];
		putc_('\n');
	}

	/* 3. All of DDR, address-in-data and its complement */
	for (uint32_t pass = 0; pass < 2; pass++) {
		puts_("romtest: memtest 0x40000000-0x7fffffff, data = address");
		puts_(pass ? " inverted" : "");
		memtest(0x40000000u, 0x80000000u, pass ? ~0u : 0);
	}
	puts_("romtest: done\n");
	for (;;)
		;
}
