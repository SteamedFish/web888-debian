# PROVENANCE — resources/qemu-web888

Vendored QEMU model of the Web-888 SDR (Zynq-7010) programmable logic and
board peripherals, plus a bare-metal smoke test for that model.

## Upstream source

- Project: **web888-ng-hw** by **jeskko** — <https://github.com/jeskko/web888-ng-hw>
  (next-generation open tooling for the Web-888 SDR). Many thanks to jeskko
  and the web888-ng contributors for writing and publishing this model; this
  vendored copy exists only to pin a reviewed version inside this repository.
- Pinned version: tag **v0.3.0**, commit
  `767030740a2fdecfebdd383efd23330e6455ff1b`
- Upstream release tarball `web888-ng-hw-v0.3.0.tar.gz`, SHA-256:
  `bec8db7da0fc1a251cbd2c6591d2c74057a10380bf040418a591d8b8300e2709`
  (mirrored in `work/upstream/downloads/`; re-fetched tarballs must match
  this hash).

## Vendored content

Everything under this directory is copied **verbatim** from
`emu/qemu/{patches,files}` and `emu/tests/baremetal` of the pinned tarball —
**no modifications** to the vendored files themselves. Project-specific glue
(build/test scripts) lives outside this directory, in `scripts/`:

- `qemu/patches/0001-web888-machine.patch` — wires the `web888` machine into
  QEMU 11.1.2 (`hw/arm/Kconfig`, `hw/arm/meson.build`, ARM softmmu default
  machines, `default-configs`).
- `qemu/patches/0002-arm-wfe-yield.patch` — `target/arm/tcg/op_helper.c`:
  yield instead of spinning on WFE, needed for the SMP boot in the model.
- `qemu/files/` — the new model sources overlaid onto the QEMU tree:
  - `hw/arm/web888.c`, `include/hw/arm/web888.h` — `web888` machine
    (subclass of `xilinx-zynq-a9`): `web888-pl`, Cadence I2C @0xE0004000
    with 24c64 EEPROM @0x50 + Si5351 stub @0x60, Zynq GPIO @0xE000A000.
  - `hw/misc/web888_pl.c`, `include/hw/misc/web888_pl.h` — PL model:
    CFG/STS/PPS FIFO registers, RX and WF DMA rings with synthetic DDC data.
  - `hw/i2c/cadence_i2c.c`, `include/hw/i2c/cadence_i2c.h`,
    `hw/gpio/zynq_gpio.c`, `include/hw/gpio/zynq_gpio.h` — controller models.
- `tests/baremetal/` — freestanding ARM smoke test (`pltest.c`, `start.S`,
  `link.ld`, `Makefile`) that exercises the PL registers, RX/WF DMA rings and
  the PPS counter, printing `RESULT: PASS` on success.

## Licenses

- QEMU model sources (`qemu/files/`) and the patches: **GPL-2.0-or-later**
  (SPDX headers in each file; compatible with upstream QEMU's GPL-2.0-or-later).
- Bare-metal test (`tests/baremetal/`): **GPL-3.0-or-later** (SPDX headers).
- All files retain their original upstream SPDX/license headers unchanged.

## Modification list (this vendored copy vs. upstream v0.3.0)

None — byte-for-byte copies. The only differences from a raw extraction are:

- the upstream `tests/baremetal/.gitignore` (ignoring `pltest.elf`) was
  dropped; builds happen out-of-tree under `work/qemu-web888/` so no build
  artifacts are ever produced inside `resources/`.
- this PROVENANCE file was added.

## Update procedure

1. Download the new upstream tarball, record its SHA-256 here and in
   `scripts/build-qemu-web888.sh`.
2. Replace `qemu/patches`, `qemu/files`, `tests/baremetal` with the new
   content; refresh the modification list above.
3. Re-run `scripts/build-qemu-web888.sh` (it detects patch-set changes,
   reverts and re-applies) and `scripts/test-zynqsdr-qemu.sh --baremetal-only`.
