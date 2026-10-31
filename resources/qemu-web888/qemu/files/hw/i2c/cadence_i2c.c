/*
 * Cadence I2C controller (Xilinx Zynq-7000 PS I2C, "cdns,i2c-r1p10"),
 * master mode only, plus a register-file stub of an Si5351 clock
 * generator (enough for software that programs it over /dev/i2c-N).
 *
 * Transfers complete instantly (no bus timing). The FIFO, transfer-size
 * register, HOLD (repeated start) and interrupt semantics follow UG585
 * closely enough for the Linux i2c-cadence driver.
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
#include "hw/i2c/i2c.h"
#include "hw/i2c/cadence_i2c.h"

#define R_CR        0x00
#define R_SR        0x04
#define R_ADDR      0x08
#define R_DATA      0x0C
#define R_ISR       0x10
#define R_XFER      0x14
#define R_SLV_PAUSE 0x18
#define R_TIMEOUT   0x1C
#define R_IMR       0x20
#define R_IER       0x24
#define R_IDR       0x28

#define CR_RW       (1 << 0)
#define CR_MS       (1 << 1)
#define CR_NEA      (1 << 2)
#define CR_ACK_EN   (1 << 3)
#define CR_HOLD     (1 << 4)
#define CR_CLR_FIFO (1 << 6)

#define SR_RXRW     (1 << 3)
#define SR_RXDV     (1 << 5)
#define SR_TXDV     (1 << 6)
#define SR_BA       (1 << 8)

#define IXR_COMP    (1 << 0)
#define IXR_DATA    (1 << 1)
#define IXR_NACK    (1 << 2)
#define IXR_TO      (1 << 3)
#define IXR_RX_OVF  (1 << 5)
#define IXR_TX_OVF  (1 << 6)
#define IXR_RX_UNF  (1 << 7)
#define IXR_ARB     (1 << 9)
#define IXR_ALL     0x2FF

static void ci2c_update_irq(CadenceI2CState *s)
{
    qemu_set_irq(s->irq, !!(s->isr & ~s->imr & IXR_ALL));
}

static void ci2c_fifo_clear(CadenceI2CState *s)
{
    s->fifo_head = 0;
    s->fifo_len = 0;
}

static void ci2c_push(CadenceI2CState *s, uint8_t v)
{
    if (s->fifo_len < CADENCE_I2C_FIFO) {
        s->fifo[(s->fifo_head + s->fifo_len) % CADENCE_I2C_FIFO] = v;
        s->fifo_len++;
    }
}

static uint8_t ci2c_pop(CadenceI2CState *s)
{
    uint8_t v = s->fifo[s->fifo_head];
    s->fifo_head = (s->fifo_head + 1) % CADENCE_I2C_FIFO;
    s->fifo_len--;
    return v;
}

static void ci2c_stop(CadenceI2CState *s)
{
    if (s->bus_held) {
        i2c_end_transfer(s->bus);
        s->bus_held = false;
    }
    s->active = false;
}

static void ci2c_nack(CadenceI2CState *s)
{
    i2c_end_transfer(s->bus);
    s->bus_held = false;
    s->active = false;
    s->isr |= IXR_NACK;
    ci2c_fifo_clear(s);
    s->xfer = 0;
}

/* Run the current transfer as far as the FIFO allows. */
static void ci2c_run(CadenceI2CState *s)
{
    if (!s->active) {
        return;
    }
    if (s->rx) {
        while (s->xfer > 0 && s->fifo_len < CADENCE_I2C_FIFO) {
            ci2c_push(s, i2c_recv(s->bus));
            s->xfer--;
        }
        if (s->xfer == 0) {
            s->isr |= IXR_COMP;
            if (!(s->cr & CR_HOLD)) {
                ci2c_stop(s);
            } else {
                s->active = false;      /* done, bus still held */
            }
        } else if (s->fifo_len >= CADENCE_I2C_FIFO - 2) {
            s->isr |= IXR_DATA;
        }
    } else {
        bool sent = false;
        while (s->fifo_len) {
            if (i2c_send(s->bus, ci2c_pop(s))) {
                ci2c_nack(s);
                return;
            }
            sent = true;
        }
        s->xfer = 0;
        if (sent || !(s->cr & CR_HOLD)) {
            s->isr |= IXR_COMP;
        }
        if (!(s->cr & CR_HOLD)) {
            ci2c_stop(s);
        }
    }
}

