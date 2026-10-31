/*
 * "web888" machine (Web-888 SDR on the Zynq-7000 model).
 *
 * Copyright (c) 2026 web888-ng contributors
 *
 * SPDX-License-Identifier: GPL-2.0-or-later
 */

#ifndef HW_ARM_WEB888_H
#define HW_ARM_WEB888_H

#include "hw/arm/xilinx_zynq.h"

#define TYPE_WEB888_MACHINE MACHINE_TYPE_NAME("web888")
OBJECT_DECLARE_SIMPLE_TYPE(Web888MachineState, WEB888_MACHINE)

struct Web888MachineState {
    ZynqMachineState parent;
    char *mac;
    bool cpu_on[ZYNQ_MAX_CPUS];
};

struct arm_boot_info;

/* Called from zynq_init() before the kernel is loaded. */
void web888_board_init(MachineState *machine, qemu_irq *pic,
                       DeviceState *slcr, struct arm_boot_info *binfo);

#endif
