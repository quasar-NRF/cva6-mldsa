#!/bin/bash
set -euo pipefail

if [ $# -lt 1 ]; then
    echo "Usage: $0 <source.c> [output.elf]"
    exit 1
fi

SRC="$(realpath "$1")"
BASENAME="$(basename "${SRC%.c}")"
OUT="${2:-$(dirname "$SRC")/${BASENAME}.elf}"

/opt/riscv/bin/riscv-none-elf-gcc -march=rv64imac_zicsr -mabi=lp64 -mcmodel=medany -O0 -g \
  -nostdlib -nostartfiles \
  -I/home/quasart1/cva6/verif/tests/custom/env \
  -I/home/quasart1/cva6/verif/tests/custom/common \
  /home/quasart1/cva6/verif/tests/custom/common/syscalls.c \
  /home/quasart1/cva6/verif/tests/custom/common/crt.S \
  -T /home/quasart1/cva6/config/gen_from_riscv_config/linker/link.ld \
  "$SRC" \
  -o "$OUT" \
  -lgcc
