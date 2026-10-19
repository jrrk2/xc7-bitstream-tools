// BIOS commands for the HP 2000F machine (litex/hp2000.py).  They replace the Makefile targets of the emulator
// project: image loading by TFTP, cold boot, system generation, a software front panel and the console bridge.
//
// File names are fetched from the TFTP server the BIOS already uses (remote IP, port TFTP_SERVER_PORT).
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>

#include <generated/csr.h>
#include <generated/soc.h>
#include <generated/mem.h>

#include <libbase/uart.h>
#include <libliteeth/udp.h>
#include <libliteeth/tftp.h>
#ifdef CSR_SDCARD_BASE
#include <liblitesdcard/sdcard.h>
#endif

#include "command.h"
#include "helpers.h"
#include "boot.h"
#include "taphw.h"
#include "tcpd.h"
#include "iss_rom.h"      /* generated: the 2883 disc boot ROM (boot/iss_rom.asm) as .seg text */
#include "iop_image.h"    /* generated: the IOP program (iop_words, iop_runs) from the assembled IOP segment */
#include <system.h>

#ifndef TFTP_SERVER_PORT
#define TFTP_SERVER_PORT 69
#endif
#ifndef REMOTEIP1
#define REMOTEIP1 192
#define REMOTEIP2 168
#define REMOTEIP3 1
#define REMOTEIP4 100
#endif

#define HP_DISC_BYTES   23905280u            /* one drive: 203*20*23*128 words * 2 */
#define HP_SCRATCH      (MAIN_RAM_BASE + 0x02000000u)
#define HP_SCRATCH_MAX  (16u << 20)

static unsigned long strtoul_dec(const char *s) { return strtoul(s, NULL, 10); }
static volatile uint32_t *const hp_win = (volatile uint32_t *)HP2000_WINDOW_BASE;
/* control registers: second half of the window (litex/hp2000.py REG_*) */
#define HPREG(i) (hp_win[0x10000 + (i)])
enum { R_CONTROL, R_M_RUN, R_I_RUN, R_M_SETP, R_I_SETP, R_STATUS, R_M_PC, R_M_A, R_M_B, R_M_HALT_IR, R_I_PC,
       R_I_HALT_IR, R_CON_TX, R_CON_RX, R_LINE_CONN, R_LINE_TX, R_LINE_RX, R_LINE_RX_FULL };
#define hp2000_control_read()       HPREG(R_CONTROL)
#define hp2000_control_write(v)     (HPREG(R_CONTROL) = (v))
#define hp2000_m_run_write(v)       (HPREG(R_M_RUN) = (v))
#define hp2000_i_run_write(v)       (HPREG(R_I_RUN) = (v))
#define hp2000_m_setp_write(v)      (HPREG(R_M_SETP) = (v))
#define hp2000_i_setp_write(v)      (HPREG(R_I_SETP) = (v))
#define hp2000_status_read()        HPREG(R_STATUS)
#define hp2000_m_pc_read()          HPREG(R_M_PC)
#define hp2000_m_a_read()           HPREG(R_M_A)
#define hp2000_m_b_read()           HPREG(R_M_B)
#define hp2000_m_halt_ir_read()     HPREG(R_M_HALT_IR)
#define hp2000_i_pc_read()          HPREG(R_I_PC)
#define hp2000_i_halt_ir_read()     HPREG(R_I_HALT_IR)
#define hp2000_con_tx_read()        HPREG(R_CON_TX)
#define hp2000_con_tx_pop_write(v)  (HPREG(R_CON_TX) = (v))
#define hp2000_con_rx_write(v)      (HPREG(R_CON_RX) = (v))
#define hp2000_line_conn_write(v)   (HPREG(R_LINE_CONN) = (v))
#define hp2000_line_tx_read()       HPREG(R_LINE_TX)
#define hp2000_line_tx_pop_write(v) (HPREG(R_LINE_TX) = (v))
#define hp2000_line_rx_write(v)     (HPREG(R_LINE_RX) = (v))
#define hp2000_line_rx_full_read()  HPREG(R_LINE_RX_FULL)
static uint8_t *hp_dram(void) { return (uint8_t *)(MAIN_RAM_BASE + HP2000_DRAM_OFFSET); }

/* The TFTP/boot server.  DIP switches 1-8 (switch 1 = least significant bit, ON = 1) give its last octet within the board's own /24;
 * all OFF means the address compiled in (--remote-ip). */
static uint32_t dip_value(void)
{
#ifdef CSR_DIPS_BASE
	return dips_in_read() & 0xff;
#else
	return 0;
#endif
}

