#include "tcpd.h"

#define F_FIN 0x01
#define F_SYN 0x02
#define F_RST 0x04
#define F_PSH 0x08
#define F_ACK 0x10

#define MSS     512                 /* what we advertise and send; small enough for any path */
#define RXWIN   4096
#define RTO_MIN 250
#define RTO_MAX 4000
#define MAXTRY  10

enum { S_FREE, S_SYN_RCVD, S_ESTAB, S_LAST_ACK };
enum { T_DATA, T_IAC, T_OPT, T_SB, T_SBIAC };

struct conn {
    uint8_t  state;
    uint8_t  mac[6];
    uint32_t ip;
    uint16_t port;
    uint32_t snd_una, snd_nxt, rcv_nxt;
    uint16_t peer_win;
    uint8_t  tx[TCPD_TXBUF];
    uint16_t txh, txt;              /* ring head (write) / tail (oldest unacked) */
    uint16_t inflight;              /* bytes of the ring currently sent and unacked */
    uint8_t  fin_queued, fin_sent;
    uint32_t rto, deadline;
    uint8_t  tries;
    uint8_t  tstate, prev_cr;
};

#ifdef TCPD_STORAGE                                  /* the BIOS has 8 KB of SRAM: keep the connection table in DDR */
#define C ((struct conn *)TCPD_STORAGE)
#else
static struct conn C[TCPD_MAXCONN];
#endif
static uint32_t my_ip;
static uint16_t my_port;
static const struct tcpd_ops *ops;
static uint32_t now;
static uint32_t iss_counter = 0x1000;

static uint16_t rd16(const uint8_t *p) { return (uint16_t)((p[0] << 8) | p[1]); }
static uint32_t rd32(const uint8_t *p) { return ((uint32_t)p[0] << 24) | (p[1] << 16) | (p[2] << 8) | p[3]; }
static void wr16(uint8_t *p, uint16_t v) { p[0] = v >> 8; p[1] = v; }
static void wr32(uint8_t *p, uint32_t v) { p[0] = v >> 24; p[1] = v >> 16; p[2] = v >> 8; p[3] = v; }

static uint32_t csum_add(uint32_t s, const uint8_t *p, uint32_t n)
{
    while (n > 1) { s += (uint32_t)(p[0] << 8 | p[1]); p += 2; n -= 2; }
    if (n) s += (uint32_t)p[0] << 8;
    return s;
}
static uint16_t csum_fold(uint32_t s)
{
    while (s >> 16) s = (s & 0xFFFF) + (s >> 16);
    return (uint16_t)~s;
}

/* build and send one TCP segment; payload may be NULL */
static void send_seg(struct conn *c, uint32_t dst_ip, uint16_t dst_port, const uint8_t *dmac, uint32_t seq, uint32_t ack,
                     uint8_t flags, const uint8_t *data, uint16_t dlen, int with_mss)
{
#ifdef TCPD_STORAGE
    uint8_t *const pkt = (uint8_t *)(TCPD_STORAGE + 0x8000);          /* DDR: the BIOS SRAM is tiny */
#else
    static uint8_t pkt[20 + 24 + MSS + 16];
#endif
    uint8_t *ip = pkt, *tcp = pkt + 20;
    uint16_t hl = with_mss ? 24 : 20, total = 20 + hl + dlen;
    (void)c;
    ip[0] = 0x45; ip[1] = 0; wr16(ip + 2, total); wr16(ip + 4, 0); wr16(ip + 6, 0x4000);
    ip[8] = 64; ip[9] = 6; wr16(ip + 10, 0); wr32(ip + 12, my_ip); wr32(ip + 16, dst_ip);
    wr16(ip + 10, csum_fold(csum_add(0, ip, 20)));
    wr16(tcp, my_port); wr16(tcp + 2, dst_port); wr32(tcp + 4, seq); wr32(tcp + 8, ack);
    tcp[12] = (uint8_t)((hl / 4) << 4); tcp[13] = flags; wr16(tcp + 14, RXWIN); wr16(tcp + 16, 0); wr16(tcp + 18, 0);
    if (with_mss) { tcp[20] = 2; tcp[21] = 4; wr16(tcp + 22, MSS); }
    for (uint16_t i = 0; i < dlen; i++) tcp[hl + i] = data[i];
    uint32_t s = 0;
    uint8_t ph[12];
    wr32(ph, my_ip); wr32(ph + 4, dst_ip); ph[8] = 0; ph[9] = 6; wr16(ph + 10, hl + dlen);
    s = csum_add(s, ph, 12); s = csum_add(s, tcp, hl + dlen);
    wr16(tcp + 16, csum_fold(s));
    ops->send_ip(dmac, pkt, total);
}