static void ci2c_start(CadenceI2CState *s)
{
    uint8_t a = s->addr & 0x7f;

    s->rx = s->cr & CR_RW;
    if (i2c_start_transfer(s->bus, a, s->rx)) {
        ci2c_nack(s);
        return;
    }
    s->bus_held = true;
    s->active = true;
    ci2c_run(s);
}

static uint64_t ci2c_read(void *opaque, hwaddr off, unsigned size)
{
    CadenceI2CState *s = opaque;
    uint32_t v = 0;

    switch (off) {
    case R_CR:
        v = s->cr;
        break;
    case R_SR:
        if (s->rx && s->fifo_len) {
            v |= SR_RXDV;
        }
        if (!s->rx && s->fifo_len) {
            v |= SR_TXDV;
        }
        if (s->bus_held) {
            v |= SR_BA;
        }
        break;
    case R_ADDR:
        v = s->addr;
        break;
    case R_DATA:
        if (s->rx && s->fifo_len) {
            v = ci2c_pop(s);
            ci2c_run(s);
            ci2c_update_irq(s);
        } else {
            s->isr |= IXR_RX_UNF;
            ci2c_update_irq(s);
        }
        break;
    case R_ISR:
        v = s->isr;
        break;
    case R_XFER:
        v = s->rx ? s->xfer : s->fifo_len;
        break;
    case R_TIMEOUT:
        v = s->timeout;
        break;
    case R_IMR:
        v = s->imr;
        break;
    default:
        break;
    }
    return v;
}

static void ci2c_write(void *opaque, hwaddr off, uint64_t val, unsigned size)
{
    CadenceI2CState *s = opaque;

    switch (off) {
    case R_CR: {
        bool hold_was = s->cr & CR_HOLD;
        s->cr = val & 0xff3f;               /* CLR_FIFO self-clears */
        if (val & CR_CLR_FIFO) {
            ci2c_fifo_clear(s);
            s->xfer = 0;
            /*
             * A new message is being set up: a write transfer that is only
             * waiting on HOLD is finished, the next ADDR write restarts.
             */
            if (s->active && !s->rx) {
                s->active = false;
            }
        }
        if (!(val & CR_RW) != !s->rx && !s->active) {
            s->rx = val & CR_RW;
        }
        if (hold_was && !(s->cr & CR_HOLD)) {
            if (s->active && (s->rx || s->fifo_len)) {
                ci2c_run(s);
            } else {
                ci2c_stop(s);               /* release a held bus */
            }
        }
        break;
    }
    case R_ADDR:
        s->addr = val & 0x3ff;
        ci2c_start(s);
        break;
    case R_DATA:
        if (s->rx) {
            break;
        }
        if (s->fifo_len >= CADENCE_I2C_FIFO) {
            s->isr |= IXR_TX_OVF;
            break;
        }
        ci2c_push(s, val);
        if (s->active) {
            /* bus held during a write: the controller continues */
            ci2c_run(s);
        }
        break;
    case R_ISR:
        s->isr &= ~(val & IXR_ALL);
        break;
    case R_XFER:
        s->xfer = val & 0xff;
        if (s->active && s->rx) {
            ci2c_run(s);
        }
        break;
    case R_TIMEOUT:
        s->timeout = val & 0xff;
        break;
    case R_IER:
        s->imr &= ~(val & IXR_ALL);
        break;
    case R_IDR:
        s->imr |= val & IXR_ALL;
        break;
    default:
        break;
    }
    ci2c_update_irq(s);
}

static const MemoryRegionOps ci2c_ops = {
    .read = ci2c_read,
    .write = ci2c_write,
    .endianness = DEVICE_LITTLE_ENDIAN,
    .valid = { .min_access_size = 4, .max_access_size = 4 },
};

