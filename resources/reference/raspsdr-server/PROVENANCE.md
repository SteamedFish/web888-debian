# Reference sources (read-only, do not edit)

- `raspsdr-server/ioctl.h`  — github.com/RaspSDR/server @ master, zynq/ioctl.h, blob SHA 6759c21e76e8cc9b065ddea64359789ad066df77 (fetched 2026-07-30). Authoritative /dev/zynqsdr ABI.
- `raspsdr-server/peri.h`   — same repo, zynq/peri.h, blob SHA ec934b7b63b039bff6140042536f39c26a96643b. GPIO bit definitions.
- `raspsdr-server/peri.cpp` — same repo, zynq/peri.cpp, blob SHA 583b8a585c8141054b5e72c85c2a2c18b8ee98b1. Exact userspace call sequences our driver must satisfy.
- `xilinx/xilinx_devcfg.c`  — github.com/Xilinx/linux-xlnx @ tag xilinx-v2016.4, drivers/char/xilinx_devcfg.c, blob SHA 7dc8de7f6cb131bd5fbbf3fb96b581d065a1aa56 (fetched 2026-07-30). Pristine Xilinx source for the /dev/xdevcfg driver removed from the xlnx 6.6 tree.

Licenses: RaspSDR/server is a KiwiSDR fork (mixed GPL/LGPL per-file); xilinx_devcfg.c is GPL v2 (Xilinx copyright 2011-2013). Vendored as read-only reference for writing/porting our own GPL driver code.
