# web888-debian

> **无需新硬件** —— 这是一个 100% 软件项目，在你已有的、原厂出品的
> [Web-888](https://www.rx-888.com/)（Xilinx Zynq-7010，512 MB 内存）SDR
> 接收机上直接运行。板上元件不做任何改动，只替换 TF 卡上的内容。

在 [Web-888](https://www.rx-888.com/) SDR 接收机（Xilinx Zynq-7010，512 MB 内存）上运行
**标准 Debian（trixie，armhf）** —— 用 TF 卡上的常规 Debian 根文件系统、全功能内核，
以及 WebSDR 与 Red Pitaya 的运行时切换，替换原厂「Alpine 全内存运行」固件。

English documentation: [README.md](README.md). **快速开始：**
[`docs/user/flashing.md`](docs/user/flashing.md)。

> **⚠️ 本仓库全部代码均由 AI（Kimi K3）生成 —— 100% vibe coding。**
> 已通过构建与启动测试（QEMU 门禁，多数功能也在硬件上验证过），但在依赖任何
> 关键结论之前，请对照二进制和硬件自行核实。见 `AGENTS.md`。

## 动机

原厂 Web-888 系统内核裁剪严重、整个系统运行在极小的内存 tmpfs 上，且无法与
Red Pitaya 软件栈共存（切换需重新刷卡）。本项目从头重建启动链，让设备运行标准 Debian：

- **Debian 源码 6.12 内核**（主机侧构建的固定版本 deb，`6.12.100-web888`）——
  功能完整：ext4、网络、FPGA devcfg，多数 USB 设备开箱即用；
  linux-xlnx 6.6 链路保留为回滚方案。
- **完整 U-Boot + 源码构建的 FSBL** —— `boot.scr`/`uEnv.txt`/dtb 位于小型 FAT
  固件分区，内核通过根文件系统里的 `/boot/zImage` 以 ext4 方式加载。
- **Debian trixie 根文件系统（ext4）** —— 容量由 TF 卡决定，而非板上 512 MB 内存。
- **WebSDR 与 Red Pitaya 集成在同一镜像**，运行时即可切换。

## 功能

- **从 TF 卡启动 Debian trixie** —— 持久化的 ext4 根文件系统、DHCP + mDNS
  （`web888.local`）、OpenSSH、首次启动自动扩容。
- **小内存 / 闪存友好调优** —— zram swap、log2ram + journald 限额、
  TF 卡 IO 调度器、可调 ondemand cpufreq。
- **SDR 支持** —— 通过 `xilinx_devcfg`（`/dev/xdevcfg`）加载 FPGA，以及全新的
  `zynqsdr` DMA 驱动；实时 ADC 数据已在硬件上验证。
- **WebSDR（同步 KiwiSDR 最新功能）** —— systemd 服务，以专用非 root 用户运行，
  含 GPS（gpsd + chrony）链路；音频与瀑布图端到端可用。原厂 Web-888 软件虽在
  维护但并不活跃，本移植版持续回移（backport）上游 KiwiSDR 的最新功能与缺陷修复。
- **管理界面配置 WiFi** —— Client（STA）与 AP 模式，兼容大多数 USB 网卡。
  板上**没有 USB-A 口**，网卡需通过 Type-C→Type-A 转接器接到数据口。见
  [`docs/user/usage.md`](docs/user/usage.md)。
- **管理界面配置动态域名 + 反向代理** —— No-IP DUC 与 FRP，接通镜像内置服务。
- **Red Pitaya 共存**（`web888-redpitaya`）—— `web888-mode` 在 WebSDR 与 RP 应用
  之间运行时切换，无需重新刷卡。
- **Bootloader 以 deb 形式发布**（`web888-boot`）—— 设备上升级 U-Boot/FSBL
  只需一次 `apt install`。
- **GitHub Releases 上的预构建镜像** —— CI 构建并对完整卡镜像做 QEMU 启动测试，
  无需本地构建。最新镜像：
  `https://github.com/SteamedFish/web888-debian/releases/latest/download/web888-debian-uboot.img.xz`

**日常使用稳定：** 系统已连续运行数周，以上功能均已验证稳定。待办与已知缺陷见
[`docs/dev/`](docs/dev/README.md)。

## 文档

| 对象 | 入口 |
|---|---|
| **用户** | [`docs/user/flashing.md`](docs/user/flashing.md) → [`usage.md`](docs/user/usage.md) → [`quick-reference.md`](docs/user/quick-reference.md) → [`troubleshooting.md`](docs/user/troubleshooting.md) |
| **开发者** | [`docs/dev/`](docs/dev/README.md) —— TODO、KNOWN-ISSUES、CHANGELOG、构建指南、内核 SOP、移植指南 |
| **硬件/协议事实** | [`docs/research/`](docs/research/README.md) —— `hardware-facts.md` 为权威来源 |

## 仓库结构

```
docs/       research/ + dev/ + user/ 文档（入库）
scripts/    构建 / 重打包 / QEMU / 刷机脚本（入库）
config/     内核与 u-boot 配置、设备树、驱动源码（入库）
packaging/  debian 打包：web888-boot、web888-websdr、web888-redpitaya（入库）
resources/  收录的非生成构建输入（入库）
work/       构建目录（不入库）
output/     可刷写产物（不入库）
.tmp/       临时空间（不入库）
```

## 构建

宿主机要求（Arch Linux）：`debootstrap arm-linux-gnueabihf-gcc dtc uboot-tools
qemu-system-arm dosfstools parted cpio rsync`，外加项目内提取的
`qemu-arm-static`（`scripts/env-setup.sh` 会校验）。

```sh
scripts/build-all.sh            # 增量构建，U-Boot 链路
scripts/build-all.sh --clean    # 从零完整复现
scripts/test-qemu.sh uboot      # QEMU 门禁 —— 刷机前必过
scripts/flash-image.sh /dev/sdX output/web888-debian-uboot.img
```

所有可配置项（`KERNEL`、`CHAIN`、镜像源）、回滚链路与手工分步构建流程见
[`docs/dev/building.md`](docs/dev/building.md)。所有非生成的构建输入已收录进
`resources/`，全新 clone 即可直接构建，无需手工拷贝。

刷机、首次启动以及如何在网络中找到设备，请按
[`docs/user/flashing.md`](docs/user/flashing.md) 操作。

## 安全

- 刷机脚本只允许操作可移动 USB 读卡器，拒绝触碰系统盘。
- 原厂 TF 卡保持不动，作为已知可用的回退方案。
- 没有串口：每个镜像先在 QEMU 中启动测试通过后才允许上硬件。

## 许可证

**GPL-2.0-or-later** —— 见 [`LICENSE`](LICENSE)。SPDX 标识符：
`GPL-2.0-or-later`。选择该许可证是为了兼容 `resources/reference/` 下已收录的
GPL-2.0 参考代码及 linux-xlnx 基础内核；第三方参考代码保留其原始上游许可证。
