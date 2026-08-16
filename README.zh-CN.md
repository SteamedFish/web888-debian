# web888-debian

> **无需新硬件** —— 这是一个 100% 软件项目，在你已有的、原厂出品的
> [Web-888](https://www.rx-888.com/)（Xilinx Zynq-7010，512 MB 内存）SDR
> 接收机上直接运行。板上元件不做任何改动，只替换 TF 卡上的内容。

在 [Web-888](https://www.rx-888.com/) SDR 接收机（Xilinx Zynq-7010，512 MB 内存）上运行
**标准 Debian（trixie，armhf）** —— 用 TF 卡上的常规 Debian 根文件系统、全功能内核，
以及 WebSDR 与 Red Pitaya 应用的运行时切换，替换原厂"Alpine 全内存运行"固件。

English documentation: [README.md](README.md).

> **⚠️ 本仓库全部代码均由 AI（Kimi K3）生成 —— 100% vibe coding。**
> 所有内容都经过构建与启动测试（QEMU 门禁，多数功能也在硬件上验证过），但在依赖任何
> 关键结论之前，请对照二进制和硬件自行核实。见 `AGENTS.md`。

## 亮点

- 全功能 Debian 内核，使用 Debian 默认内核配置与固件 —— 大多数 Wi‑Fi 网卡开箱即用。
- 根分区（/）位于 ext4 TF 卡上而非全部在内存中。其容量由你的 TF 卡决定，而不是板上
  512 MB 内存，因此可以放心安装应用而无需担心空间不足。
- 从 KiwiSDR 精心回移的最新功能与缺陷修复。
- 针对低内存、TF 卡设备的调优与优化，包括 zram、log2ram 等。
- WebSDR 以专用非 root 用户身份运行，并由 systemd 管理，安全性更佳。
- WebSDR 与 Red Pitaya 应用同时集成在同一镜像中 —— 无需重新刷写固件即可切换。

## 动机

原厂 Web-888 系统内核功能裁剪严重、整个系统运行在内存 tmpfs 中（可写空间极小），
且无法与 Red Pitaya 软件栈共存（切换需重新刷卡）。本项目从头重建启动链：

- **Debian 源码 6.12 内核**（主机侧构建的固定版本 deb，`6.12.100-web888`，
  Debian armmp 基线 + Web-888 驱动），功能完整（ext4、网络、FPGA devcfg 等）；
  linux-xlnx 6.6 链路保留为回滚方案
- **完整 U-Boot v2026.07** 作为 SSBL（位于**源码构建的 FSBL** 之后，
  该 FSBL 由 vendored Xilinx embeddedsw zynq_fsbl + RaspSDR hooks 构建，
  ps7_init 提取自原厂二进制并逐字节验证；`FSBL=stock` 保留为回退开关）
  ——内核/DTB 通过 boot.scr/uEnv.txt 从 FAT 分区加载
- **Debian trixie 根文件系统**（debootstrap 构建），放在 ext4 分区
- 每次刷硬件前必须先过 QEMU 启动测试（没有串口可用）

## 目前已实现的功能

- **从 TF 卡启动 Debian trixie** —— debootstrap 构建的 ext4 根文件系统、
  重打包 boot.bin（源码构建的 FSBL + bootgen）、busybox initramfs switch_root、
  DHCP + mDNS（`web888.local`）、OpenSSH、首次启动自动扩容
- **小内存 / 闪存友好调优** —— zram swap（lzo-rle）、log2ram + journald 限额、
  TF 卡 IO 调度器 `none`、可调 ondemand cpufreq
- **SDR 驱动** —— `xilinx_devcfg` 前向移植（`/dev/xdevcfg` FPGA 加载）与全新
  `zynqsdr` 驱动（完整 15 个 ioctl ABI、总线主 DMA 数据面）；硬件上已验证实时
  ADC 数据
- **Debian 上的 WebSDR**（`web888-websdr` deb）—— systemd 服务、gpsd+chrony
  GPS 链路，音频 + 瀑布图端到端硬件验证；已与上游 KiwiSDR v1.902 对齐
  （46 个 cherry-pick + mongoose 7.14 升级 + 管理界面再同步）
- **Red Pitaya 共存**（`web888-redpitaya` deb）—— 收录比特流 + 源码构建的应用，
  `web888-mode` 在 WebSDR 与 RP 应用之间运行时切换，无需重新刷卡
- **6.12 内核 + 完整 U-Boot 链路** —— QEMU 门禁已通过；硬件浸泡测试事项见
  `docs/dev/TODO.md`
- **Bootloader 以 deb 形式发布**（`web888-boot`）—— FSBL + U-Boot +
  boot.scr/uEnv.txt payload 随镜像预置；设备上升级只需一次 `apt install`
  （postinst 带一次性 `.bak` 备份与 sync-word 校验写入 vfat /boot，不触碰
  uEnv.txt）
- **CI 构建的 APT 仓库** —— GitHub Actions 在相关源码变更的推送时构建全部
  deb（内核、WebSDR、Red Pitaya、web888-boot，以及 dumphfdl / noip-duc /
  frpc），将签名后的扁平仓库发布到 GitHub Pages；每日 cron 检查上游发布并
  重新构建第三方软件包。配置与 sources.list 见
  [`docs/dev/github-ci-apt-repo.md`](docs/dev/github-ci-apt-repo.md)

当前工作项：[`docs/dev/TODO.md`](docs/dev/TODO.md) ·
已知缺陷：[`docs/dev/KNOWN-ISSUES.md`](docs/dev/KNOWN-ISSUES.md) ·
变更历史：[`docs/dev/CHANGELOG.md`](docs/dev/CHANGELOG.md)

## 文档

| 对象 | 入口 |
|---|---|
| **用户** | [`docs/user/flashing.md`](docs/user/flashing.md) → [`usage.md`](docs/user/usage.md) → [`quick-reference.md`](docs/user/quick-reference.md) → [`troubleshooting.md`](docs/user/troubleshooting.md) |
| **开发者** | [`docs/dev/`](docs/dev/README.md) —— TODO、KNOWN-ISSUES、CHANGELOG、内核 SOP、移植指南 |
| **硬件/协议事实** | [`docs/research/`](docs/research/README.md) —— `hardware-facts.md` 为经实测验证的权威来源 |

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

宿主机要求：Arch Linux（构建原生运行）。软件包：`debootstrap
arm-linux-gnueabihf-gcc dtc uboot-tools qemu-system-arm dosfstools parted
cpio rsync`，外加从 Debian qemu-user-static .deb 项目内提取的
`qemu-arm-static`（`scripts/env-setup.sh`）。

```sh
scripts/build-all.sh            # 增量构建（跳过已有产物），U-Boot 链路
scripts/build-all.sh --clean    # 从零完整复现
CHAIN=stub KERNEL=6.6 \
scripts/build-all.sh            # 回滚链路（linux-xlnx 6.6 + stub SSBL）
scripts/test-qemu.sh uboot      # QEMU 门禁 —— 刷机前必过
scripts/flash-image.sh /dev/sdX output/web888-debian-uboot.img
```

所有可配置项（`KERNEL`、`CHAIN`、镜像源）见
[`docs/user/building.md`](docs/user/building.md)。

所有非生成的构建输入已收录进 `resources/`（原装 boot.bin、busybox-static
.deb —— 见 `resources/README.md`），全新 clone 即可直接构建，无需任何手工
拷贝步骤；仅内核源码、bootgen、debootstrap 需要联网。

刷机、首次启动以及如何在网络中找到设备，请按
[`docs/user/flashing.md`](docs/user/flashing.md) 操作。

## 安全

- 刷机脚本只允许操作可移动 USB 读卡器，拒绝触碰系统盘。
- 原厂 TF 卡保持不动，作为已知可用的回退方案。
- 没有串口：每个镜像先在 QEMU 中启动测试通过后才允许上硬件。

## 许可证

本项目采用 **GNU 通用公共许可证第二版（或你选择的更新版本）** 授权 —— 见
[`LICENSE`](LICENSE)。SPDX 标识符：`GPL-2.0-or-later`。

选择本许可证的原因：

- 与已收录的 `resources/reference/xilinx/xilinx_devcfg.c`（GPL-2.0-only，
  Xilinx 2011-2013）及 linux-xlnx 基础内核（GPL-2.0-or-later）完全兼容。
- 与已收录的 RaspSDR/server 参考代码（KiwiSDR fork，按
  `resources/reference/raspsdr-server/PROVENANCE.md` 是"per-file 混合 GPL/LGPL"）兼容。
- 符合内核模块惯例（zynqsdr 驱动）。
- 上游 KiwiSDR（jks-prv/Beagle_SDR_GPS）为 GPL-3.0-or-later；"or later"
  子句让我们在任意方向上重新授权兼容的子树。

`resources/reference/` 下的参考代码保留其原始上游许可证（详见各文件头及
`PROVENANCE.md`），本 LICENSE 文件不重新授权第三方参考代码。