static uint32_t server_ip(void)
{
	uint32_t d = dip_value();
	if (d) return (udp_get_ip() & 0xffffff00u) | d;
	return IPTOINT(REMOTEIP1, REMOTEIP2, REMOTEIP3, REMOTEIP4);
}
static int net_ready;
static void net_up(void) { if (!net_ready) { net_init(); net_ready = 1; } }

/* --------------------------------------------------------------------------------------- memory window */
static void hp_wr(int core, unsigned addr, unsigned val) { hp_win[(core ? 0x8000 : 0) | (addr & 0x7fff)] = val & 0xffff; }
static unsigned hp_rd(int core, unsigned addr) { return hp_win[(core ? 0x8000 : 0) | (addr & 0x7fff)] & 0xffff; }

/* Load a .seg file (hpasm.py output: "@origin" lines followed by octal words) already in memory. */
static int load_seg_text(int core, const char *text, size_t len)
{
	unsigned addr = 0; int words = 0;
	const char *p = text, *end = text + len;
	while (p < end) {
		while (p < end && (*p == ' ' || *p == '\n' || *p == '\r')) p++;
		if (p >= end) break;
		if (*p == '@') { p++; addr = strtoul(p, (char **)&p, 8); continue; }
		unsigned long v = strtoul(p, (char **)&p, 8);
		hp_wr(core, addr++, v); words++;
	}
	return words;
}

static int fetch(const char *name, void *buf, size_t max)
{
	net_up();
	int n = tftp_get(server_ip(), TFTP_SERVER_PORT, name, buf, max);
	if (n <= 0) printf("tftp: cannot fetch %s\n", name);
	return n;
}

static int hp_load_file(int core, const char *name)
{
	char *scratch = (char *)HP_SCRATCH;
	int n = fetch(name, scratch, HP_SCRATCH_MAX - 1);
	if (n <= 0) return -1;
	scratch[n] = 0;
	int w = load_seg_text(core, scratch, n);
	printf("%s: %d words into %s memory\n", name, w, core ? "IOP" : "main");
	return w;
}

/* --------------------------------------------------------------------------------------- run control */
static void hp_hold(int on) { hp2000_control_write((hp2000_control_read() & ~1u) | (on ? 1u : 0u)); }
static void hp_press_run(int core) { if (core) { hp2000_i_run_write(1); } else { hp2000_m_run_write(1); } }
static void hp_set_p(int core, unsigned p) { if (core) hp2000_i_setp_write(p & 0x7fff); else hp2000_m_setp_write(p & 0x7fff); }

static void hp_status(void)
{
	uint32_t s = hp2000_status_read();
	printf("main: %s P=%06o A=%06o B=%06o halt-IR=%06o\n", (s & 1) ? "halted" : "running",
	       (unsigned)hp2000_m_pc_read(), (unsigned)hp2000_m_a_read(), (unsigned)hp2000_m_b_read(),
	       (unsigned)hp2000_m_halt_ir_read());
	printf("iop : %s P=%06o halt-IR=%06o\n", (s & 2) ? "halted" : "running",
	       (unsigned)hp2000_i_pc_read(), (unsigned)hp2000_i_halt_ir_read());
	printf("tape %s, control=%x\n", (s & 4) ? "modified" : "unmodified", (unsigned)hp2000_control_read());
}

/* --------------------------------------------------------------------------------------- console bridge
 * UART <-> the HP operator console register pair (hp_console, hp_sysgen, hp_cold).  The terminal lines are served by hp_standalone
 * (telnet); the old UDP line tunnel and host/hpterm.py are gone. */
static int hp_bridge(int autorun)
{
	printf("[console bridge: Ctrl-] exits]\n");
	for (;;) {
		if (uart_read_nonblock()) {
			char c = uart_read();
			if (c == 0x1d) break;
			if (!(hp2000_status_read() & 8)) {
				hp2000_con_rx_write((c == '\r' || c == '\n') ? 015 : c);
				if (c == '\r') putchar('\n'); else putchar(c);        /* local echo, as the teleprinter did */
			}
		}
		if (hp2000_con_tx_read() & 0x100) {
			putchar(hp2000_con_tx_read() & 0x7f);
			hp2000_con_tx_pop_write(1);
		}
		if (autorun && (hp2000_status_read() & 1) && hp2000_m_halt_ir_read() == 0102077) {
			printf("[HLT 77B: RUN]\n");
			hp_press_run(0);
		}
	}
	printf("\n");
	return 0;
}

/* --------------------------------------------------------------------------------------- commands */

