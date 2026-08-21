#!/bin/sh

gcc -o schick.x schick.c

./schick.x < hello.sch > hello.rv32
chmod +x hello.rv32
qemu-riscv32 hello.rv32

# SPDX-License-Identifier: ISC

