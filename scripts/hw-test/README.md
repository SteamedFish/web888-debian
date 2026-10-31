# hw-test — hardware test tools for the zynqsdr/xdevcfg drivers

Host-built, statically linked ARM binaries, uploaded to the device and run over SSH.
Used by the Step-2 hardware gates (see `scripts/hw-gate-step2.sh` and `docs/dev/TODO.md`).

## Tools

| Tool | Source | Purpose |
|------|--------|---------|
| `zynqsdr-smoke.c` | project-original | Full ABI gate: all 15 ioctls, GPIO/DSA bit-bang, RX/WF arm + reads, PPS, rmmod-EBUSY, 400 concurrent reads, 50x arm/disarm stress, the real web888-ng `GET_STATS` extension (0x80405a20) refused as ENOTTY/EINVAL. Prints `ZYNQSDR_SMOKE_OK` on full pass. |
| `zynqsdr-rearm-test.c` | project-original | S1 regression: RX_START/WF_START must re-sync the consumer offset to the ring head on every re-arm (QEMU model assertions deterministic; hardware run relaxes to the `readed>=0` contract). Prints `ZYNQSDR_REARM_OK`. |
| `zynqsdr-datapath.c` | project-original | Model-only data-path validation: 96-byte RX frame/sample assertions (endianness/interleave/I-Q-swap detection without libm), RX_READ length 0/1/96/127 contract + tail sentinels, 0x7fc00 ring-wrap continuity, WF continuous vs one-shot semantics, WF_PARAM decimate-change reset pulse, interleaved RX+WF0+WF1, RX_PARAM retune-while-armed. **QEMU web888-pl model only — refuses hardware.** Prints `ZYNQSDR_DATAPATH_OK`. |
| `sigdump.c` | project-original | GET_SIGNATURE + GET_DNA + GPIO mask dump (quick PL-alive check). |
| `pldump.c` | project-original | Raw `/dev/mem` dump of config 0x40000000 / status 0x41000000 (cross-check driver vs raw PL). |
| `mmap-test.c` | project-original | Per-region `/dev/mem` mmap probe (0x40000000/0x41000000/0x42000000) — diagnoses STRICT_DEVMEM/IO_STRICT_DEVMEM blocks vs the RP apps' raw-mmap needs. Build like `pldump`. |
| `ws-e2e.py` | project-original | Host-side websdr websocket E2E (no deps): handshakes `/kiwi/<ts>/SND` + `/W/F`, waits for `audio_init`, sends full client setup incl. `SET AR OK` and 5 s keepalives, asserts real audio + waterfall binary frames. Prints `E2E_OK`. |
| `hw-roundtrip.sh` | project-original | RP-coexistence gate (TODO P4.5): 10x `web888-mode` round-trips websdr↔RF-active RP app with :8073 recovery polls, reboot-default check, 1 h soak, final `ws-e2e.py`. Prints `ROUNDTRIP_OK`. |
| `hw-reboot-loop.sh` | project-original | WebSDR deeper gate: reboot ×3 verifying websdr self-heals as the web888 user each boot, then a multi-hour soak (default 2 h, `SOAK_CHECKS` override) with journal error scans, final `ws-e2e.py`. Prints `REBOOTLOOP_OK`. |
| `si5351/` | see provenance | `si5351-init`: stock userspace clock setup (Si5351 @0x60 on /dev/i2c-0, ref 24.576 MHz, CLK0 = 66.6666 MHz ADC clock, 8 mA). Required before the PL RX engine produces data. websdr.bin does this itself — this tool is for driver-level testing without websdr. |
| `hw-probe.c` / `hw-probe.py` | project-original | Read-only hardware state dump (every register group via /dev/mem + i2c) for stock-vs-Debian golden-reference diffing; run on the device via `scripts/capture-hw-state.sh`. `hw-probe.armhf` is the committed prebuilt static binary. |

