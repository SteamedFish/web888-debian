#!/usr/bin/env python3
"""Web-888 hardware state probe — runs ON the device.

Dumps every register group relevant to stock-vs-Debian diffing so that
our Debian system and the stock firmware can be diffed apples-to-apples.
Pure stdlib (mmap /dev/mem, raw i2c via fcntl). Read-only: the only
exception is NOTHING — this script must never write registers, so it is
safe to run on the stock card as well.
"""
import os, sys, mmap, struct, time, fcntl, statistics

def rd32(mm, off):
    return struct.unpack("<I", mm[off:off+4])[0]

def dump_mem(base, offs, name):
    try:
        fd = os.open("/dev/mem", os.O_RDONLY | os.O_SYNC)
        mm = mmap.mmap(fd, 0x1000, mmap.MAP_SHARED, mmap.PROT_READ, offset=base)
        print("[%s @0x%08x]" % (name, base))
        for o in offs:
            print("  +0x%03x = 0x%08x" % (o, rd32(mm, o)))
        mm.close(); os.close(fd)
    except Exception as e:
        print("[%s @0x%08x] ERROR: %s" % (name, base, e))

def si5351():
    try:
        I2C_SLAVE = 0x0703
        fd = os.open("/dev/i2c-0", os.O_RDWR)
        fcntl.ioctl(fd, I2C_SLAVE, 0x60)
        regs = [0, 1, 3, 15, 16, 17, 18, 19, 20, 21, 22, 23] + \
               list(range(26, 34)) + list(range(34, 42)) + list(range(42, 50)) + \
               [177, 183, 187]
        print("[Si5351 @0x60 /dev/i2c-0, single-byte reads]")
        for r in regs:
            os.write(fd, bytes([r]))
            v = os.read(fd, 1)[0]
            print("  reg%3d = 0x%02x" % (r, v))
        os.close(fd)
    except Exception as e:
        print("[Si5351] ERROR: %s" % e)

def ring(base, name):
    try:
        fd = os.open("/dev/mem", os.O_RDONLY | os.O_SYNC)
        mm = mmap.mmap(fd, 0x2000, mmap.MAP_SHARED, mmap.PROT_READ, offset=base)
        s1 = mm[:]; time.sleep(1.0); s2 = mm[:]
        diff = sum(1 for a, b in zip(s1, s2) if a != b)
        print("[%s @0x%08x] diff=%d/8192 -> %s" %
              (name, base, diff, "LIVE" if diff > 10 else "STATIC"))
        words = struct.unpack("<2048I", s1)
        samples = [struct.unpack("<i", struct.pack("<I", w))[0] for w in words[0::4]]
        abss = [abs(s) for s in samples]
        print("  word0 stats: mean_abs=%.0f max=%d min=%d" %
              (statistics.mean(abss), max(samples), min(samples)))
        print("  head32: %s" % s1[:32].hex())
        mm.close(); os.close(fd)
    except Exception as e:
        print("[%s @0x%08x] ERROR: %s" % (name, base, e))

print("=== hw-probe %s ===" % time.strftime("%Y-%m-%d %H:%M:%S"))
si5351()
dump_mem(0xF8000000, [0x100, 0x120, 0x170, 0x180, 0x190, 0x1A0, 0x240], "SLCR")
dump_mem(0xF8007000, [0x00, 0x04, 0x0c], "devcfg")
dump_mem(0x40000000, [0x00, 0x04, 0x0c, 0x6c, 0x74, 0x78, 0x80, 0x84, 0x8c, 0x90], "PL cfg")
dump_mem(0x41000000, [0x00, 0x04, 0x08], "PL status")
dump_mem(0xE000A000, [0x00, 0x40], "PS GPIO (MASK_DATA_0_LSW, DATA_0)")
ring(0x1bc80000, "RX ring")
ring(0x1bd00000, "WF ring")