static void ci2c_reset_hold(Object *obj, ResetType type)
{
    CadenceI2CState *s = CADENCE_I2C(obj);

    s->cr = 0;
    s->addr = 0;
    s->isr = 0;
    s->imr = IXR_ALL;
    s->xfer = 0;
    s->timeout = 0x1f;
    s->active = false;
    s->bus_held = false;
    s->rx = false;
    ci2c_fifo_clear(s);
    ci2c_update_irq(s);
}

static void ci2c_init(Object *obj)
{
    CadenceI2CState *s = CADENCE_I2C(obj);
    SysBusDevice *sbd = SYS_BUS_DEVICE(obj);

    memory_region_init_io(&s->iomem, obj, &ci2c_ops, s, "cadence-i2c",
                          0x1000);
    sysbus_init_mmio(sbd, &s->iomem);
    sysbus_init_irq(sbd, &s->irq);
    s->bus = i2c_init_bus(DEVICE(obj), "i2c");
}

static const VMStateDescription vmstate_ci2c = {
    .name = TYPE_CADENCE_I2C,
    .unmigratable = 1,
};

static void ci2c_class_init(ObjectClass *klass, const void *data)
{
    DeviceClass *dc = DEVICE_CLASS(klass);
    ResettableClass *rc = RESETTABLE_CLASS(klass);

    dc->desc = "Cadence I2C controller (Zynq-7000)";
    dc->vmsd = &vmstate_ci2c;
    rc->phases.hold = ci2c_reset_hold;
}

static const TypeInfo ci2c_info = {
    .name = TYPE_CADENCE_I2C,
    .parent = TYPE_SYS_BUS_DEVICE,
    .instance_size = sizeof(CadenceI2CState),
    .instance_init = ci2c_init,
    .class_init = ci2c_class_init,
};

/* ------------------------------------------------------------ Si5351 */

static int si5351_event(I2CSlave *i2c, enum i2c_event ev)
{
    Web888Si5351State *s = WEB888_SI5351(i2c);
    if (ev == I2C_START_SEND) {
        s->first = true;
    }
    return 0;
}

static uint8_t si5351_recv(I2CSlave *i2c)
{
    Web888Si5351State *s = WEB888_SI5351(i2c);
    uint8_t v = s->regs[s->ptr];
    if (s->ptr == 0) {
        v = 0;      /* SYS_INIT = 0, PLLs locked, no LOS */
    }
    s->ptr++;
    return v;
}

static int si5351_send(I2CSlave *i2c, uint8_t data)
{
    Web888Si5351State *s = WEB888_SI5351(i2c);
    if (s->first) {
        s->ptr = data;
        s->first = false;
    } else {
        if (s->log) {
            qemu_log("si5351: reg %3u <- 0x%02x\n", s->ptr, data);
        }
        s->regs[s->ptr++] = data;
    }
    return 0;
}

static void si5351_reset_hold(Object *obj, ResetType type)
{
    Web888Si5351State *s = WEB888_SI5351(obj);
    memset(s->regs, 0, sizeof(s->regs));
    s->ptr = 0;
    s->first = false;
}

static const Property si5351_props[] = {
    DEFINE_PROP_BOOL("log", Web888Si5351State, log, false),
};

static void si5351_class_init(ObjectClass *klass, const void *data)
{
    DeviceClass *dc = DEVICE_CLASS(klass);
    I2CSlaveClass *k = I2C_SLAVE_CLASS(klass);
    ResettableClass *rc = RESETTABLE_CLASS(klass);

    dc->desc = "Si5351 clock generator (register file stub)";
    k->event = si5351_event;
    k->recv = si5351_recv;
    k->send = si5351_send;
    rc->phases.hold = si5351_reset_hold;
    device_class_set_props(dc, si5351_props);
}

static const TypeInfo si5351_info = {
    .name = TYPE_WEB888_SI5351,
    .parent = TYPE_I2C_SLAVE,
    .instance_size = sizeof(Web888Si5351State),
    .class_init = si5351_class_init,
};

static void ci2c_register_types(void)
{
    type_register_static(&ci2c_info);
    type_register_static(&si5351_info);
}

type_init(ci2c_register_types)