Host-side gates (`ws-e2e.py`, `hw-roundtrip.sh`, `hw-reboot-loop.sh`) drive a
live device over SSH (`sshpass`, password `changeme`); default target
`DEVICE=web888.local`, override via the environment. They reboot the device —
never run two gates concurrently. Logs land in `.tmp/` (gitignored).

## Provenance

`si5351/si5351.cpp`, `si5351/si5351.h`, `si5351/i2c.cpp`, `si5351/i2c.h`,
`si5351/I2CInterface.h`, `si5351/LinuxInterface.h` are verbatim copies from
`RaspSDR/server` @ master (`si5351/` + interface headers).
`si5351/main.cpp` is project-original. See also `resources/reference/raspsdr-server/PROVENANCE.md`.

## Build (on the build host)

The Arch `arm-linux-gnueabihf` spec file injects `-latomic_asneeded`, which does
not exist — `libatomic_asneeded.a` here is an empty stub archive satisfying the
linker. Recreate if lost:

```sh
cd scripts/hw-test
echo 'int main(){return 0;}' | arm-linux-gnueabihf-gcc -x c -c -o stub.o - \
  && ar rcs libatomic_asneeded.a stub.o && rm stub.o
```

Build all:

```sh
cd scripts/hw-test
arm-linux-gnueabihf-gcc -static -O2 -L. -o zynqsdr-smoke zynqsdr-smoke.c
arm-linux-gnueabihf-gcc -static -O2 -L. -o zynqsdr-rearm zynqsdr-rearm-test.c
arm-linux-gnueabihf-gcc -static -O2 -L. -o zynqsdr-datapath zynqsdr-datapath.c
arm-linux-gnueabihf-gcc -static -O2 -L. -o sigdump sigdump.c
arm-linux-gnueabihf-gcc -static -O2 -L. -o pldump pldump.c
arm-linux-gnueabihf-g++ -static -O2 -L. -o si5351-init si5351/main.cpp si5351/si5351.cpp si5351/i2c.cpp
```

## QEMU web888-pl model lane

`scripts/test-zynqsdr-qemu.sh` builds fresh host + armhf copies of
`zynqsdr-smoke`, `zynqsdr-rearm` and `zynqsdr-datapath` into
`work/qemu-web888/tools/` and runs each inside the QEMU guest via
`TOOL --emu HOST SSH_PORT` (the host binary uploads its adjacent `.armhf`
payload over ssh and relays output/exit status; `ZYNQSDR_*` env vars can
override the tool paths). `zynqsdr-datapath` is **model-only**: it verifies
its expectations against the web888-pl signature and exits non-zero on real
hardware.

## Run (on the device)

Prerequisites: kernel with `xilinx_devcfg` + `zynqsdr` modules (auto-loaded via
udev coldplug), and the FPGA bitstream loaded:

```sh
# upload (use cat pipes; works with any sshd)
ssh -p22 root@DEVICE 'cat > /tmp/websdr_hf.bit' < resources/stock-card/websdr_hf.bit
ssh -p22 root@DEVICE 'cat > /root/zynqsdr-smoke && chmod +x /root/zynqsdr-smoke' < zynqsdr-smoke
ssh -p22 root@DEVICE 'cat > /root/si5351-init && chmod +x /root/si5351-init' < si5351-init

# on device: bitstream FIRST (blank PL + PL MMIO = AXI stall, see port-notes §11)
ssh -p22 root@DEVICE 'cat /tmp/websdr_hf.bit > /dev/xdevcfg \
  && cat /sys/devices/soc0/axi/f8007000.devcfg/prog_done'   # expect 1
ssh -p22 root@DEVICE '/root/si5351-init'                    # ADC clock up
ssh -p22 root@DEVICE '/root/zynqsdr-smoke hw'               # expect ZYNQSDR_SMOKE_OK
```

`hw` arg switches assertions from QEMU (PL returns zeros) to real hardware
(signature `0xaa55020c` → 12 RX + 2 WF channels, non-zero DNA, real ADC samples).
