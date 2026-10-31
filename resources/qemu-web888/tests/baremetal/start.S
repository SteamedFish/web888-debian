/* SPDX-License-Identifier: GPL-3.0-or-later */
    .section .text.start
    .global _start
_start:
    ldr sp, =__stack_top
    /* enable VFP (soft-float build does not need it, keep it simple) */
    bl main
1:  wfi
    b 1b
