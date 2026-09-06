# A netbooted self-test for the VC707 LiteX SoC

A small bare-metal program the SoC fetches over TFTP and runs from DDR3.

## Why it is not a hello-world

The BIOS already proves a good deal before it looks for a boot image: it
calibrates the DDR3 PHY, runs a 2 MiB memtest and answers ARP. What it does
not prove is that a program *fetched over the network* runs from DDR3 and
finds the machine intact. That is a different claim, and the one that matters
before anything larger is booted here.

So the test:

* reports what it is running on, from the SoC's own generated headers;
* walks 64 MiB of DDR3 at `MAIN_RAM_BASE + 16 MiB`, clear of its own load
  address, with the address-dependent pattern `index * 2654435761 ^ index << 3`
  rather than a counter. A counter cannot tell a stuck bit from aliased
  address lines: with address lines swapped or shorted, the readback of a
  counter still looks like a counter;
* reports the first failing address with expected and actual values, because
  "N errors" alone does not distinguish one weak bit from a wholly unmapped
  region;
* halts rather than returning, so the verdict stays on the terminal instead of
  scrolling away when the BIOS reboots and network-boots again.

## Verified result (2026-09-05)

Built against `../vc707-litex-ddr-eth/build-vivado` and delivered to MAC
`10:e2:d5:00:00:07` alone:

```
[1/2] netboot ....... PASS (this code is running from main RAM)
[2/2] DDR3 64 MiB at 0x41000000
  writing  64 MiB... done
  reading  64 MiB... done
  PASS
 RESULT: PASS
```

The server side of that transfer, showing the per-MAC dispatch working:

```
192.168.1.50 [10:e2:d5:00:00:07] asked for 'boot.bin'
     -> 10:e2:d5:00:00:07/boot.bin (its own directory)
     sent 4288 bytes in 5 block(s) of 1024
```

## Building and delivering

The image is compiled against **one specific SoC's** headers -- its CSR map,
its memory map, its MAC -- and is not valid for another. `BUILD_DIR` names it:

```sh
make BUILD_DIR=../vc707-litex-ddr-eth/build-vivado
cp selftest.bin ~/tftp-vc707/10:e2:d5:00:00:07/boot.bin
../../scripts/tftp_serve.py --root ~/tftp-vc707 --port 6969
```

`scripts/tftp_serve.py` resolves the requesting IP to a MAC through the host's
ARP table and prefers `<root>/<mac>/<file>`, so each board gets its own
payload. That matters because more than one LiteX SoC network-boots here --
the Sonata Linux triage in `~/sonata-linux` is another -- and out of the box
they share both a MAC (`10:e2:d5:00:00:00`, LiteEth's default) and a boot
filename the BIOS does not let the target change. The SoC's own MAC, its own
TFTP port (`TFTP_SERVER_PORT`, a `#ifndef` in the BIOS that a SoC constant
overrides) and a per-MAC root keep the two triages apart, and leave the system
`tftpd-hpa` on port 69 -- which the Sonata setup depends on -- untouched.

## Note on resets

While this image is what the server offers, CPU_RESET re-runs the BIOS, which
network-boots it again. To reach the BIOS console instead, move `boot.bin`
aside on the server.