static void reset_reply(const uint8_t *smac, uint32_t sip, uint16_t sport, uint32_t seq, uint32_t ack, uint8_t flags_in, uint16_t dlen)
{
    if (flags_in & F_RST) return;
    if (flags_in & F_ACK) send_seg(0, sip, sport, smac, ack, 0, F_RST, 0, 0, 0);
    else send_seg(0, sip, sport, smac, 0, seq + dlen + ((flags_in & (F_SYN | F_FIN)) ? 1 : 0), F_RST | F_ACK, 0, 0, 0);
}

static void drop(struct conn *c, int notify)
{
    int line = (int)(c - C);
    int was = c->state != S_FREE;
    c->state = S_FREE;
    if (was && notify) ops->on_close(line);
}

static uint16_t ring_used(const struct conn *c) { return (uint16_t)((c->txh - c->txt) & (TCPD_TXBUF - 1)); }

static void out_data(struct conn *c, uint16_t off, uint8_t *dst, uint16_t n)
{
    for (uint16_t i = 0; i < n; i++) dst[i] = c->tx[(c->txt + off + i) & (TCPD_TXBUF - 1)];
}

/* send (or resend) whatever is pending on a connection, if nothing is in flight or the timer expired */
static void pump(struct conn *c)
{
    uint8_t buf[MSS];
    if (c->state != S_ESTAB && c->state != S_LAST_ACK) return;
    uint16_t used = ring_used(c);
    if (c->inflight == 0 && used) {                       /* new data */
        uint16_t n = used < MSS ? used : MSS;
        if (c->peer_win && n > c->peer_win) n = c->peer_win;
        if (n == 0) return;
        out_data(c, 0, buf, n);
        send_seg(c, c->ip, c->port, c->mac, c->snd_nxt, c->rcv_nxt, F_ACK | F_PSH, buf, n, 0);
        c->inflight = n; c->snd_nxt += n; c->tries = 0; c->rto = RTO_MIN; c->deadline = now + c->rto;
    } else if (c->inflight && (int32_t)(now - c->deadline) >= 0) {        /* retransmit */
        if (++c->tries > MAXTRY) { send_seg(c, c->ip, c->port, c->mac, c->snd_nxt, c->rcv_nxt, F_RST | F_ACK, 0, 0, 0); drop(c, 1); return; }
        out_data(c, 0, buf, c->inflight);
        send_seg(c, c->ip, c->port, c->mac, c->snd_una, c->rcv_nxt, F_ACK | F_PSH, buf, c->inflight, 0);
        c->rto = c->rto * 2 > RTO_MAX ? RTO_MAX : c->rto * 2; c->deadline = now + c->rto;
    } else if (c->inflight == 0 && used == 0 && c->fin_queued && !c->fin_sent) {
        send_seg(c, c->ip, c->port, c->mac, c->snd_nxt, c->rcv_nxt, F_FIN | F_ACK, 0, 0, 0);
        c->fin_sent = 1; c->snd_nxt++; c->state = S_LAST_ACK; c->deadline = now + RTO_MAX;
    }
}

/* Returns 0 if the terminal side cannot take the character yet; nothing has changed then and the byte is not acknowledged. */
static int telnet_in(struct conn *c, uint8_t b)
{
    int line = (int)(c - C);
    switch (c->tstate) {
    case T_DATA:
        if (b == 255) { c->tstate = T_IAC; return 1; }
        if (c->prev_cr && (b == 0 || b == 10)) { c->prev_cr = 0; return 1; }     /* CR NUL / CR LF = Enter */
        if (!ops->on_char(line, b == 3 ? 0 : b)) return 0;                       /* Ctrl-C = BREAK */
        c->prev_cr = (b == 13);
        return 1;
    case T_IAC:
        if (b >= 251 && b <= 254) c->tstate = T_OPT;
        else if (b == 250) c->tstate = T_SB;
        else {
            int ok = 1;
            if (b == 243 || b == 244) ok = ops->on_char(line, 0);                /* BRK / IP */
            else if (b == 255) ok = ops->on_char(line, 255);
            if (!ok) return 0;
            c->tstate = T_DATA;
        }
        return 1;
    case T_OPT: c->tstate = T_DATA; return 1;
    case T_SB:  if (b == 255) c->tstate = T_SBIAC; return 1;
    case T_SBIAC: c->tstate = (b == 240) ? T_DATA : T_SB; return 1;
    }
    return 1;
}