static void join(char *dst, size_t n, const char *a, const char *b)
{
	size_t la = strlen(a), lb = strlen(b);
	if (la + lb + 2 > n) { dst[0] = 0; return; }
	memcpy(dst, a, la); dst[la] = '/'; memcpy(dst + la + 1, b, lb + 1);
}
static int arg_core(const char *s) { return (int)strtoul_dec(s) ? 1 : 0; }

static void hp_status_h(int nb, char **p) { (void)nb; (void)p; hp_status(); }
define_command(hp_status, hp_status_h, "HP2000: show processor state", 0);

static void hp_reset_h(int nb, char **p) { (void)nb; (void)p; hp_hold(1); hp_hold(0); printf("reset\n"); }
define_command(hp_reset, hp_reset_h, "HP2000: reset the machine (processors halt)", 0);

static void hp_load_h(int nb, char **p)
{
	if (nb < 2) { printf("hp_load <core 0=main|1=iop> <file.seg>\n"); return; }
	hp_load_file(arg_core(p[0]), p[1]);
}
define_command(hp_load, hp_load_h, "HP2000: load an assembled .seg image over TFTP", 0);

static void hp_ex_h(int nb, char **p)
{
	if (nb < 2) { printf("hp_ex <core> <octal addr> [count]\n"); return; }
	int core = arg_core(p[0]); unsigned a = strtoul(p[1], NULL, 8); int n = nb > 2 ? (int)strtoul_dec(p[2]) : 1;
	for (int i = 0; i < n; i++, a++) printf("%06o: %06o\n", a & 0x7fff, hp_rd(core, a));
}
define_command(hp_ex, hp_ex_h, "HP2000: front panel EXAMINE", 0);

static void hp_dep_h(int nb, char **p)
{
	if (nb < 3) { printf("hp_dep <core> <octal addr> <octal word> ...\n"); return; }
	int core = arg_core(p[0]); unsigned a = strtoul(p[1], NULL, 8);
	for (int i = 2; i < nb; i++) hp_wr(core, a++, strtoul(p[i], NULL, 8));
}
define_command(hp_dep, hp_dep_h, "HP2000: front panel DEPOSIT", 0);

static void hp_setp_h(int nb, char **p)
{
	if (nb < 2) { printf("hp_setp <core> <octal P>\n"); return; }
	hp_set_p(arg_core(p[0]), strtoul(p[1], NULL, 8));
}
define_command(hp_setp, hp_setp_h, "HP2000: front panel set P register", 0);

static void hp_run_h(int nb, char **p)
{
	if (nb < 1) { printf("hp_run <core>\n"); return; }
	hp_press_run(arg_core(p[0]));
}
define_command(hp_run, hp_run_h, "HP2000: front panel RUN", 0);

static void hp_disc_h(int nb, char **p)
{
	if (nb < 1) { printf("hp_disc <file.img>   (23905280-byte ISS disc image, big-endian words)\n"); return; }
	int n = fetch(p[0], hp_dram(), HP_DISC_BYTES);
	if (n > 0) { hp2000_control_write(hp2000_control_read() | 8); printf("disc 0: %d bytes\n", n); }
}
define_command(hp_disc, hp_disc_h, "HP2000: fetch a disc image into DRAM and mount it", 0);

static void hp_disc_blank_h(int nb, char **p)
{
	(void)nb; (void)p;
	memset(hp_dram(), 0, HP_DISC_BYTES);
	hp2000_control_write(hp2000_control_read() | 8);
	printf("blank disc 0 mounted\n");
}
define_command(hp_disc_blank, hp_disc_blank_h, "HP2000: mount a blank disc (for system generation)", 0);

static void hp_disc_save_h(int nb, char **p)
{
	if (nb < 1) { printf("hp_disc_save <file.img>\n"); return; }
	net_up();
	int n = tftp_put(server_ip(), TFTP_SERVER_PORT, p[0], hp_dram(), HP_DISC_BYTES);
	printf("tftp put: %d\n", n);
}
define_command(hp_disc_save, hp_disc_save_h, "HP2000: store the disc image by TFTP", 0);

