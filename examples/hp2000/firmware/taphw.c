#include "taphw.h"

#define EOM 0xFFFFu

static void put16(uint8_t *p, uint16_t v) { p[0] = v >> 8; p[1] = v & 0xFF; }
static uint16_t get16(const uint8_t *p) { return (uint16_t)((p[0] << 8) | p[1]); }
static uint32_t get32le(const uint8_t *p) { return p[0] | (p[1] << 8) | (p[2] << 16) | ((uint32_t)p[3] << 24); }
static void put32le(uint8_t *p, uint32_t v) { p[0] = v; p[1] = v >> 8; p[2] = v >> 16; p[3] = v >> 24; }

size_t taphw_from_tap(const uint8_t *tap, size_t tap_len, uint8_t *out, size_t cap)
{
    size_t ip = 0, op = 0;
    uint32_t prev = 0, pos_words = 0;
    while (ip + 4 <= tap_len) {
        uint32_t n = get32le(tap + ip);
        ip += 4;
        if (n == 0xFFFFFFFFu) break;                         /* end of medium */
        uint32_t start = pos_words;
        if (n == 0) {                                         /* tape mark */
            if (op + 4 > cap) return 0;
            put16(out + op, 0x8000); put16(out + op + 2, (uint16_t)prev);
            op += 4; pos_words += 2;
        } else {
            uint32_t len = n & 0xFFFFFF, keep = len > 0x7FFF ? 0x7FFF : len;
            uint32_t words = (keep + 1) / 2;
            if (ip + len > tap_len || op + 4 + 2 * words > cap) return 0;
            put16(out + op, (uint16_t)keep); put16(out + op + 2, (uint16_t)prev);
            for (uint32_t w = 0; w < words; w++) {
                uint8_t hi = tap[ip + 2 * w];
                uint8_t lo = (2 * w + 1 < keep) ? tap[ip + 2 * w + 1] : 0;
                put16(out + op + 4 + 2 * w, (uint16_t)((hi << 8) | lo));
            }
            op += 4 + 2 * words; pos_words += 2 + words;
            ip += len + (len & 1) + 4;                        /* data, pad, trailing length */
        }
        prev = pos_words - start;
    }
    if (op + 4 > cap) return 0;
    put16(out + op, EOM); put16(out + op + 2, (uint16_t)prev);
    return op + 4;
}

size_t taphw_to_tap(const uint8_t *hw, size_t hw_len, uint8_t *out, size_t cap)
{
    size_t ip = 0, op = 0;
    while (ip + 4 <= hw_len) {
        uint16_t w0 = get16(hw + ip);
        if (w0 == EOM) break;
        if (w0 & 0x8000) {
            if (op + 4 > cap) return 0;
            put32le(out + op, 0); op += 4; ip += 4;
            continue;
        }
        uint32_t len = w0 & 0x7FFF, words = (len + 1) / 2;
        uint32_t pad = len & 1;
        if (ip + 4 + 2 * words > hw_len || op + 8 + len + pad > cap) return 0;
        put32le(out + op, len); op += 4;
        for (uint32_t i = 0; i < len; i++) out[op + i] = hw[ip + 4 + i];
        op += len;
        if (pad) out[op++] = 0;
        put32le(out + op, len); op += 4;
        ip += 4 + 2 * words;
    }
    if (op + 4 > cap) return 0;
    put32le(out + op, 0xFFFFFFFFu);
    return op + 4;
}