void tcpd_init(uint32_t ip, uint16_t port, const struct tcpd_ops *o)
{
    my_ip = ip; my_port = port; ops = o;
    for (int i = 0; i < TCPD_MAXCONN; i++) C[i].state = S_FREE;
}

void tcpd_rx(const uint8_t *smac, const uint8_t *ip, uint32_t len)
{
    if (len < 40 || (ip[0] >> 4) != 4 || ip[9] != 6) return;
    uint16_t ihl = (uint16_t)((ip[0] & 15) * 4), tot = rd16(ip + 2);
    if (ihl < 20 || tot > len || tot < ihl + 20) return;
    if (rd16(ip + 6) & 0x3FFF) return;                                          /* fragments: not supported */
    if (rd32(ip + 16) != my_ip) return;
    const uint8_t *t = ip + ihl;
    uint16_t tl = (uint16_t)(tot - ihl), off = (uint16_t)((t[12] >> 4) * 4);
    if (off < 20 || off > tl || rd16(t + 2) != my_port) return;
    uint8_t ph[12];
    wr32(ph, rd32(ip + 12)); wr32(ph + 4, my_ip); ph[8] = 0; ph[9] = 6; wr16(ph + 10, tl);
    if (csum_fold(csum_add(csum_add(0, ph, 12), t, tl)) != 0) return;
    uint32_t sip = rd32(ip + 12), seq = rd32(t + 4), ack = rd32(t + 8);
    uint16_t sport = rd16(t), win = rd16(t + 14), dlen = (uint16_t)(tl - off);
    uint8_t fl = t[13];
    const uint8_t *data = t + off;

    struct conn *c = 0;
    for (int i = 0; i < TCPD_MAXCONN; i++)
        if (C[i].state != S_FREE && C[i].ip == sip && C[i].port == sport) { c = &C[i]; break; }

    if (!c) {
        if ((fl & (F_SYN | F_ACK | F_RST)) != F_SYN) { reset_reply(smac, sip, sport, seq, ack, fl, dlen); return; }
        for (int i = 0; i < TCPD_MAXCONN; i++) if (C[i].state == S_FREE) { c = &C[i]; break; }
        if (!c) { reset_reply(smac, sip, sport, seq, ack, fl, dlen); return; }
        for (int i = 0; i < 6; i++) c->mac[i] = smac[i];
        c->ip = sip; c->port = sport; c->rcv_nxt = seq + 1; c->txh = c->txt = c->inflight = 0;
        c->fin_queued = c->fin_sent = 0; c->tstate = T_DATA; c->prev_cr = 0; c->peer_win = win;
        iss_counter += 64000 + (now & 0xFFFF);
        c->snd_una = iss_counter; c->snd_nxt = iss_counter + 1;
        c->state = S_SYN_RCVD; c->rto = RTO_MIN; c->deadline = now + c->rto; c->tries = 0;
        send_seg(c, sip, sport, smac, c->snd_una, c->rcv_nxt, F_SYN | F_ACK, 0, 0, 1);
        return;
    }
    for (int i = 0; i < 6; i++) c->mac[i] = smac[i];
    if (fl & F_RST) { if (seq == c->rcv_nxt || c->state == S_SYN_RCVD) drop(c, 1); return; }

    if (c->state == S_SYN_RCVD) {
        if ((fl & F_SYN) && !(fl & F_ACK)) {                                    /* retransmitted SYN */
            send_seg(c, sip, sport, smac, c->snd_una, c->rcv_nxt, F_SYN | F_ACK, 0, 0, 1); return;
        }
        if ((fl & F_ACK) && ack == c->snd_nxt) {
            c->snd_una = ack; c->state = S_ESTAB; c->peer_win = win;
            static const uint8_t neg[] = { 255, 251, 1, 255, 251, 3, 255, 253, 3 };   /* WILL ECHO, WILL SGA, DO SGA */
            for (unsigned i = 0; i < sizeof neg; i++) {                              /* raw: these are commands, not data */
                c->tx[c->txh] = neg[i]; c->txh = (uint16_t)((c->txh + 1) & (TCPD_TXBUF - 1));
            }
            ops->on_connect((int)(c - C));
        } else return;
    }

    if (fl & F_ACK) {                                                           /* acknowledgement processing */
        c->peer_win = win;
        uint32_t acked = ack - c->snd_una;
        uint32_t outstanding = c->snd_nxt - c->snd_una;
        if (acked && acked <= outstanding) {
            uint32_t data_acked = acked;
            if (c->fin_sent && ack == c->snd_nxt) data_acked--;                 /* the FIN consumed one sequence number */
            if (data_acked > c->inflight) data_acked = c->inflight;
            c->txt = (uint16_t)((c->txt + data_acked) & (TCPD_TXBUF - 1));
            c->inflight = (uint16_t)(c->inflight - data_acked);
            c->snd_una = ack; c->tries = 0;
            if (c->inflight) { c->rto = RTO_MIN; c->deadline = now + c->rto; }
            if (c->state == S_LAST_ACK && ack == c->snd_nxt) { drop(c, 0); return; }
        }
    }

    int need_ack = 0;
    if (dlen && c->state == S_ESTAB) {
        if (seq == c->rcv_nxt) {
            uint16_t i = 0;
            while (i < dlen && telnet_in(c, data[i])) i++;                       /* a refused byte stops us; the peer retransmits it */
            c->rcv_nxt += i;
            if (i < dlen) fl &= (uint8_t)~F_FIN;
        }
        need_ack = 1;                                                            /* in order or not, tell the peer where we are */
    }
    if ((fl & F_FIN) && seq + dlen == c->rcv_nxt && c->state == S_ESTAB) {
        c->rcv_nxt++; need_ack = 1;
        ops->on_close((int)(c - C));
        c->fin_queued = 1;                                                        /* close our side once output drains */
        c->txh = c->txt; c->inflight = 0;                                         /* terminal is gone: discard pending output */
        c->state = S_ESTAB;
        send_seg(c, c->ip, c->port, c->mac, c->snd_nxt, c->rcv_nxt, F_FIN | F_ACK, 0, 0, 0);
        c->fin_sent = 1; c->snd_nxt++; c->state = S_LAST_ACK; c->deadline = now + RTO_MAX;
        return;
    }
    if (need_ack) send_seg(c, c->ip, c->port, c->mac, c->snd_nxt, c->rcv_nxt, F_ACK, 0, 0, 0);
    pump(c);
}