static void hp_tape_h(int nb, char **p)
{
	if (nb < 1) { printf("hp_tape <file.hwtape | file.tap>\n"); return; }
	uint8_t *tape = hp_dram() + HP2000_TAPE_OFFSET;
	size_t len = strlen(p[0]);
	int n;
	if (len > 4 && !strcmp(p[0] + len - 4, ".tap")) {
		n = fetch(p[0], (void *)HP_SCRATCH, HP_SCRATCH_MAX);
		if (n <= 0) return;
		size_t m = taphw_from_tap((uint8_t *)HP_SCRATCH, n, tape, 32u << 20);
		if (!m) { printf("tape too large or malformed\n"); return; }
		n = m;
	} else {
		n = fetch(p[0], tape, 32u << 20);
		if (n <= 0) return;
	}
	hp2000_control_write(hp2000_control_read() | 2);
	printf("tape mounted: %d bytes (loader command MAG select code 21)\n", n);
}
define_command(hp_tape, hp_tape_h, "HP2000: fetch a tape (.tap converted on the fly) and mount it", 0);

static void hp_tape_rw_h(int nb, char **p) { (void)nb; (void)p; hp2000_control_write(hp2000_control_read() | 4); printf("write ring in\n"); }
define_command(hp_tape_rw, hp_tape_rw_h, "HP2000: put the write ring in the mounted tape", 0);

static void hp_tape_blank_h(int nb, char **p)
{
	(void)nb; (void)p;
	uint8_t *tape = hp_dram() + HP2000_TAPE_OFFSET;
	memset(tape, 0, 8); tape[0] = 0xff; tape[1] = 0xff;
	hp2000_control_write(hp2000_control_read() | 2 | 4);
	printf("blank writable tape mounted\n");
}
define_command(hp_tape_blank, hp_tape_blank_h, "HP2000: mount a blank writable tape", 0);

static void hp_tape_save_h(int nb, char **p)
{
	if (nb < 1) { printf("hp_tape_save <file.tap>\n"); return; }
	uint8_t *tape = hp_dram() + HP2000_TAPE_OFFSET;
	size_t m = taphw_to_tap(tape, 32u << 20, (uint8_t *)HP_SCRATCH, HP_SCRATCH_MAX);
	if (!m) { printf("tape image malformed or too large\n"); return; }
	net_up();
	printf("tftp put: %d\n", tftp_put(server_ip(), TFTP_SERVER_PORT, p[0], (void *)HP_SCRATCH, m));
}
define_command(hp_tape_save, hp_tape_save_h, "HP2000: convert the tape back to .tap and store it by TFTP", 0);

static void hp_type_h(int nb, char **p)
{
	if (nb < 1) { printf("hp_type <text>   (\\n = RETURN)\n"); return; }
	for (int a = 0; a < nb; a++) {
		for (const char *s = p[a]; *s; s++) {
			int c = *s;
			if (c == '\\' && s[1] == 'n') { c = 015; s++; }
			while (hp2000_status_read() & 8) udp_service();
			hp2000_con_rx_write(c);
		}
		while (hp2000_status_read() & 8) udp_service();
		hp2000_con_rx_write(' ');
	}
}
define_command(hp_type, hp_type_h, "HP2000: type text on the operator console", 0);

static void hp_console_h(int nb, char **p) { (void)nb; (void)p; hp_bridge(0); }
define_command(hp_console, hp_console_h, "HP2000: operator console bridge on the UART (Ctrl-] exits)", 0);

/* copy the built-in IOP program into IOP memory */
static int load_iop_builtin(void)
{
	const uint16_t *w = iop_words; int n = 0;
	for (unsigned i = 0; i < sizeof iop_runs / sizeof iop_runs[0]; i++)
		for (unsigned j = 0; j < iop_runs[i].n; j++, n++) hp_wr(1, iop_runs[i].org + j, *w++);
	return n;
}

/* Load the processors' code (built in) and, unless the SD card supplied it, the disc image over TFTP; press RUN.  Returns 0 on success.
 * With the disc already in DDR (from the SD card) no network or server is needed at all. */
static int hp_cold_start(const char *dir, int load_disc)
{
	char name[96];
	hp_hold(1);
	printf("iop: %d words into IOP memory (built in)\n", load_iop_builtin());
	printf("iss_rom: %d words into main memory (built in)\n", load_seg_text(0, iss_rom_seg, sizeof iss_rom_seg - 1));
	if (load_disc) {
		join(name, sizeof name, dir, "tsb.img");
		if (fetch(name, hp_dram(), HP_DISC_BYTES) <= 0) return -1;
	}
	flush_cpu_dcache();
	hp2000_control_write(hp2000_control_read() | 8);
	hp_hold(0);
	hp_set_p(1, 2); hp_press_run(1);
	hp_set_p(0, 077750); hp_press_run(0);
	return 0;
}

