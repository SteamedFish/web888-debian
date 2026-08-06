# web888 boot script — step 6. Compiled to boot.scr (mkimage -T script)
# by build-image.sh uboot and placed at the FAT root, where bootstd's script
# bootmeth picks it up (distro bootcmd, mmc0 first). Kernel/dtb come from
# the FAT partition; bootargs live HERE, not in the dtb.
#
# uEnv.txt on the same partition overrides any of these (env import), e.g.
#   kernel_file=zImage-6.12.99-web888   (test a new kernel)
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

if load ${devtype} ${devnum}:${distro_bootpart} ${kernel_addr_r} ${kernel_file} \
   && load ${devtype} ${devnum}:${distro_bootpart} ${fdt_addr_r} ${dtb_file}; then
    bootz ${kernel_addr_r} - ${fdt_addr_r}
fi

echo "primary ${kernel_file} failed; trying ${prev_kernel_file}"
if load ${devtype} ${devnum}:${distro_bootpart} ${kernel_addr_r} ${prev_kernel_file} \
   && load ${devtype} ${devnum}:${distro_bootpart} ${fdt_addr_r} ${dtb_file}; then
    bootz ${kernel_addr_r} - ${fdt_addr_r}
fi

echo "FALLBACK FAILED — dropping to U-Boot prompt"