void tcpd_tick(uint32_t t)
{
    now = t;
    for (int i = 0; i < TCPD_MAXCONN; i++) {
        struct conn *c = &C[i];
        if (c->state == S_SYN_RCVD && (int32_t)(now - c->deadline) >= 0) {
            if (++c->tries > 5) { drop(c, 0); continue; }
            send_seg(c, c->ip, c->port, c->mac, c->snd_una, c->rcv_nxt, F_SYN | F_ACK, 0, 0, 1);
            c->deadline = now + RTO_MAX;
        } else if (c->state == S_LAST_ACK && (int32_t)(now - c->deadline) >= 0) {
            drop(c, 0);
        } else pump(c);
    }
}

int tcpd_putc(int line, uint8_t b)
{
    struct conn *c = &C[line];
    if (c->state != S_ESTAB && c->state != S_SYN_RCVD) return 1;                  /* nobody listening: swallow it */
    if (ring_used(c) >= TCPD_TXBUF - 1) return 0;
    if (b == 255) {                                                              /* IAC must be doubled */
        if (ring_used(c) >= TCPD_TXBUF - 2) return 0;
        c->tx[c->txh] = 255; c->txh = (uint16_t)((c->txh + 1) & (TCPD_TXBUF - 1));
    }
    c->tx[c->txh] = b; c->txh = (uint16_t)((c->txh + 1) & (TCPD_TXBUF - 1));
    return 1;
}

int tcpd_connected(int line) { return C[line].state == S_ESTAB; }

int tcpd_active(void)
{
    int n = 0;
    for (int i = 0; i < TCPD_MAXCONN; i++) n += C[i].state != S_FREE;
    return n;
}
