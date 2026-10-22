/* ROM unpacker: the second stage of the BIOS ROM.
 *
 * The LiteX BIOS jumps here through ROM_BOOT_ADDRESS once it has brought up
 * DDR.  The payload after this program holds xz images, each with the DDR
 * address it unpacks to; once every image is in place this jumps to the
 * payload's entry point (OpenSBI) the way the BIOS's own boot() does.
 * mkpayload.py writes the format. */
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
static uint8_t heap[48 * 1024] __attribute__((aligned(8)));
static size_t heap_used;

void *xz_alloc(size_t size)
{
	void *p = heap + heap_used;
	heap_used += (size + 7) & ~(size_t)7;
	return heap_used <= sizeof heap ? p : NULL;
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

static void halt(const char *why)
{
	puts_("unpack: ");
	puts_(why);
	puts_(", halted\n");
	for (;;)
		;
}

int main(void)
{
	const struct payload *p = (const struct payload *)PAYLOAD_ADDRESS;

	puts_("\nunpack: payload at 0x");
	puthex(PAYLOAD_ADDRESS);
	putc_('\n');
	if (p->magic[0] != 'L' || p->magic[1] != 'X' || p->magic[2] != 'R' || p->magic[3] != 'P')
		halt("no payload");

	xz_crc32_init();
	struct xz_dec *dec = xz_dec_init(XZ_SINGLE, 0);
	if (!dec)
		halt("no memory for the decoder");

	for (uint32_t i = 0; i < p->count; i++) {
		const struct image *im = &p->image[i];
		struct xz_buf b = {
			.in = (const uint8_t *)p + im->offset, .in_pos = 0, .in_size = im->csize,
			.out = (uint8_t *)im->dest, .out_pos = 0, .out_size = im->usize,
		};
		puts_("unpack: ");
		putdec(im->csize);
		puts_(" -> ");
		putdec(im->usize);
		puts_(" bytes at 0x");
		puthex(im->dest);
		puts_(" ... ");
		xz_dec_reset(dec);
		enum xz_ret r = xz_dec_run(dec, &b);
		if (r != XZ_STREAM_END || b.out_pos != im->usize) {
			puts_("error ");
			putdec(r);
			halt("bad image");
		}
		puts_("ok\n");
	}

	puts_("unpack: starting 0x");
	puthex(p->entry);
	puts_("\n\n");
	while (!uart_txempty_read())
		;

	/* As the BIOS's boot(): the images were written through the data side */
	asm volatile(".word(0x100F)\n nop\n nop\n nop\n nop\n nop\n");   /* i$ */
	asm volatile(".word(0x500F)");                                    /* d$ */
	((void (*)(unsigned long, unsigned long, unsigned long))p->entry)(0, 0, 0);
	return 0;
}
