/*
 * Xilinx Zynq-7000 PS GPIO controller ("xlnx,zynq-gpio-1.0").
 *
 * 4 banks (MIO 0-31, MIO 32-53, EMIO 54-85, EMIO 86-117). GPIO lines
 * (qdev gpio "in" / "out") are numbered like Linux GPIO offsets 0..117.
 * Inputs drive DATA_RO for pins not configured as outputs and the
 * edge/level interrupt logic; outputs follow DATA & DIRM & OEN.
 *
 * Copyright (c) 2026 web888-ng contributors
 *
 * SPDX-License-Identifier: GPL-2.0-or-later
 */

#include "qemu/osdep.h"
#include "qemu/log.h"
#include "qemu/module.h"
#include "hw/core/irq.h"
#include "hw/core/sysbus.h"
#include "hw/core/qdev-properties.h"
#include "migration/vmstate.h"
#include "hw/gpio/zynq_gpio.h"

static const unsigned bank_pins[ZYNQ_GPIO_BANKS] = { 32, 22, 32, 32 };
static const unsigned bank_base[ZYNQ_GPIO_BANKS] = { 0, 32, 54, 86 };

static uint32_t bank_mask(int b)
{
    return bank_pins[b] == 32 ? 0xffffffffu : (1u << bank_pins[b]) - 1;
}

static void zgpio_update_irq(ZynqGPIOState *s)
{
    bool lvl = false;

    for (int b = 0; b < ZYNQ_GPIO_BANKS; b++) {
        /* level-sensitive pins follow the input continuously */
        uint32_t level = ~s->int_type[b];
        uint32_t active = ~(s->in[b] ^ s->int_pol[b]);
        s->int_stat[b] = (s->int_stat[b] & ~level) | (active & level);
        s->int_stat[b] &= bank_mask(b);
        if (s->int_stat[b] & ~s->int_mask[b]) {
            lvl = true;
        }
    }
    qemu_set_irq(s->irq, lvl);
}

static void zgpio_update_out(ZynqGPIOState *s)
{
    for (int b = 0; b < ZYNQ_GPIO_BANKS; b++) {
        uint32_t drive = s->dirm[b] & s->oen[b];
        uint32_t v = s->data[b];
        uint32_t ch = (v ^ s->out_prev[b]) | (drive ^ s->drive_prev[b]);
        for (unsigned i = 0; i < bank_pins[b]; i++) {
            if (ch & (1u << i)) {
                bool level = (drive & (1u << i)) ? (v >> i) & 1
                                                  : (s->in[b] >> i) & 1;
                qemu_set_irq(s->out[bank_base[b] + i], level);
            }
        }
        s->out_prev[b] = v;
        s->drive_prev[b] = drive;
    }
}

static void zgpio_set_in(void *opaque, int line, int level)
{
    ZynqGPIOState *s = opaque;
    int b;

    for (b = ZYNQ_GPIO_BANKS - 1; b > 0 && line < (int)bank_base[b]; b--) {
    }
    unsigned bit = line - bank_base[b];
    if (bit >= bank_pins[b]) {
        return;
    }
    uint32_t m = 1u << bit;
    bool old = s->in[b] & m;
    if (level) {
        s->in[b] |= m;
    } else {
        s->in[b] &= ~m;
    }
    if (old != !!level && (s->int_type[b] & m)) {
        bool rising = level;
        if ((s->int_any[b] & m) ||
            (rising == !!(s->int_pol[b] & m))) {
            s->int_stat[b] |= m;
        }
    }
    zgpio_update_irq(s);
}

static uint64_t zgpio_read(void *opaque, hwaddr off, unsigned size)
{
    ZynqGPIOState *s = opaque;

    if (off < 0x20) {
        return 0;                                   /* MASK_DATA: WO */
    }
    if (off >= 0x40 && off < 0x50) {
        return s->data[(off - 0x40) / 4];
    }
    if (off >= 0x60 && off < 0x70) {
        int b = (off - 0x60) / 4;
        uint32_t out = s->dirm[b];
        return ((s->data[b] & out) | (s->in[b] & ~out)) & bank_mask(b);
    }
    if (off >= 0x204 && off < 0x204 + 0x40 * ZYNQ_GPIO_BANKS) {
        int b = (off - 0x204) / 0x40;
        switch ((off - 0x204) % 0x40) {
        case 0x00:
            return s->dirm[b];
        case 0x04:
            return s->oen[b];
        case 0x08:
            return s->int_mask[b];
        case 0x14:
            return s->int_stat[b];
        case 0x18:
            return s->int_type[b];
        case 0x1C:
            return s->int_pol[b];
        case 0x20:
            return s->int_any[b];
        default:
            return 0;
        }
    }
    return 0;
}

