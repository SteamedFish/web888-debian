# boot.bin layout & repack spec (verified)

Verified against the stock card's `boot.bin` using bootgen v2026.1
(`bootgen -arch zynq -read`), `arm-linux-gnueabihf-objdump` on the extracted
SSBL bytes, and a live dump of the on-board 24c64 EEPROM (`docs/research/hardware-facts.md`).
This supersedes all AI-generated guesses about "hardcoded offsets" in
`docs/boot-chain-analysis.md` and friends.

## Boot flow (no U-Boot anywhere)

```
BootROM
  └─ FSBL (reused stock binary, does ps7_init + Si5351 I2C setup)
       │  reads boot.bin partition table, copies each partition to its load addr
       ├─ SSBL  → 0x00100000   (52-byte stub)
       ├─ DTB   → 0x02000000
       ├─ zImage→ 0x02008000
       └─ initrd→ 0x03000000   (only when an initrd partition exists)
       └─ jumps to SSBL @ 0x00100000
            └─ SSBL sets r0=0, r1=0xFFFFFFFF, r2=0x02000000, pc=0x02008000
                 └─ Linux kernel
```

There is **no partition-table-driven loader**. The FSBL does all loading from
partition headers; the SSBL is a fixed jump stub. Offsets inside boot.bin are
therefore free — only the **load addresses** are contractual.

## Stock boot.bin partition table (bootgen -read, verified)

| # | partition        | file offset | load addr    | exec addr    | length (bytes) |
|---|------------------|-------------|--------------|--------------|----------------|
| 1 | executable.elf   | 0x00001700  | 0x00000000   | 0x00000000   | 114,696 (0x1C008) — FSBL |
| 2 | ssbl.elf         | 0x0001D740  | 0x00100000   | 0x00100000   | 52 |
| 3 | initrd.dtb       | 0x0001D780  | 0x02000000   | —            | 12,456 (DTB, name is misleading) |
| 4 | zImage.bin       | 0x00020840  | 0x02008000   | —            | 4,727,728 (self-extracting; inner gzip at +0x7068) |
| 5 | initrd.bin       | 0x004A3200  | 0x03000000   | —            | 4,194,304 (exactly 4 MiB, matches `initrd=` bootarg) |

Boot header: `iht_offset 0x8c0`, `pht_offset 0xc80`, 5 images, no encryption,
no authentication. Extracted copies: `work/stock/fsbl.bin`, `work/stock/ssbl.bin`.

## SSBL (52 bytes @ 0x00100000) — full disassembly

```asm
mov  r3, #0xF8000000        @ SLCR base
movw r2, #0xDF0D
str  r2, [r3, #8]           @ SLCR_UNLOCK
mov  r2, #31
str  r2, [r3, #0x910]       @ SLCR reg 0x910 = 0x1F (stock quirk, keep stub as-is)
mov  r0, #0                 @ r0 = 0          (kernel ABI)
add  r3, r3, #0xF00000      @ r3 = 0xF8F00000 (SCU)
mov  r2, #0x02000000        @ r2 = DTB addr   (kernel ABI)
str  r0, [r3, #0x40]        @ SCU filtering start = 0
mvn  r1, #0                 @ r1 = 0xFFFFFFFF (kernel ABI)
ldr  r3, [pc]               @ 0x02008000
bx   r3
.word 0x02008000
```

## Repack contract (M4 hard requirements)

| component | source | requirement |
|-----------|--------|-------------|
| FSBL      | `work/stock/fsbl.bin` verbatim, `[bootloader]` | must run first (does ps7_init + Si5351) |
| SSBL      | `work/stock/ssbl.bin` verbatim | load=exec `0x00100000` |
| DTB       | built in M4 from modified stock dts | load `0x02000000` (hardcoded in SSBL r2) |
| zImage    | built in M3 (linux-xlnx 6.6) | load `0x02008000` (hardcoded in SSBL literal) |
| initrd    | busybox initramfs (M5 first-boot gate only) | load `0x03000000`, `≤ 4 MiB` if stock bootargs reused; **omit entirely** for the final Debian card |

Kernel cmdline comes from the DTB `chosen/bootargs` — no other source exists
in this chain. Stock bootargs:
`console=ttyPS0,115200 earlycon earlyprintk initrd=0x3000000,4M modloop=modloop`.
Debian bootargs (M4): `console=ttyPS0,115200 root=/dev/mmcblk0p2 rootfstype=ext4 rw rootwait`.

### BIF template (M4)

```bif
the_ROM_image:
{
  [bootloader] work/stock/fsbl.bin
  [load=0x00100000, startup=0x00100000] work/stock/ssbl.bin
  [load=0x02000000] output/web888-debian.dtb
  [load=0x02008000] output/zImage
  # first-boot-gate card only, removed for the final image:
  # [load=0x03000000] output/initramfs-busybox.cpio.gz
}
```

## 24c64 EEPROM (i2c-0 @ 0x50) — verified contents

Only two non-0xFF regions in the whole 8 KiB:

| region | content |
|--------|---------|
| `0x0010–0x0015` | **factory MAC (`ce:cf:3f:*` prefix; read the full value from `eth0/address` on your unit)** — the persistent MAC seen live |
| `0x1800–0x19ba` | U-Boot environment (CRC32 + key=value, valid) |

The MAC reaches the kernel via DTB: stock dts has `eeprom@50` with an
`nvmem-layout` fixed-layout cell `macaddr@10` (`reg = <0x10 0x06>`,
`compatible = "mac-address"`), referenced by `gem0` via
`nvmem-cells`/`nvmem-cell-names = "mac-address"`. **M4 DTB must replicate this
node pair**; M3 kernel config needs `CONFIG_NVMEM`, `CONFIG_NVMEM_LAYOUTS`
(+ fixed-layout parser) and the default OF EEPROM provider.

The U-Boot env at 0x1800 is a leftover from an older U-Boot-based chain and is
**not consumed** by the current FSBL→stub→kernel chain. It documents factory
metadata: `hw_rev=Web-888.1`, `serial=241000080`, `refclock=24576000`
(Si5351 reference, matches the FSBL I2C setup), `prod_date=04/08/24`,
`hostname=web-888`. Env `ethaddr=02:00:11:22:33:44` is NOT the live MAC.

Full dump archived: `.tmp/stock/eeprom-24c64.bin` (8192 bytes).
