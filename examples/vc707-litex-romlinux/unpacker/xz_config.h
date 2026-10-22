/* xz-embedded (linux lib/xz) outside the kernel: the configuration its
 * xz_private.h asks for when __KERNEL__ is not defined. */
#ifndef XZ_CONFIG_H
#define XZ_CONFIG_H

#define XZ_DEC_SINGLE   /* whole input and output in memory: no dictionary buffer */

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include "../../../linux-deps/linux/include/linux/xz.h"

void *xz_alloc(size_t size);
#define kmalloc(size, flags) xz_alloc(size)
#define kfree(ptr) ((void)0)
#define vmalloc(size) xz_alloc(size)
#define vfree(ptr) ((void)0)

void *memcpy(void *dst, const void *src, size_t n);
void *memmove(void *dst, const void *src, size_t n);
void *memset(void *dst, int c, size_t n);
#define memeq(a, b, size) (xz_memcmp(a, b, size) == 0)
#define memzero(buf, size) memset(buf, 0, size)
int xz_memcmp(const void *a, const void *b, size_t n);

#ifndef min
#define min(x, y) ((x) < (y) ? (x) : (y))
#endif
#define min_t(type, x, y) min(x, y)

#define __always_inline inline __attribute__((__always_inline__))
#define fallthrough __attribute__((__fallthrough__))
#define get_le32(p) ((uint32_t)(p)[0] | (uint32_t)(p)[1] << 8 | (uint32_t)(p)[2] << 16 | (uint32_t)(p)[3] << 24)
#define put_unaligned_le32(v, p) do { (p)[0] = (uint8_t)(v); (p)[1] = (uint8_t)((v) >> 8); \
	(p)[2] = (uint8_t)((v) >> 16); (p)[3] = (uint8_t)((v) >> 24); } while (0)

#endif
