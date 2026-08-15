# Reference sources (read-only, do not edit)

- `embeddedsw-zynq-fsbl/` — trimmed subset of github.com/Xilinx/embeddedsw @
  tag `xilinx_v2023.1`, commit `86f54b77641f325042a1101fead96b2714e6d3ef`
  (tag object `b8dc44c9bf4ade4a81a217e3ab42aecd370d9254`), fetched 2026-08-15
  via `git clone --filter=blob:none` + `git sparse-checkout` (cone mode;
  root-level `README.txt` is a cone-mode artifact of the upstream repo root).
  Vendored to build the Web-888 FSBL from source (replaces the stock binary
  FSBL inside `resources/stock/web888-boot.bin` in a later task).

Trimmed paths (relative to the embeddedsw repo root, layout preserved):

- `lib/sw_apps/zynq_fsbl`               — the FSBL application (incl. `src/Makefile`, honors `BOARD=<name>` and `CC`)
- `lib/bsp/standalone/src`              — standalone BSP (xil_types, xil_printf, xparameters glue, …)
- `lib/sw_services/xilffs/src`          — FatFs service (SD boot image loading)
- `lib/sw_services/xilrsa/src`          — RSA authentication service (referenced by FSBL image auth path)
- `XilinxProcessorIPLib/drivers/{cpu_cortexa9,devcfg,dmaps,emacps,gpiops,iicps,qspips,scugic,scutimer,scuwdt,sdps,ttcps,uartps,usbps,xadcps}/src`
  — PS peripheral drivers the FSBL links against
- `license.txt`                         — upstream license file

License: the FSBL, standalone BSP, xilffs/xilrsa services and the PS drivers
in this subset are distributed by Xilinx under the MIT license (see
`license.txt` and the per-file headers). Vendored read-only reference/build
input; do not modify in-tree — fixes belong in wrappers or demoted warnings
(`CC_FLAGS`), not in vendored sources.

Verification: the vendored tree must always match upstream —
`diff -r` against a sparse checkout of the same tag must be empty
(excluding this `PROVENANCE.md`).

## Smoke test (2026-08-15, host `arm-none-eabi-gcc` 16.1.0, Arch)

`make BOARD=zc702 CC=arm-none-eabi-gcc` in `lib/sw_apps/zynq_fsbl/src`
produces `fsbl.elf` with **zero source changes and no warning demotions**:
text 94,961 / data 12,540 / bss 76,604 bytes (total 184,105 — under the
200 KB sanity bound). Only benign warnings: `-Wunused-but-set-variable`
in `xemacps_bdring.c:181` and `xusbps_intr.c:314`, plus the modern-binutils
note `fsbl.elf has a LOAD segment with RWX permissions`.

Host-environment accommodations (build-script concerns, NOT vendored-tree
changes — consumers such as Tasks 3–4 must replicate these):

- Arch splits the C library out of gcc: the `arm-none-eabi-gcc` package
  alone has no `stdint.h`/`libc.a` (they live in the separate
  `arm-none-eabi-newlib` package). If the system package is absent, extract
  the Arch package project-locally (smoke test used
  `arm-none-eabi-newlib-4.6.0.20260123-1-any.pkg.tar.zst` under `.tmp/newlib/`)
  and inject it without touching this tree:
  - compile: `CPATH=<repo>/.tmp/newlib/usr/arm-none-eabi/include`
  - link: `LINKER="arm-none-eabi-gcc --sysroot=<repo>/.tmp/newlib/usr/arm-none-eabi"`
    as a make command-line override. Note: the environment `LIBRARY_PATH`
    is silently ignored by this sysrooted cross-gcc (entries get
    sysroot-prefixed) — `--sysroot` is the reliable mechanism.
- Force serial make (`make -j1`, or unset the host's `MAKEFLAGS=-jN`):
  the 2020-era Xilinx Makefiles have no dependency edge between the BSP
  header-copy step and the FSBL app objects, so a parallel make races and
  dies with `fatal error: xil_io.h: No such file or directory`.
- `make clean` afterwards restores the pristine tree (the `diff -r`
  verification above must stay empty).
