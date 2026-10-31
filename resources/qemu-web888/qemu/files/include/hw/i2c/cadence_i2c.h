/*
 * Cadence I2C controller (Xilinx Zynq-7000 PS I2C, "cdns,i2c-r1p10"),
 * master mode only.
 *
 * Copyright (c) 2026 web888-ng contributors
 *
 * SPDX-License-Identifier: GPL-2.0-or-later
 */

#ifndef HW_I2C_CADENCE_I2C_H
#define HW_I2C_CADENCE_I2C_H

#include "hw/core/sysbus.h"
#include "hw/i2c/i2c.h"
#include "qom/object.h"

#define TYPE_CADENCE_I2C "cadence-i2c"
OBJECT_DECLARE_SIMPLE_TYPE(CadenceI2CState, CADENCE_I2C)

#define CADENCE_I2C_FIFO 16

struct CadenceI2CState {
    SysBusDevice parent_obj;

    MemoryRegion iomem;
    qemu_irq irq;
    I2CBus *bus;

    uint32_t cr;
    uint32_t addr;
    uint32_t isr;
    uint32_t imr;
    uint32_t xfer;          /* transfer size register */
    uint32_t timeout;

    uint8_t fifo[CADENCE_I2C_FIFO];
    unsigned fifo_head, fifo_len;

    bool active;            /* a master transfer is in progress */
    bool bus_held;          /* START sent, no STOP yet */
    bool rx;                /* direction of the current transfer */
};

#define TYPE_WEB888_SI5351 "web888-si5351"
OBJECT_DECLARE_SIMPLE_TYPE(Web888Si5351State, WEB888_SI5351)

struct Web888Si5351State {
    I2CSlave parent_obj;
    uint8_t regs[256];
    uint8_t ptr;
    bool first;
    bool log;
};

#endif