/* cold boot from a disc image: iop.seg, iss_rom.seg and tsb.img under the given TFTP directory */
static void hp_cold_h(int nb, char **p)
{
	if (hp_cold_start(nb > 0 ? p[0] : "hp2000", 1)) return;
	printf("cold boot: answer CONFIGURATION OPTIONS? (NO), DATE?, TIME?\n");
	hp_bridge(1);
}
define_command(hp_cold, hp_cold_h, "HP2000: cold boot TSB from <dir>/tsb.img (default dir hp2000)", 0);

/* system generation from the paper tape held in ROM */
static void hp_sysgen_h(int nb, char **p)
{
	char name[96];
	const char *dir = nb > 0 ? p[0] : "hp2000";
	hp_hold(1);
	join(name, sizeof name, dir, "iop.seg");      if (hp_load_file(1, name) < 0) return;
	join(name, sizeof name, dir, "loader.seg");   if (hp_load_file(0, name) < 0) return;
	memset(hp_dram(), 0, HP_DISC_BYTES);
	hp2000_control_write(hp2000_control_read() | 8);
	hp_hold(0);
	hp_set_p(1, 2); hp_press_run(1);
	hp_set_p(0, 02000); hp_press_run(0);
	printf("system generation from ROM tape: LIBRARY? NO, SYSTEM IDENTIFICATION? name, ... (operator manual IV)\n");
	printf("finish with SLEEP, then: hp_disc_save <name>.img\n");
	hp_bridge(0);
}
define_command(hp_sysgen, hp_sysgen_h, "HP2000: generate a new TSB system onto a blank disc", 0);

/* --------------------------------------------------------------------------------------- SD card as the disc
 * Card layout (raw, no filesystem): block 0 = header (magic, image size), blocks 1.. = the disc image, 512 bytes each.  At boot the image
 * is read into DDR, where the HP disc controller works on it directly (instant updates, no SD traffic while the machine runs).  When the
 * operator puts TSB to sleep (SLEEP prints DONE) the CPU compares the DDR image with a shadow copy and writes the changed blocks back. */
static uint32_t sa_now_ms(int resync);
#ifdef CSR_SDCARD_BASE
#define SD_DATA_BLOCK  1u
#define SD_DISC_BLOCKS (HP_DISC_BYTES / 512u)
static const char sd_magic[16] = "HP2000-DISC-V1";
static uint8_t *sd_shadow(void) { return (uint8_t *)(MAIN_RAM_BASE + 0x20000000u); }
static uint8_t *sd_hdr(void) { return (uint8_t *)(MAIN_RAM_BASE + 0x01020000u); }
static int sd_ok;                                              /* card initialised and carrying a disc: saving is possible */

static int sd_header_valid(void)
{
	uint8_t *h = sd_hdr();
	if (sdcard_read(0, 1, h) != 0) return 0;
	for (unsigned i = 0; i < sizeof sd_magic; i++) if (h[i] != (uint8_t)sd_magic[i]) return 0;      /* the BIOS libc has no memcmp */
	return ((uint32_t)h[16] << 24 | h[17] << 16 | h[18] << 8 | h[19]) == HP_DISC_BYTES;
}

/* read the disc image from the card into DDR; 0 = ok */
static int sd_load_disc(void)
{
	if (!sdcard_init()) { printf("SD: no card\n"); return -1; }
	if (!sd_header_valid()) { printf("SD: card has no HP 2000 disc (hp_sd_format creates one)\n"); return -1; }
	printf("SD: loading disc");
	for (uint32_t b = 0; b < SD_DISC_BLOCKS; b += 2048) {
		uint32_t n = SD_DISC_BLOCKS - b < 2048 ? SD_DISC_BLOCKS - b : 2048;
		if (sdcard_read(SD_DATA_BLOCK + b, n, hp_dram() + (size_t)b * 512) != 0) { printf(" read error at block %u\n", (unsigned)b); return -1; }
		if ((b & 0x3fff) == 0) putchar('.');
	}
	printf(" done\n");
	flush_cpu_dcache();
	{ uint32_t sum = 0, *w = (uint32_t *)hp_dram(); for (uint32_t i = 0; i < HP_DISC_BYTES / 4; i++) sum = (sum << 1 | sum >> 31) ^ w[i];
	  printf("SD: disc checksum %08x\n", (unsigned)sum); }
	memcpy(sd_shadow(), hp_dram(), HP_DISC_BYTES);
	sd_ok = 1;
	return 0;
}

