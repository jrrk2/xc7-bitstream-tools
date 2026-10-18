/* Minimal TCP server with a telnet layer, for the HP 2000 terminal lines.
 *
 * Freestanding and portable: it never touches hardware.  The caller feeds it received IPv4 packets and a millisecond
 * clock and supplies a function that transmits IPv4 packets (the Ethernet header is the caller's business; the MAC
 * the peer used is passed in so no ARP is needed).  One connection = one terminal line (0..TCPD_MAXCONN-1).
 *
 * Deliberately simple: in-order delivery only (out-of-order segments are dropped and the peer retransmits), one
 * unacknowledged segment per connection, fixed receive window, no options except MSS.
 */
#ifndef TCPD_H
#define TCPD_H
#include <stdint.h>

#define TCPD_MAXCONN 32
#define TCPD_TXBUF   256            /* per-connection output queue, power of two */

struct tcpd_ops {
    /* transmit an IPv4 packet (header + TCP) to the peer whose Ethernet address is dmac */
    int  (*send_ip)(const uint8_t *dmac, const uint8_t *ip_pkt, uint32_t len);
    void (*on_connect)(int line);               /* a terminal connected on this line */
    int  (*on_char)(int line, uint8_t c);       /* a character typed (telnet already decoded; Ctrl-C arrives as 0 = BREAK) */
    void (*on_close)(int line);                 /* the connection ended */
};

void tcpd_init(uint32_t my_ip, uint16_t port, const struct tcpd_ops *ops);
void tcpd_rx(const uint8_t *src_mac, const uint8_t *ip_pkt, uint32_t len);   /* one received IPv4 packet */
void tcpd_tick(uint32_t now_ms);                                            /* call often: retransmit and output */
int  tcpd_putc(int line, uint8_t c);            /* queue a character for the terminal; 0 if the queue is full */
int  tcpd_connected(int line);
int  tcpd_active(void);                          /* number of open connections */
#endif
