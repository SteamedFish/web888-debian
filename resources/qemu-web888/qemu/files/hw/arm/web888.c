/*
 * "web888" machine: the Web-888 SDR board on top of the Xilinx Zynq-7000
 * model (xilinx-zynq-a9).
 *
 * Adds what the Web-888 firmware needs and the generic Zynq machine
 * lacks or leaves unimplemented:
 *   - web888-pl: the FPGA (PL) register hub with synthetic DDC data
 *   - cadence-i2c @ 0xE0004000 with a 24c64 EEPROM @ 0x50 (holds the MAC
 *     at 0x10, like the board) and an Si5351 stub @ 0x60
 *   - zynq-gpio @ 0xE000A000 (driver GPIOs on MIO 10-13/49, PPS on EMIO 54)
 *
 * Copyright (c) 2026 web888-ng contributors
 *
 * SPDX-License-Identifier: GPL-2.0-or-later
 */

#include "qemu/osdep.h"
#include "qemu/units.h"
#include "qemu/error-report.h"
#include "qapi/error.h"
#include "hw/core/sysbus.h"
#include "hw/core/boards.h"
#include "hw/core/irq.h"
#include "system/reset.h"
#include "hw/i2c/i2c.h"
#include "hw/nvram/eeprom_at24c.h"
#include "hw/arm/xilinx_zynq.h"
#include "hw/arm/boot.h"
#include "target/arm/arm-powerctl.h"
#include "target/arm/cpu.h"
#include "hw/arm/web888.h"
#include "hw/misc/web888_pl.h"
#include "hw/i2c/cadence_i2c.h"
#include "hw/gpio/zynq_gpio.h"

#define WEB888_EEPROM_SIZE   8192
#define WEB888_EEPROM_MAC    0x10

/* GIC SPI numbers (as in the device tree) */
#define SPI_GPIO   20
#define SPI_I2C0   25
#define SPI_F2P0   29

static bool parse_mac(const char *str, uint8_t mac[6])
{
    unsigned v[6];
    if (sscanf(str, "%x:%x:%x:%x:%x:%x", &v[0], &v[1], &v[2], &v[3], &v[4],
               &v[5]) != 6) {
        return false;
    }
    for (int i = 0; i < 6; i++) {
        if (v[i] > 0xff) {
            return false;
        }
        mac[i] = v[i];
    }
    return true;
}

/*
 * SMP: the secondary CPU starts powered off and is released through the
 * SLCR A9_CPU_RST_CTRL register like on hardware (Linux zynq platsmp puts
 * a trampoline at address 0, then deasserts the CPU's reset).
 */
static void web888_cpu_reset_line(void *opaque, int n, int level)
{
    Web888MachineState *wm = opaque;

    if (n == 0 || n >= ZYNQ_MAX_CPUS) {
        return;
    }
    if (level && wm->cpu_on[n]) {
        arm_set_cpu_off(n);
        wm->cpu_on[n] = false;
    } else if (!level && !wm->cpu_on[n]) {
        /*
         * In CPU0's security state, as the hardware does: a kernel QEMU
         * booted runs non-secure (EL1), one a boot loader started on the
         * board's path (--bootrom) secure; a mismatch leaves Linux's
         * timer interrupts undelivered.
         */
        CPUState *cpu0 = qemu_get_cpu(0);
        int el = cpu0 && arm_is_secure(&ARM_CPU(cpu0)->env) ? 3 : 1;

        if (arm_set_cpu_on(n, 0x0, 0, el, false) ==
            QEMU_ARM_POWERCTL_RET_SUCCESS) {
            wm->cpu_on[n] = true;
        }
    }
}

static void web888_write_secondary(ARMCPU *cpu,
                                   const struct arm_boot_info *info)
{
}

static void web888_reset_secondary(ARMCPU *cpu,
                                   const struct arm_boot_info *info)
{
    /* stays powered off ("start-powered-off") until the SLCR releases it */
}

static void web888_machine_reset(MachineState *machine, ResetType type)
{
    Web888MachineState *wm = WEB888_MACHINE(machine);

    for (int i = 0; i < ZYNQ_MAX_CPUS; i++) {
        wm->cpu_on[i] = i == 0;
    }
    qemu_devices_reset(type);
}

