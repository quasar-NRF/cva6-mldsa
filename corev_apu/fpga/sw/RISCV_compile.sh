# ==================================================
# Giulio Golinelli - golinelli.giulio13@gmail.com
# TUMCREATE QUASAR RESEARCH ENGINEER
# Modified: 2026-06-17
# This file contains modifications vs. the upstream
# CVA6 / ML-DSA-OSH source fork.
# ==================================================

#!/bin/bash
set -euo pipefail

# TUMCREATE (2026-06-18): accept extra -D flags via $EXTRA_CFLAGS env var so callers
# (e.g. deploy_test.sh --sec-lvl) can pass compile-time overrides like -DSEC_LVL=2.
if [ $# -lt 1 ]; then
    echo "Usage: EXTRA_CFLAGS=\"-DFOO=1\" $0 <source.c> [output.elf]"
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
  ${EXTRA_CFLAGS:-} \
  "$SRC" \
  -o "$OUT" \
  -lgcc
