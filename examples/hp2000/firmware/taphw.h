/* SIMH .tap <-> HP 2000 RTL tape image (see tools/taphw.py for the layout).
 * Freestanding: no libc beyond memcpy-free byte loops, so it can run inside the LiteX BIOS. */
#ifndef TAPHW_H
#define TAPHW_H
#include <stdint.h>
#include <stddef.h>

/* Convert a .tap image held in memory to the hardware layout.  Writes big-endian 16-bit words as bytes into
 * `out` (capacity `cap` bytes).  Returns the number of bytes written, or 0 on overflow. */
size_t taphw_from_tap(const uint8_t *tap, size_t tap_len, uint8_t *out, size_t cap);

/* Convert a hardware-layout image back to .tap.  Returns bytes written, or 0 on overflow. */
size_t taphw_to_tap(const uint8_t *hw, size_t hw_len, uint8_t *out, size_t cap);
#endif