static void zgpio_write(void *opaque, hwaddr off, uint64_t val,
                        unsigned size)
{
    ZynqGPIOState *s = opaque;
    uint32_t v = val;

    if (off < 0x20) {
        int b = off / 8;
        int sh = (off & 4) ? 16 : 0;
        uint32_t mask = (~v >> 16) & 0xffff;        /* 0 = write the bit */
        s->data[b] = (s->data[b] & ~(mask << sh)) | ((v & mask) << sh);
        s->data[b] &= bank_mask(b);
    } else if (off >= 0x40 && off < 0x50) {
        int b = (off - 0x40) / 4;
        s->data[b] = v & bank_mask(b);
    } else if (off >= 0x204 && off < 0x204 + 0x40 * ZYNQ_GPIO_BANKS) {
        int b = (off - 0x204) / 0x40;
        switch ((off - 0x204) % 0x40) {
        case 0x00:
            s->dirm[b] = v & bank_mask(b);
            break;
        case 0x04:
            s->oen[b] = v & bank_mask(b);
            break;
        case 0x0C:
            s->int_mask[b] &= ~v;
            break;
        case 0x10:
            s->int_mask[b] |= v & bank_mask(b);
            break;
        case 0x14:
            s->int_stat[b] &= ~v;
            break;
        case 0x18:
            s->int_type[b] = v & bank_mask(b);
            break;
        case 0x1C:
            s->int_pol[b] = v & bank_mask(b);
            break;
        case 0x20:
            s->int_any[b] = v & bank_mask(b);
            break;
        default:
            break;
        }
        zgpio_update_irq(s);
    }
    zgpio_update_out(s);
}

static const MemoryRegionOps zgpio_ops = {
    .read = zgpio_read,
    .write = zgpio_write,
    .endianness = DEVICE_LITTLE_ENDIAN,
    .valid = { .min_access_size = 4, .max_access_size = 4 },
};

static void zgpio_reset_hold(Object *obj, ResetType type)
{
    ZynqGPIOState *s = ZYNQ_GPIO(obj);

    for (int b = 0; b < ZYNQ_GPIO_BANKS; b++) {
        s->data[b] = 0;
        s->dirm[b] = 0;
        s->oen[b] = 0;
        s->int_mask[b] = 0;
        s->int_stat[b] = 0;
        s->int_type[b] = b < 2 ? 0xffffffff & bank_mask(b) : 0xffffffff;
        s->int_pol[b] = 0;
        s->int_any[b] = 0;
    }
    zgpio_update_irq(s);
}

static void zgpio_init(Object *obj)
{
    ZynqGPIOState *s = ZYNQ_GPIO(obj);
    SysBusDevice *sbd = SYS_BUS_DEVICE(obj);

    memory_region_init_io(&s->iomem, obj, &zgpio_ops, s, "zynq-gpio",
                          0x1000);
    sysbus_init_mmio(sbd, &s->iomem);
    sysbus_init_irq(sbd, &s->irq);
    qdev_init_gpio_in(DEVICE(obj), zgpio_set_in, ZYNQ_GPIO_PINS);
    qdev_init_gpio_out(DEVICE(obj), s->out, ZYNQ_GPIO_PINS);
}

static const VMStateDescription vmstate_zgpio = {
    .name = TYPE_ZYNQ_GPIO,
    .unmigratable = 1,
};

static void zgpio_class_init(ObjectClass *klass, const void *data)
{
    DeviceClass *dc = DEVICE_CLASS(klass);
    ResettableClass *rc = RESETTABLE_CLASS(klass);

    dc->desc = "Xilinx Zynq-7000 PS GPIO";
    dc->vmsd = &vmstate_zgpio;
    rc->phases.hold = zgpio_reset_hold;
}

static const TypeInfo zgpio_info = {
    .name = TYPE_ZYNQ_GPIO,
    .parent = TYPE_SYS_BUS_DEVICE,
    .instance_size = sizeof(ZynqGPIOState),
    .instance_init = zgpio_init,
    .class_init = zgpio_class_init,
};

static void zgpio_register_types(void)
{
    type_register_static(&zgpio_info);
}

type_init(zgpio_register_types)
