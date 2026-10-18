#!/usr/bin/env python3
"""Make a private copy of libliteeth's udp.c with a TCP hook: IP protocol 6 frames are handed to a callback together with the
sender's MAC, and udp_send_ip() transmits a complete IP packet to a given MAC.  Usage: patch_udp.py <udp.c in> <out>"""
import sys
s = open(sys.argv[1]).read()
def sub(old, new):
    global s
    assert s.count(old) == 1, old
    s = s.replace(old, new)
sub("		if (hdr->proto == IP_PROTO_UDP)\n			process_udp();",
    "		if (hdr->proto == 6 && tcp_hook) {\n"
    "			uint32_t n = ntohs(hdr->total_length);\n"
    "			if (n >= 40 && sizeof(struct ethernet_header) + n <= rxlen)\n"
    "				tcp_hook(rxbuffer->frame.eth_header.srcmac, (const uint8_t *)hdr, n);\n"
    "		} else if (hdr->proto == IP_PROTO_UDP)\n			process_udp();")
sub("static void process_frame(void)\n{",
    "static void (*tcp_hook)(const uint8_t *, const uint8_t *, uint32_t);\n"
    "void udp_set_tcp_hook(void (*h)(const uint8_t *, const uint8_t *, uint32_t)) { tcp_hook = h; }\n\n"
    "int udp_send_ip(const uint8_t *dmac, const uint8_t *pkt, uint32_t len)\n{\n"
    "	if (sizeof(struct ethernet_header) + len + ETH_TX_CRC_SIZE > ETHMAC_SLOT_SIZE) return 0;\n"
    "	fill_eth_header(&txbuffer->frame.eth_header, dmac, my_mac, ETHERTYPE_IP);\n"
    "	for (uint32_t i = 0; i < len; i++) ((uint8_t *)&txbuffer->frame.contents)[i] = pkt[i];\n"
    "	txlen = len + sizeof(struct ethernet_header);\n"
    "	if (txlen < ARP_PACKET_LENGTH) txlen = ARP_PACKET_LENGTH;\n"
    "	send_packet();\n	return 1;\n}\n\n"
    "static void process_frame(void)\n{")
open(sys.argv[2], 'w').write(s)
