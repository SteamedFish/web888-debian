# web888 boot script — step 6. Compiled to boot.scr (mkimage -T script)
# by build-boot-deb.sh and placed at the FAT root, where bootstd's script
# bootmeth picks it up (distro bootcmd, mmc0 first). The KERNEL comes from
# the ext4 rootfs partition (p2): /boot/zImage, a symlink managed by the
# web888-boot kernel hook. Script/env/dtb stay on the FAT firmware
# partition (p1, mounted at /boot/firmware once Linux is up) — the Zynq
# BootROM mandates boot.bin on FAT, and uEnv.txt must sit beside boot.scr
# for the env import below. bootargs live HERE, not in the dtb.
#
# uEnv.txt on the FAT partition overrides any of these (env import), e.g.
#   kernel_file=vmlinuz-6.12.101-web888   (boot one installed version)
#   bootargs_extra=earlycon ignore_loglevel
setenv kernel_file zImage
setenv dtb_file web888.dtb
setenv prev_kernel_file zImage.prev
setenv bootargs_base 'console=ttyPS0,115200 earlycon root=/dev/mmcblk0p2 rw rootwait fw_devlink=off net.ifnames=0'

# Program armpll FBDIV=40 / cpu divisor=2 (= 666.67 MHz, an OPP-listed rate).
# The real FSBL does this on silicon; QEMU never runs ps7 init, so without it
# the kernel cpufreq probe sees a non-table frequency and (on the corrective
# transition) can hit BUG_ON(cpufreq.c:1539). Idempotent on real hardware.
mw.l 0xF8000008 0xDF0D
mw.l 0xF8000100 0x00028008
mw.l 0xF8000120 0x1F000200
mw.l 0xF8000004 0x767B

if load ${devtype} ${devnum}:${distro_bootpart} ${scriptaddr} uEnv.txt; then
    env import -t ${scriptaddr} ${filesize}
fi

setenv bootargs ${bootargs_base} ${bootargs_extra}

# Kernel from the ext4 rootfs (p2), dtb from the FAT firmware partition.
if load ${devtype} ${devnum}:2 ${kernel_addr_r} /boot/${kernel_file} \
   && load ${devtype} ${devnum}:${distro_bootpart} ${fdt_addr_r} ${dtb_file}; then
    bootz ${kernel_addr_r} - ${fdt_addr_r}
fi

echo "primary ${kernel_file} failed; trying ${prev_kernel_file}"
if load ${devtype} ${devnum}:2 ${kernel_addr_r} /boot/${prev_kernel_file} \
   && load ${devtype} ${devnum}:${distro_bootpart} ${fdt_addr_r} ${dtb_file}; then
    bootz ${kernel_addr_r} - ${fdt_addr_r}
fi

echo "FALLBACK FAILED — dropping to U-Boot prompt"