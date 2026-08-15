# Red Pitaya FSBL hooks (read-only, do not edit)

- `red_pitaya_fsbl_hooks.c` and `fsbl.patch` — vendored from
  https://github.com/RaspSDR/red-pitaya-notes.git @ commit
  `da1a7e3a8e715bd0cc47b143b518b05995d5ad9c` ("Add playground project"),
  paths `patches/red_pitaya_fsbl_hooks.c` and `patches/fsbl.patch`,
  fetched 2026-08-15 (see `work/redpitaya-src/`, gitignored).

Purpose: the Web-888 stock FSBL is a Red Pitaya-derived FSBL with board
hooks that (a) program the Si5351 clock generator over I2C0 and (b) read
the per-unit MAC address from the board EEPROM (I2C address 0x50) and
program it into the EMAC0 registers before handoff
(`SetMacAddress()`, called from `FsblHookBeforeHandoff()` via
`fsbl.patch`). Without these hooks the board loses its calibrated clocks
and its EEPROM-derived MAC address.

`fsbl.patch` is a two-hunk context patch against the Xilinx FSBL's
`src/fsbl_hooks.c`: it adds the `u32 SetMacAddress();` prototype and the
`Status = SetMacAddress();` call inside `FsblHookBeforeHandoff()`. It is
applied by `scripts/build-fsbl.sh` to the *working copy* under
`work/fsbl/` — never to the vendored embeddedsw tree.

License: the red-pitaya-notes repository carries no top-level license
file; these two patch files are treated as reference/build inputs under
their upstream project's terms. They do not form part of the GPL-2.0
project code and are not linked into the repository's own sources — they
are only compiled into the FSBL artifact at build time.

Note on xilrsa: the FSBL links `-lrsa`, but upstream
`lib/sw_services/xilrsa` ships only a **prebuilt `librsa.a`** (no C
sources) — do not attempt to build it from source.
