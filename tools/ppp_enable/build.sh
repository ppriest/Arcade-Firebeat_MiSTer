#!/bin/bash
# Builds ppp_enable for the MiSTer (ARM, static) with Main_MiSTer's toolchain, gcc-arm
# 10.2-2020.11 (Main_MiSTer setup_default_toolchain.sh). MISTER_GCC: its bin directory.
set -e
cd "$(dirname "$0")"
GCC=${MISTER_GCC:-$HOME/mister-gcc/gcc-arm-10.2-2020.11-x86_64-arm-none-linux-gnueabihf/bin}
"$GCC/arm-none-linux-gnueabihf-gcc" -O2 -Wall -Wextra -static -o ppp_enable ppp_enable.c
"$GCC/arm-none-linux-gnueabihf-strip" ppp_enable
ls -l ppp_enable