void web888_board_init(MachineState *machine, qemu_irq *pic,
                       DeviceState *slcr, struct arm_boot_info *binfo)
{
    Web888MachineState *wm = WEB888_MACHINE(machine);
    DeviceState *pl, *i2c, *gpio;
    SysBusDevice *sbd;
    I2CBus *bus;
    uint8_t *rom = g_malloc0(WEB888_EEPROM_SIZE);
    uint8_t mac[6] = { 0x02, 0x88, 0x88, 0x00, 0x00, 0x01 };

    binfo->write_secondary_boot = web888_write_secondary;
    binfo->secondary_cpu_reset_hook = web888_reset_secondary;
    for (int i = 0; i < ZYNQ_MAX_CPUS; i++) {
        qdev_connect_gpio_out_named(slcr, "cpu-reset", i,
            qemu_allocate_irq(web888_cpu_reset_line, wm, i));
    }

    /* PL */
    pl = qdev_new(TYPE_WEB888_PL);
    sbd = SYS_BUS_DEVICE(pl);
    sysbus_realize_and_unref(sbd, &error_fatal);
    sysbus_mmio_map(sbd, 0, WEB888_CFG_BASE);
    sysbus_mmio_map(sbd, 1, WEB888_STS_BASE);
    sysbus_mmio_map(sbd, 2, WEB888_PPS_BASE);
    for (int i = 0; i < 4; i++) {
        sysbus_connect_irq(sbd, i, pic[SPI_F2P0 + i]);
    }

    /* GPIO */
    gpio = qdev_new(TYPE_ZYNQ_GPIO);
    sbd = SYS_BUS_DEVICE(gpio);
    sysbus_realize_and_unref(sbd, &error_fatal);
    sysbus_mmio_map(sbd, 0, 0xE000A000);
    sysbus_connect_irq(sbd, 0, pic[SPI_GPIO]);
    qdev_connect_gpio_out_named(pl, "pps", 0, qdev_get_gpio_in(gpio, 54));
    qdev_connect_gpio_out(gpio, 10,
                          qdev_get_gpio_in(pl, WEB888_GPIO_IN_HFVHF));
    qdev_connect_gpio_out(gpio, 13,
                          qdev_get_gpio_in(pl, WEB888_GPIO_IN_ATT_CLK));
    qdev_connect_gpio_out(gpio, 12,
                          qdev_get_gpio_in(pl, WEB888_GPIO_IN_ATT_LATCH));
    qdev_connect_gpio_out(gpio, 11,
                          qdev_get_gpio_in(pl, WEB888_GPIO_IN_ATT_DATA));
    qdev_connect_gpio_out(gpio, 49,
                          qdev_get_gpio_in(pl, WEB888_GPIO_IN_REFCLK));

    /* I2C0 with EEPROM and Si5351 */
    i2c = qdev_new(TYPE_CADENCE_I2C);
    sbd = SYS_BUS_DEVICE(i2c);
    sysbus_realize_and_unref(sbd, &error_fatal);
    sysbus_mmio_map(sbd, 0, 0xE0004000);
    sysbus_connect_irq(sbd, 0, pic[SPI_I2C0]);
    bus = I2C_BUS(qdev_get_child_bus(i2c, "i2c"));

    if (wm->mac && !parse_mac(wm->mac, mac)) {
        error_report("web888: bad mac '%s' (want xx:xx:xx:xx:xx:xx)",
                     wm->mac);
        exit(1);
    }
    memset(rom, 0xff, WEB888_EEPROM_SIZE);
    memcpy(rom + WEB888_EEPROM_MAC, mac, 6);
    at24c_eeprom_init_rom(bus, 0x50, WEB888_EEPROM_SIZE, rom,
                          WEB888_EEPROM_SIZE);
    g_free(rom);
    i2c_slave_create_simple(bus, TYPE_WEB888_SI5351, 0x60);
}

static char *web888_get_mac(Object *obj, Error **errp)
{
    return g_strdup(WEB888_MACHINE(obj)->mac);
}

static void web888_set_mac(Object *obj, const char *v, Error **errp)
{
    Web888MachineState *wm = WEB888_MACHINE(obj);
    g_free(wm->mac);
    wm->mac = g_strdup(v);
}

static void web888_machine_class_init(ObjectClass *oc, const void *data)
{
    MachineClass *mc = MACHINE_CLASS(oc);

    mc->desc = "Web-888 SDR (Zynq-7010 + emulated FPGA logic)";
    mc->default_ram_size = 512 * MiB;
    mc->default_cpus = 2;
    mc->reset = web888_machine_reset;
    object_class_property_add_str(oc, "mac", web888_get_mac, web888_set_mac);
    object_class_property_set_description(oc, "mac",
        "MAC address stored in the board EEPROM (offset 0x10), "
        "xx:xx:xx:xx:xx:xx");
}

static const TypeInfo web888_machine_type = {
    .name = TYPE_WEB888_MACHINE,
    .parent = TYPE_ZYNQ_MACHINE,
    .instance_size = sizeof(Web888MachineState),
    .class_init = web888_machine_class_init,
};

static void web888_machine_register_types(void)
{
    type_register_static(&web888_machine_type);
}

type_init(web888_machine_register_types)
