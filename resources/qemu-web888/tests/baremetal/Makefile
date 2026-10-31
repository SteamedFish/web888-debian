# SPDX-License-Identifier: GPL-3.0-or-later
CC = arm-none-eabi-gcc
CFLAGS = -mcpu=cortex-a9 -marm -mfloat-abi=soft -O2 -ffreestanding -nostdlib -Wall
pltest.elf: start.S pltest.c link.ld
	$(CC) $(CFLAGS) -T link.ld -o $@ start.S pltest.c -lgcc
clean:
	rm -f pltest.elf
