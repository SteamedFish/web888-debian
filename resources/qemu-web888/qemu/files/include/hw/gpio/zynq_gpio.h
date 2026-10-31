/*
 * Xilinx Zynq-7000 PS GPIO controller.
 *
 * Copyright (c) 2026 web888-ng contributors
 *
 * SPDX-License-Identifier: GPL-2.0-or-later
 */

#ifndef HW_GPIO_ZYNQ_GPIO_H
#define HW_GPIO_ZYNQ_GPIO_H

#include "hw/core/sysbus.h"
#include "qom/object.h"

#define TYPE_ZYNQ_GPIO "zynq-gpio"
OBJECT_DECLARE_SIMPLE_TYPE(ZynqGPIOState, ZYNQ_GPIO)

#define ZYNQ_GPIO_BANKS 4
#define ZYNQ_GPIO_PINS  118

struct ZynqGPIOState {
    SysBusDevice parent_obj;

    MemoryRegion iomem;
    qemu_irq irq;
    qemu_irq out[ZYNQ_GPIO_PINS];

    uint32_t data[ZYNQ_GPIO_BANKS];
    uint32_t in[ZYNQ_GPIO_BANKS];
    uint32_t dirm[ZYNQ_GPIO_BANKS];
    uint32_t oen[ZYNQ_GPIO_BANKS];
    uint32_t int_mask[ZYNQ_GPIO_BANKS];
    uint32_t int_stat[ZYNQ_GPIO_BANKS];
    uint32_t int_type[ZYNQ_GPIO_BANKS];
    uint32_t int_pol[ZYNQ_GPIO_BANKS];
    uint32_t int_any[ZYNQ_GPIO_BANKS];
    uint32_t out_prev[ZYNQ_GPIO_BANKS];
    uint32_t drive_prev[ZYNQ_GPIO_BANKS];
};

#endif