/* write the disc (already in DDR) to the card with a header; 0 = ok */
static int sd_write_disc(void)
{
	if (!sdcard_init()) { printf("SD: no card\n"); return -1; }
	uint8_t *h = sd_hdr();
	memset(h, 0, 512); memcpy(h, sd_magic, sizeof sd_magic);
	h[16] = HP_DISC_BYTES >> 24; h[17] = HP_DISC_BYTES >> 16; h[18] = HP_DISC_BYTES >> 8; h[19] = HP_DISC_BYTES;
	flush_cpu_dcache();
	printf("SD: writing disc");
	for (uint32_t b = 0; b < SD_DISC_BLOCKS; b += 2048) {
		uint32_t n = SD_DISC_BLOCKS - b < 2048 ? SD_DISC_BLOCKS - b : 2048;
		if (sdcard_write(SD_DATA_BLOCK + b, n, hp_dram() + (size_t)b * 512) != 0) { printf(" write error at block %u\n", (unsigned)b); return -1; }
		if ((b & 0x3fff) == 0) putchar('.');
	}
	if (sdcard_write(0, 1, h) != 0) { printf(" header write error\n"); return -1; }       /* the header last: a half-written card is not recognised */
	printf(" done\n");
	memcpy(sd_shadow(), hp_dram(), HP_DISC_BYTES);
	sd_ok = 1;
	return 0;
}

/* write every block of the disc that differs from the shadow (= what the card holds) to the card; returns the number written, -1 on error */
static int sd_save_changes(void)
{
	if (!sd_ok) return -1;
	flush_cpu_dcache(); flush_l2_cache();
	int written = 0;
	uint32_t *d = (uint32_t *)hp_dram(), *s = (uint32_t *)sd_shadow();
	for (uint32_t blk = 0; blk < SD_DISC_BLOCKS; blk++, d += 128, s += 128) {
		int diff = 0;
		for (int i = 0; i < 128; i++) if (d[i] != s[i]) { diff = 1; break; }
		if (!diff) continue;
		memcpy(s, d, 512);
		flush_cpu_dcache();
		if (sdcard_write(SD_DATA_BLOCK + blk, 1, (uint8_t *)s) != 0) { printf("SD: write error at block %u\n", (unsigned)blk); return -1; }
		written++;
	}
	return written;
}

static void hp_sd_save_h(int nb, char **p)
{
	(void)nb; (void)p;
	int n = sd_save_changes();
	if (n >= 0) printf("SD: %d block(s) written\n", n); else printf("SD: not available (no card, or the disc was not loaded from it)\n");
}
define_command(hp_sd_save, hp_sd_save_h, "HP2000: write the changed disc blocks to the SD card", 0);

static void hp_sd_format_h(int nb, char **p)
{
	char name[96];
	join(name, sizeof name, nb > 0 ? p[0] : "hp2000", "tsb.img");
	printf("WARNING: this overwrites the first %u MB of the SD card\n", (unsigned)(HP_DISC_BYTES >> 20) + 1);
	if (fetch(name, hp_dram(), HP_DISC_BYTES) <= 0) return;
	sd_write_disc();
}
define_command(hp_sd_format, hp_sd_format_h, "HP2000: write <dir>/tsb.img (default dir hp2000) to the SD card as the disc", 0);
#else
#define sd_ok 0
static int sd_load_disc(void) { return -1; }
static int sd_save_changes(void) { return -1; }
#endif

/* --------------------------------------------------------------------------------------- standalone: telnet terminal lines
 * The BIOS's default boot.  DHCP (static address if no server answers), cold boot of TSB from the TFTP server, then this CPU is the
 * terminal concentrator: telnet port 23 = one HP terminal line per connection (carrier follows the session).  The operator console
 * stays on the UART; its three start-up questions are answered here so that nothing but a telnet login is needed. */
extern void udp_set_tcp_hook(void (*h)(const uint8_t *, const uint8_t *, uint32_t));
extern int udp_send_ip(const uint8_t *dmac, const uint8_t *pkt, uint32_t len);

#ifndef HP2000_DATE
#define HP2000_DATE "277/74"       /* TSB wants day-of-year/year; the machine has no calendar */
#endif
#ifndef HP2000_TIME
#define HP2000_TIME "0900"
#endif

static uint32_t sa_now_ms(int resync)       /* timer0 is also used by busy_wait() (the SD driver): resync after those, time keeps counting */
{
	static int init; static uint32_t last, rem, ms;
	if (resync) { init = 0; return ms; }
	timer0_update_value_write(1);
	if (!init) { timer0_en_write(0); timer0_load_write(0); timer0_reload_write(0xffffffffu); timer0_en_write(1); init = 1; rem = 0;
	             timer0_update_value_write(1); last = timer0_value_read(); return ms; }
	uint32_t v = timer0_value_read();
	rem += last - v; last = v;                                   /* the counter runs down */
	ms += rem / (CONFIG_CLOCK_FREQUENCY / 1000); rem %= (CONFIG_CLOCK_FREQUENCY / 1000);
	return ms;
}

