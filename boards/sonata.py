"""Sonata FPGA configuration image formatter."""
import struct
from pathlib import Path

FAMILY_ID = 0x6CE29E6B
PAYLOAD_SIZE = 256
BLOCK_DATA_SIZE = 476
FLAG_FAMILY_ID_PRESENT = 0x00002000
MAGIC_START0 = 0x0A324655
MAGIC_START1 = 0x9E5D5157
MAGIC_END = 0x0AB16F30


def write_uf2(bitstream, output, base_address=0):
    output = Path(output)
    block_count = (len(bitstream) + PAYLOAD_SIZE - 1) // PAYLOAD_SIZE
    with output.open("wb") as destination:
        for block_number in range(block_count):
            offset = block_number * PAYLOAD_SIZE
            payload = bitstream[offset : offset + PAYLOAD_SIZE]
            payload += bytes(BLOCK_DATA_SIZE - len(payload))
            destination.write(
                struct.pack(
                    "<IIIIIIII",
                    MAGIC_START0,
                    MAGIC_START1,
                    FLAG_FAMILY_ID_PRESENT,
                    base_address + offset,
                    PAYLOAD_SIZE,
                    block_number,
                    block_count,
                    FAMILY_ID,
                )
                + payload
                + struct.pack("<I", MAGIC_END)
            )