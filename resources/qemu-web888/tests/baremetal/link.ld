ENTRY(_start)
SECTIONS {
    . = 0x00100000;
    .text : { *(.text.start) *(.text*) *(.rodata*) }
    .data : { *(.data*) }
    .bss : { *(.bss*) *(COMMON) }
    . = ALIGN(16);
    . = . + 0x10000;
    __stack_top = .;
}