#define SA_LQ 128
struct sa_q { uint8_t b[SA_LQ]; uint8_t h, t; };
#define sa_lq ((struct sa_q *)(MAIN_RAM_BASE + 0x01010000u))     /* typed characters waiting for the multiplexer, per line (in DDR: SRAM is tiny) */
static uint32_t sa_carrier;

static int sa_send_ip(const uint8_t *dmac, const uint8_t *pkt, uint32_t len) { return udp_send_ip(dmac, pkt, len); }
static void sa_flush(int line) { sa_lq[line].h = sa_lq[line].t = 0; }
/* A closed telnet session must log its user off: TSB does not act on a dropped carrier, and a user left logged on blocks SLEEP for ever.
 * So the line keeps its carrier while the BIOS types BREAK, BYE (state 1 -> 2 -> 3), then drops the carrier. */
static int sa_push(int line, uint8_t b);
static struct { uint8_t state; uint32_t t; } sa_hang[32];
static uint32_t sa_t;                                          /* current time, ms */
static void sa_connect(int line) { sa_flush(line); sa_hang[line].state = 0; sa_carrier |= 1u << line; hp2000_line_conn_write(sa_carrier); printf("[line %d connected]\n", line); }
static void sa_close(int line) { sa_flush(line); sa_hang[line].state = 1; sa_hang[line].t = sa_t; printf("[line %d closed: logging off]\n", line); }
static void sa_hangup_step(void)
{
	for (int i = 0; i < 32; i++) {
		if (!sa_hang[i].state || (int32_t)(sa_t - sa_hang[i].t) < 0) continue;
		switch (sa_hang[i].state) {
		case 1: sa_push(i, 0x80); sa_hang[i].state = 2; sa_hang[i].t = sa_t + 1500; break;                   /* BREAK: stop what it is doing */
		case 2: sa_push(i, 'B'); sa_push(i, 'Y'); sa_push(i, 'E'); sa_push(i, 015); sa_hang[i].state = 3; sa_hang[i].t = sa_t + 4000; break;
		case 3: sa_carrier &= ~(1u << i); hp2000_line_conn_write(sa_carrier); sa_hang[i].state = 0; break;   /* now hang up */
		}
	}
}
static int sa_push(int line, uint8_t b)                           /* queue one byte for the multiplexer as it is (bit 7 = BREAK) */
{
	uint8_t n = (sa_lq[line].h + 1) % SA_LQ;
	if (n == sa_lq[line].t) return 0;
	sa_lq[line].b[sa_lq[line].h] = b;
	sa_lq[line].h = n;
	return 1;
}
static int sa_char(int line, uint8_t c) { return sa_push(line, c ? (c & 0x7f) : 0x80); }   /* tcpd reports BREAK as 0 */
static const struct tcpd_ops sa_ops = { sa_send_ip, sa_connect, sa_char, sa_close };
static void sa_tcp_hook(const uint8_t *mac, const uint8_t *ip, uint32_t len) { tcpd_rx(mac, ip, len); }

/* the operator console's start-up dialogue: reply when its output ends with one of the questions */
static const char *sa_answer;
static int sa_up;                                              /* TSB has printed READY on the console: any later halt of the main CPU is SLEEP */
static void sa_console_out(char c)
{
	static char tail[24];
	memmove(tail, tail + 1, sizeof tail - 2); tail[sizeof tail - 2] = c; tail[sizeof tail - 1] = 0;
	if (sa_answer) return;
	int n = (int)strlen(tail);
	#define ENDS(s) (n >= (int)sizeof(s) - 1 && !strcmp(tail + n - (sizeof(s) - 1), s))
	if (ENDS("OPTIONS? ") || ENDS("OPTIONS?")) sa_answer = "NO\r";
	else if (ENDS("DATE?") || ENDS("DATE? ")) sa_answer = HP2000_DATE "\r";
	else if (ENDS("TIME?") || ENDS("TIME? ")) sa_answer = HP2000_TIME "\r";
	else if (ENDS("READY")) sa_up = 1;
}

