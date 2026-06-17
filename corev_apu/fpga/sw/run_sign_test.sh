# ==================================================
# Giulio Golinelli - golinelli.giulio13@gmail.com
# TUMCREATE QUASAR RESEARCH ENGINEER
# Modified: 2026-06-17
# This file contains modifications vs. the upstream
# CVA6 / ML-DSA-OSH source fork.
# ==================================================

#!/bin/bash
# Run sign-only test with diagnostics
set -euo pipefail

GDB="/opt/riscv/bin/riscv-none-elf-gdb"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ELF="$SCRIPT_DIR/mldsa_sign_test.elf"

pkill openocd 2>/dev/null || true; sleep 1

echo "Reprogramming FPGA..."
/opt/Xilinx/2025.2/Vivado/bin/vivado -nojournal -mode batch -source /tmp/program_fpga.tcl 2>&1 | grep -E "(programmed|ERROR)" | head -3
sleep 2

echo "Starting OpenOCD..."
openocd -f "$HOME/cva6/corev_apu/fpga/ariane.cfg" > /tmp/openocd.log 2>&1 &
for i in $(seq 1 30); do nc -z localhost 3333 2>/dev/null && break; sleep 0.5; done
nc -z localhost 3333 2>/dev/null || { echo "OpenOCD failed"; exit 1; }

GDB_LOAD=$(mktemp /tmp/gdb_load_XXXXXX.gdb)
cat > "$GDB_LOAD" <<'GDBEOF'
set architecture riscv:rv64
set pagination off
set confirm off
set remotetimeout 10
target remote :3333
monitor reset halt
load
monitor resume
quit
GDBEOF

echo "Running signing test..."
"$GDB" -batch -x "$GDB_LOAD" "$ELF" 2>&1 | grep -E "(Loading|Start address|Transfer)" | head -5
rm -f "$GDB_LOAD"

sleep 15

GDB_READ=$(mktemp /tmp/gdb_read_XXXXXX.gdb)
cat > "$GDB_READ" <<'GDBEOF'
set architecture riscv:rv64
set pagination off
set confirm off
set remotetimeout 10
target remote :3333
interrupt

printf "\n=== SIGN TEST RESULT ===\n"
printf "result = 0x%lx\n", result

set $status = *(volatile unsigned long long*)0x50000018
set $diag = *(volatile unsigned long long*)0x50000020

printf "STATUS = 0x%016llx\n", $status
printf "  push_cnt=%d busy=%d out_empty=%d in_full=%d\n", ($status >> 16) & 0xFFFF, ($status >> 6) & 1, ($status >> 2) & 1, ($status >> 1) & 1

printf "\nDIAG = 0x%016llx\n", $diag
set $cs0 = $diag & 0x1F
printf "  cstate0=%d cstate1=%d cstate2=%d\n", $cs0, ($diag >> 5) & 0x1F, ($diag >> 10) & 0x1F
printf "  ctr=%d done_op0=%d start_op0=%d\n", ($diag >> 27) & 0x7FF, ($diag >> 55) & 1, ($diag >> 56) & 1

printf "\n--- Diagnostics after each push phase ---\n"
printf "after mlen:  DIAG=0x%016lx STATUS=0x%016lx\n", diag_after_push[0], status_after_push[0]
printf "after tr:    DIAG=0x%016lx STATUS=0x%016lx\n", diag_after_push[1], status_after_push[1]
printf "after fmtd:  DIAG=0x%016lx STATUS=0x%016lx\n", diag_after_push[2], status_after_push[2]
printf "after K:     DIAG=0x%016lx STATUS=0x%016lx\n", diag_after_push[3], status_after_push[3]
printf "after rnd:   DIAG=0x%016lx STATUS=0x%016lx\n", diag_after_push[4], status_after_push[4]
printf "after s1:    DIAG=0x%016lx STATUS=0x%016lx\n", diag_after_push[5], status_after_push[5]
printf "after s2:    DIAG=0x%016lx STATUS=0x%016lx\n", diag_after_push[6], status_after_push[6]
printf "after t0:    DIAG=0x%016lx STATUS=0x%016lx\n", diag_after_push[7], status_after_push[7]
if result >= 0xBAD0000000000000ull
printf "stall:       DIAG=0x%016lx STATUS=0x%016lx\n", diag_after_push[15], status_after_push[15]
end

quit
GDBEOF

echo "Reading diagnostics..."
"$GDB" -batch -x "$GDB_READ" "$ELF" 2>&1 | grep -v "^$" | grep -v "Ignoring" | grep -v "Traceback" | grep -v "Exception" | grep -v "KeyboardInterrupt" | tail -30

rm -f "$GDB_READ" "$GDB_LOAD"
echo ""
echo "Done."
