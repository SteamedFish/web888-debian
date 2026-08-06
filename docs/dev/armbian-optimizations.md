# Armbian optimization mechanisms for ARM/SBC devices — research notes

> **Document type**: external research material (sources: Armbian official docs
> repo `armbian/documentation` and build repo `armbian/build`, main branches,
> retrieved at time of research). These are NOT facts about our hardware; where
> this document conflicts with `../research/hardware-facts.md`, the latter wins.
> All paths below are **runtime paths inside an Armbian image**; the
> corresponding build-repo source path is noted in parentheses.
>
> **Research goal**: the Web-888 is a 512 MB RAM ARM device with its rootfs on
> a TF card. Armbian's optimization themes (small memory + protecting flash
> media) are directly transferable. This document only describes "what Armbian
> does and how" — it does not include any adoption plan for this project.

---

## 1. Overview

The Armbian official documentation (`docs/index.md`, section "Other features
and performance tweaks") lists these optimization features:

| Optimization | Mechanism |
|---|---|
| Memory compression | Half of physical RAM used as **zram** compressed swap |
| Log media protection | `/var/log` mounted as a compressed zram partition (`log2ram`), synced to disk daily and on shutdown |
| /tmp media protection | `/tmp` mounted as tmpfs (optionally compressed further) |
| Media-friendly I/O | Tuned IO scheduler; ext4 journal data writeback enabled |
| Interrupt affinity | Ethernet interrupts pinned to a dedicated CPU core (RPS/smp_affinity) |
| Image layer | Highly compressed image; rootfs auto-expands on first boot |
| Desktop layer | Browser profile memory cache enabled on desktop images |

The sections below break down each implementation by topic.

---

## 2. Small-memory optimization: zram compressed swap (core)

### 2.1 What it is

Armbian **by default** uses zram to turn part of physical RAM into a
compressed block device used as swap — no flash writes, purely in-RAM
compression. By default it exposes **50%** of physical RAM as swap.

Runtime script: `/usr/lib/armbian/armbian-zram-config`
(source: `packages/bsp/common/usr/lib/armbian/armbian-zram-config`),
started by the systemd unit `armbian-zram-config.service`.
Config: `/etc/default/armbian-zram-config`
(source: `packages/bsp/common/etc/default/armbian-zram-config.dpkg-dist`)

### 2.2 Workflow (`activate_zram` + `activate_zram_swap`)

1. **Probe the module**: exit if `modinfo zram` fails; also exit if a
   third-party `zram-config` package is installed.
2. **Device count**:
   - 3.x kernels: `ZRAM_MAX_DEVICES` (default 4);
   - newer kernels: `zram_max_devs=1`, relying on `max_comp_streams` set to
     the CPU core count (capped at 4).
   - Actually creates `min(cpu_cores, max_devs) + 2` devices (swap + ramlog +
     tmp reserved).
3. **Per-device capacity**: `mem_per_zram_device = memory_total × ZRAM_PERCENTAGE / devs / 100`
   (default `ZRAM_PERCENTAGE=50`, i.e. total swap capacity = 50% of RAM).
4. **Memory limit**: `mem_limit_per_zram_device = memory_total × MEM_LIMIT_PERCENTAGE / devs / 100`
   (default `MEM_LIMIT_PERCENTAGE=50` — the zram device itself may consume at
   most 50% of RAM, preventing swap from blowing up memory).
5. **Compression algorithm**: default `SWAP_ALGORITHM=lzo` (the config comment
   states explicitly: **lzo is the best choice on ARM**; auto-switches to
   `lzo-rle` if the kernel supports it — see the zram Linux 5.1 optimization).
6. **Create swap**: `mkswap` + `swapon -p ${SWAP_PRIORITY:=5}` (zram priority
   is higher than disk swap).
7. **Disable zswap**: if the kernel has zswap, write `0` to
   `/sys/module/zswap/parameters/enabled` — zram and zswap are mutually
   exclusive.
8. **Flash-friendly**: `echo 0 > /proc/sys/vm/page-cluster` (disables
   page-cluster readahead on swap-in, which is more efficient for compressed
   swap).
9. **Cap logging**: `journald.conf` gets `SystemMaxUse=20M`.

### 2.3 Config key reference (`/etc/default/armbian-zram-config`)

| Key | Default | Meaning |
|---|---|---|
| `ENABLED` | `true` | Master switch for the whole service |
| `SWAP` | `true` (commented form) | `SWAP=false` disables zram swap (use zswap/disk swap instead) |
| `ZRAM_PERCENTAGE` | `50` | Swap capacity as a percentage of physical RAM (can over-commit beyond 300% if `MEM_LIMIT_PERCENTAGE` is adjusted in sync) |
| `MEM_LIMIT_PERCENTAGE` | `50` | Upper bound on RAM the zram device may occupy |
| `ZRAM_MAX_DEVICES` | `4` | Maximum number of swap devices |
| `SWAP_ALGORITHM` | `lzo` | Swap compression algorithm (lzo/lzo-rle preferred on ARM) |
| `SWAP_PRIORITY` | `5` | zram swap priority |
| `RAMLOG_ALGORITHM` | `zstd` | ramlog partition compression algorithm (see §3) |
| `TMP_ALGORITHM` | `zstd` | Algorithm for compressed /tmp (see §4) |
| `TMP_SIZE` | `RAM/2` | Compressed /tmp size |
| `ZRAM_BACKING_DEV` | empty | Optional zram backing device (`CONFIG_ZRAM_WRITEBACK`) |

### 2.4 zswap: when to switch

Official docs `User-Guide_Advanced-Configuration.md`, "Swap for experts":

> By default Armbian uses ZRAM (no disk writes, pages compressed in RAM). If
> you hit OOM frequently and have reliable storage (NVMe/SATA SSD), you can
> use ZSWAP instead: confirm kernel support (`dmesg | grep zswap`), create a
> swapfile/swap partition the traditional way, then set `SWAP=false` in
> `armbian-zram-config` and reboot. **Zswap performs significantly better
> than zram + disk swap combined.**

zswap is a compressed write-back cache (the backing disk swap still exists),
suited to machines with an SSD; zram is entirely in-RAM, suited to diskless
or extremely flash-constrained setups.

---

## 3. Protecting the TF/SD card: move logs and frequently-written data to RAM (ramlog / log2ram)

### 3.1 What it is

`armbian-ramlog` mounts all of `/var/log` onto a **compressed zram
partition** (label `log2ram`) or a **tmpfs**, so every log write lands in
RAM. A daily cron job and a systemd stop hook rsync it back to
`/var/log.hdd` on flash.

Runtime script: `/usr/lib/armbian/armbian-ramlog`
(source: `packages/bsp/common/usr/lib/armbian/armbian-ramlog`)
Config: `/etc/default/armbian-ramlog`
(source: `packages/bsp/common/etc/default/armbian-ramlog.dpkg-dist`)

### 3.2 Workflow

**start**:
1. `HDD_LOG=/var/log.hdd`; first create a disk-side copy mountpoint with
   `mount --bind /var/log /var/log.hdd`.
2. Scan `/dev/zram*`: find the zram device labelled `log2ram` (created by
   `activate_ramlog_partition()` in the §2 script; ext4 formatted with
   `-O ^has_journal`, default size 50M, algorithm auto-selected as the
   fastest available of lz4 → lz4hc → zstd) → mount it; otherwise fall back
   to tmpfs (`size=$SIZE`, default 50M).
3. `syncFromDisk`: rsync the old logs from flash back into RAM with
   `rsync -aXWv --delete` (excluding rotated archives `*.gz`/`*.xz`/`*.[0-9]`
   and `journal*`).
4. Recreate key log directories (apache2/nginx/samba etc., so services don't
   fail to start over missing directories).

**stop / write**:
1. `syncToDisk`: `rsync -aXWv` writes the in-RAM logs back to `/var/log.hdd`
   (excluding `lost+found`, `armbian-ramlog.log`, `journal*`).
2. journald handling: if `/var/log/journal` exists and is not a symlink, stop
   journald, `mv` the directory to the disk side, then symlink it back; if
   `journald.conf` lacks `Storage=volatile`, run `journalctl --flush` (write
   to disk) followed by `--relinquish-var` (return to volatile in-RAM
   logging).
3. `sync /` forces everything to disk.

**Auxiliary pieces**:
- `cron.daily/armbian-ram-logging`: runs `armbian-ramlog write` daily for
  periodic disk sync.
- `armbian-truncate-logs` (`/usr/lib/armbian/armbian-truncate-logs`):
  when log usage exceeds 75% — `armbian-ramlog write` → forced logrotate →
  `truncate --size 0` on various logs → delete rotated archives →
  `journalctl --vacuum-size=5M`.
- `prepare_board()` (see §6) rewrites paths in `/etc/logrotate.d/*` and
  `logrotate.conf` to `/var/log.hdd/` via `sed` when `/var/log` is on
  zram/tmpfs, and forces `compress` on in logrotate.
- `systemd-journald.service.d/override.conf` (source path) contains a single
  line `After=armbian-ramlog.service`, ensuring journald starts after the
  ramlog mount.

### 3.3 Config key reference (`/etc/default/armbian-ramlog`)

| Key | Default | Meaning |
|---|---|---|
| `ENABLED` | `true` | Master switch |
| `SIZE` | `50M` | /var/log size in tmpfs mode (must match the zram-side 50M) |
| `USE_RSYNC` | `true` | rsync-based sync (incremental, good performance) |
| `HDD_LOG` | `/var/log.hdd` | Disk-side long-term log storage (can be moved to NVMe etc.) |
| `XTRA_RSYNC_TO/FROM` | `()` | Extra rsync arguments |

### 3.4 Uncompressed alternative: plain tmpfs

On low-end images without a `log2ram` zram partition, ramlog simply falls
back to `mount -t tmpfs -o nosuid,noexec,nodev,mode=0755,size=$SIZE` —
still zero flash writes.

---

## 4. Protecting the TF/SD card: compressed /tmp and mount options

### 4.1 Compressed /tmp (zram)

`activate_compressed_tmp()`: if `/etc/mtab` has no existing `/tmp` mount,
take another zram device, `mkfs.ext4 -O ^has_journal` (no journal),
`mount -o nosuid,discard` it on `/tmp`, `chmod 1777`. Default
`TMP_SIZE=RAM/2`; the algorithm defaults to the swap's `lzo` and can be
overridden with `TMP_ALGORITHM=zstd` (the shipped config defaults to zstd in
commented form).

### 4.2 fstab mount options

Box-class template (`config/optional/boards/aml-s9xx-box/_packages/bsp-cli/root/fstab.template`):

```
/dev/root  /      ext4  defaults,noatime,errors=remount-ro  0 1
tmpfs      /tmp   tmpfs defaults,nosuid                      0 0
```

Key points:
- rootfs uses **`noatime`** (avoids atime writes).
- `/tmp` on **tmpfs** (RAM), `nosuid`.
- The **"Journal data writeback is enabled (/etc/fstab)"** mentioned in the
  official index.md refers to the ext4 `data=writeback` mount option (only
  metadata is journaled, not data — reduces write amplification).
- At build time `install_distribution_agnostic()` appends placeholder entries
  like `/dev/mmcblk0p1 / ... defaults 0 1` to `/etc/fstab` to satisfy the
  initramfs.

---

## 5. Small-memory specific: the lowmem extension (<256 MB devices)

Source: `extensions/lowmem.sh` + `packages/bsp/armbian-lowmem/`
(targets devices under 256 MB; the Web-888's 512 MB is borderline, but the
approach is still worth knowing):

1. **Initramfs slimming** (`/etc/initramfs-tools/conf.d/armbian-lowmem.conf`):
   - `MODULES=dep` (only boot-essential modules, not all).
   - `RUNSIZE=20M`: /run defaults to 10% of RAM, and systemd daemon-reload
     errors out below 16 MB, so it is pinned at 20M.
2. **Swapfile fallback** (`lowmem-mkswap.service`):
   `/swapfile` of 256 MiB, created with `fallocate`, `mkswap`, fstab entry
   `defaults,nofail,discard=once,pri=0`, `swapon -p 0` (lower priority than
   zram's 5). A safety net for memory-hungry operations like apt/locale-gen.
3. **Memory-saving defaults**: at build time set `armbian-ramlog`
   `ENABLED=false` and `armbian-zram-config` `SWAP=false` (saves the zram
   device overhead + one log partition).

**Complete example for a 256 MB board**: `config/boards/beaglebadge.conf`
(BeagleBadge, 256 MB, lowmem extension) additionally does at build time:
- zram overrides: `SWAP_ALGORITHM=zstd`, `SWAP_PRIORITY=100` (zram swap
  preferred).
- journald caps: `SystemMaxFileSize=4M`, `RuntimeMaxUse=8M`,
  `RuntimeMaxFileSize=2M`, `ForwardToSyslog=no`, `ForwardToConsole=no`,
  `ForwardToWall=no`, `Compress=yes`.
- systemd timeout tightening: `DefaultTimeoutStopSec=30s`,
  `DefaultDeviceTimeoutSec=30s`, `DefaultLimitNOFILE=1024:4096`; coredump
  `MaxUse=128M`.
- Kernel sysctls (`/etc/sysctl.d/99-beaglebadge.conf`):
  `vm.swappiness=100`, `vm.page-cluster=0`, `vm.watermark_scale_factor=125`,
  `vm.compact_memory=1`, `vm.vfs_cache_pressure=150`,
  `vm.dirty_background_ratio=5`, `vm.dirty_ratio=10`, `vm.min_free_kbytes=8192`,
  `vm.overcommit_memory=1`; minimized network buffers
  (`net.core.rmem_max=131072` etc.).
- Disabled services: `rsyslog`, `systemd-homed`,
  `armbian-hardware-monitor/optimize`, apt timers, `e2scrub_all.timer`.
- Boot argument `zswap.enabled=0` appended (avoids conflict with zram).

> Note the `vm.swappiness=100` value: with zram swap Armbian actually prefers
> HIGH swappiness (compressed swap is cheap — swap out aggressively to free
> anonymous pages); the conventional LOW swappiness advice applies to **disk
> swap**. The two are not contradictory — it depends on the swap medium.

---

## 6. CPU frequency, IO scheduler and IRQ affinity (armbian-hardware-optimization)

Runtime script: `/usr/lib/armbian/armbian-hardware-optimization`
(source: `packages/bsp/common/usr/lib/armbian/armbian-hardware-optimization`),
started by `armbian-hardware-optimize.service`.

### 6.1 IO scheduler (`set_io_scheduler`)

Selected per block device `queue/rotational`:
- Rotational disks (rotational=1): kernel ≥4.20 → `bfq`, otherwise `cfq`.
- **Flash (rotational=0, including TF cards)**: ≥4.20 → **`none`** (noop is
  no longer needed in the mq-deadline era), otherwise `noop`. zram devices
  are skipped.

### 6.2 cpufreq governor (inside `prepare_board`)

- Reads `/etc/default/cpufrequtils` (generated at build time by
  `distro-agnostic.sh`: `ENABLE=false`, `MIN_SPEED=$CPUMIN`,
  `MAX_SPEED=$CPUMAX`, `GOVERNOR=$GOVERNOR`; the governor comes from board
  config, typically `ondemand` or `performance`).
- Writes `GOVERNOR`, `MIN_SPEED`, `MAX_SPEED` to every `cpufreq/policy*`.
- **ondemand tuning** (if the governor is ondemand):
  `io_is_busy=1` (ramp up during IO too), `up_threshold=25` (more aggressive
  upscaling), `sampling_down_factor=10`, `sampling_rate=200000` — makes SBCs
  more responsive under IO load.
- `chmod +r .../cpuinfo_cur_freq`: lets unprivileged users read the current
  frequency (used by armbianmonitor).

### 6.3 IRQ affinity / RPS (board-family case table)

Pins key interrupts to specific cores per BOARDFAMILY/BOARD:
- Example (rk3399): GPU/MMC/USB → cpu0/cpu1, `xhci` → cpu2, **eth0 → cpu3**,
  `rps_cpus=7` (RPS aggregates packet reception across cores),
  `rps_sock_flow_entries=32768`.
- sun8i/sun50i/mvebu etc. each have their own mapping. Core idea: **isolate
  NIC/storage interrupts on dedicated cores** to reduce inter-core
  interference and improve determinism.

---

## 7. Power optimization (h3consumption, H3-era tool)

Source: `packages/bsp/h3consumption` (only works on legacy H3 kernels, but
the ideas are generic). Controls fex/script.bin + `/etc/rc.local` +
cpufrequtils:

| Measure | Measured savings |
|---|---|
| Disable GPU/HDMI on headless devices (`-g off`) | 210 mW (also raises memory bandwidth, slight perf gain) |
| Downgrade GbE to 100M negotiation (`-e fast`) | 370 mW |
| Disable Ethernet (`-e off`) | 200 mW |
| Cap max cpufreq (`-m`, e.g. 912 MHz to avoid a VDD_CPU voltage step) | Large peak-power reduction |
| Limit active cores (`-c 1..3`) | Large peak-power reduction |
| Downclock DRAM to 408 MHz (`-d`) | 150 mW |
| Disable USB (`-u off`) | 125 mW |
| WiFi power management (`-w off`) | 300–1000 mW depending on chip |

---

## 8. Other build-time work (rootfs layer)

Source: `lib/functions/rootfs/distro-agnostic.sh` (`install_distribution_agnostic`):

- Generates `/etc/default/cpufrequtils` (see §6.2).
- Generates `/etc/modules` and modprobe blacklists (board-trimmed kernel
  modules).
- Defaults to `SELINUX=disabled`; disables NMBD (samba NetBIOS, hangs boot
  without a network).
- Unlocks `kernel.printk`-related log config; trims redundant rsyslog rules.
- Serial console: enables `serial-getty@` per `SERIALCON` (with baud
  override).
- On non-ext4 rootfs, `touch /var/swap` to block swap-file creation (swap is
  unusable on f2fs/btrfs).
- Service manifest (enabled by default, relevant ones):
  `armbian-zram-config.service`, `armbian-ramlog.service`,
  `armbian-hardware-optimize.service`, `armbian-resize-filesystem.service`
  (first-boot partition expansion), `armbian-hardware-monitor.service`,
  `armbian-led-state.service`.
- Image layer: the rootfs is packed compressed and **auto-resized to fill
  the card on first boot**.

### armbianEnv.txt (u-boot environment, zynq board example)

`config/bootenv/zynq.txt`:

```
verbosity=1
bootlogo=false
fpga_bin=system_wrapper.bin
```

Switches like `console=serial|display|none` also live in `armbianEnv.txt`
(docs `User-Guide_Advanced-Configuration.md`). Low verbosity noticeably
speeds up boot output.

---

## 9. Summary table: goal → mechanism → key values

| Goal | Mechanism | Key values/files |
|---|---|---|
| Small memory | zram swap (on by default) | 50% RAM, lzo/lzo-rle, pri=5, `page-cluster=0`, zswap disabled |
| Small memory | Disk swapfile fallback (lowmem) | `/swapfile` 256M, pri=0, nofail |
| Small memory | sysctl tuning | swappiness=100, vfs_cache_pressure=150, dirty 5/10, min_free_kbytes=8M |
| Small memory | journald caps | SystemMaxUse=20M (zram side) / RuntimeMaxUse=8M (lowmem side) |
| Small memory | initramfs slimming | `MODULES=dep`, `RUNSIZE=20M` |
| Protect TF card | Logs in RAM | ramlog + log2ram zram/tmpfs 50M, daily + shutdown rsync to disk |
| Protect TF card | Compressed /tmp | zram ext4 without journal, RAM/2, zstd |
| Protect TF card | fstab options | `noatime`, `data=writeback`, /tmp tmpfs |
| Protect TF card | Log rotation paths | logrotate → /var/log.hdd/, forced compress, 75% threshold truncation |
| Performance | IO scheduler | flash → `none`, rotational → `bfq` |
| Performance | cpufreq | ondemand tuning: up_threshold=25, io_is_busy=1 |
| Performance | IRQ affinity/RPS | NIC/storage interrupts pinned to dedicated cores, rps_cpus=7 |
| Power | Disable peripherals/downclock | GPU/HDMI 210mW, GbE→100M 370mW, DRAM downclock 150mW |
| Boot | First-boot expansion | rootfs auto-resize; low verbosity; serial console |

---

## 10. References

- Armbian documentation repo `armbian/documentation` (main):
  - `docs/index.md` (feature list)
  - `docs/User-Guide_Advanced-Configuration.md` (zswap/zram "Swap for
    experts", cpufrequtils, armbianEnv.txt, verbosity)
- Armbian build repo `armbian/build` (main):
  - `packages/bsp/common/usr/lib/armbian/armbian-zram-config`
  - `packages/bsp/common/etc/default/armbian-zram-config.dpkg-dist`
  - `packages/bsp/common/usr/lib/armbian/armbian-ramlog`
  - `packages/bsp/common/etc/default/armbian-ramlog.dpkg-dist`
  - `packages/bsp/common/usr/lib/armbian/armbian-truncate-logs`
  - `packages/bsp/common/usr/lib/armbian/armbian-hardware-optimization`
  - `packages/bsp/common/etc/cron.daily/armbian-ram-logging`
  - `packages/bsp/common/lib/systemd/system/systemd-journald.service.d/override.conf`
  - `packages/bsp/armbian-lowmem/` (lowmem-mkswap.sh etc.)
  - `extensions/lowmem.sh`
  - `lib/functions/rootfs/distro-agnostic.sh`
  - `config/boards/beaglebadge.conf` (complete 256 MB optimization example)
  - `config/bootenv/zynq.txt`
  - `packages/bsp/h3consumption` (power tool)
  - `config/optional/boards/aml-s9xx-box/_packages/bsp-cli/root/fstab.template`