static void hp_standalone(void)
{
	printf("\nHP 2000F standalone: DHCP, cold boot over TFTP, telnet lines on port 23\n");
#ifdef ETH_WITH_DHCP
	dhcp_get_ip();
#else
	net_init();
#endif
	net_ready = 1;
	{ uint32_t sv = server_ip(); printf("boot server %d.%d.%d.%d (DIP switches %s)\n", (int)(sv >> 24), (int)((sv >> 16) & 255), (int)((sv >> 8) & 255), (int)(sv & 255),
	         dip_value() ? "set" : "all off: built-in address"); }
	int have_sd_disc = (sd_load_disc() == 0);
	sa_now_ms(1);
	if (!have_sd_disc) printf("disc image will come from TFTP (not persistent)\n");
	for (;;) {                                           /* the TFTP server may not be up yet: keep trying */
		if (hp_cold_start("hp2000", !have_sd_disc) == 0) break;
		printf("cold boot failed; retrying in 5 s\n");
		busy_wait(5000);
	}
	sa_now_ms(1);
	memset(sa_lq, 0, 32 * sizeof(struct sa_q));
	hp2000_line_conn_write(0);
	tcpd_init(udp_get_ip(), 23, &sa_ops);
	udp_set_callback(0);
	udp_set_tcp_hook(sa_tcp_hook);
	printf("[serving telnet on port 23; operator console on this UART]\n");

	uint32_t tick = sa_now_ms(0);
	for (;;) {
		udp_service();
		uint32_t t = sa_now_ms(0);
		if (t != tick) { tick = t; sa_t = t; tcpd_tick(t); sa_hangup_step(); }

		if (uart_read_nonblock()) {                             /* operator console from the UART */
			char c = uart_read();
			if (c == 0x1d) {                                        /* Ctrl-]: save the disc to the SD card now */
				int n = sd_save_changes(); sa_now_ms(1);
				if (n >= 0) printf("\n[SD: %d block(s) written]\n", n); else printf("\n[SD: not saved (no card)]\n");
			} else if (!(hp2000_status_read() & 8)) {
				hp2000_con_rx_write((c == '\r' || c == '\n') ? 015 : c);
				if (c == '\r') putchar('\n'); else putchar(c);
			}
		} else if (sa_answer && !(hp2000_status_read() & 8)) {  /* ... or the scripted start-up answers */
			char c = *sa_answer++;
			hp2000_con_rx_write(c == '\r' ? 015 : c);
			if (!*sa_answer) sa_answer = 0;
		}
		if (hp2000_con_tx_read() & 0x100) {
			char c = hp2000_con_tx_read() & 0x7f;
			putchar(c); sa_console_out(c);
			hp2000_con_tx_pop_write(1);
		}

		uint32_t full = hp2000_line_rx_full_read();             /* typed characters -> multiplexer */
		for (int i = 0; i < 32; i++)
			if (sa_lq[i].h != sa_lq[i].t && !((full >> i) & 1)) {
				hp2000_line_rx_write(sa_lq[i].b[sa_lq[i].t] | (i << 8));
				sa_lq[i].t = (sa_lq[i].t + 1) % SA_LQ;
				full = hp2000_line_rx_full_read();
			}
		uint32_t v = hp2000_line_tx_read();                     /* multiplexer output -> telnet, as far as the connection can take it */
		if ((v >> 16) & 1 && tcpd_putc((v >> 8) & 31, v & 0x7f)) hp2000_line_tx_pop_write(1);

		if ((hp2000_status_read() & 1) && hp2000_m_halt_ir_read() == 0102077) {
			if (!sa_up) hp_press_run(0);                          /* HLT 77B in the pre-boot = press RUN */
			else {                                                /* SLEEP: TSB is down; save the disc, then start it again */
				printf("[SLEEP: saving the disc to the SD card]\n");
				int n = sd_save_changes();
				sa_now_ms(1);
				if (n >= 0) printf("[SD: %d block(s) written]\n", n); else printf("[SD: not saved (no card)]\n");
				sa_up = 0;
				printf("[restarting TSB]\n");
				if (hp_cold_start("hp2000", 0)) printf("restart failed\n");
			}
		}
	}
}
static void hp_standalone_h(int nb, char **p) { (void)nb; (void)p; hp_standalone(); }
define_command(hp_standalone, hp_standalone_h, "HP2000: DHCP, cold boot, serve telnet terminal lines (the default boot)", 0);

/* called from the BIOS boot sequence; never returns */
int hp2000_boot_method(void)
{
	printf("\nHP 2000F: press any key within 5 s to stop at the BIOS prompt (hp_sd_format, hp_standalone, ...)\n");
	for (int i = 0; i < 50; i++) {
		if (uart_read_nonblock()) { (void)uart_read(); printf("boot cancelled\n"); return 1; }
		busy_wait(100);
	}
	hp_standalone();
	return 0;
}
