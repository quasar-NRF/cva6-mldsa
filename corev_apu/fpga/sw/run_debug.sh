#!/bin/bash
# Clean run: reprogram FPGA, restart OpenOCD, run test, read diagnostics
set -euo pipefail

GDB="/opt/riscv/bin/riscv-none-elf-gdb"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

INPUT="${1:-mldsa_test.c}"
if [[ "$INPUT" == *.c ]]; then
    ELF="${INPUT%.c}.elf"
    echo "[1/5] Compiling $(basename "$INPUT")..."
    "$SCRIPT_DIR/RISCV_compile.sh" "$INPUT" "$ELF" || { echo "Compilation failed"; exit 1; }
else
    ELF="$INPUT"
fi

# Kill any existing OpenOCD
pkill openocd 2>/dev/null || true
sleep 1

# Reprogram FPGA for clean state
echo "[2/5] Reprogramming FPGA..."
/opt/Xilinx/2025.2/Vivado/bin/vivado -nojournal -mode batch -source /tmp/program_fpga.tcl 2>&1 | grep -E "(programmed|ERROR|WARNING)" | head -5

sleep 2

# Start fresh OpenOCD
echo "[3/5] Starting OpenOCD..."
openocd -f "$HOME/cva6/corev_apu/fpga/ariane.cfg" > /tmp/openocd.log 2>&1 &
for i in $(seq 1 30); do nc -z localhost 3333 2>/dev/null && break; sleep 0.5; done
nc -z localhost 3333 2>/dev/null || { echo "OpenOCD failed"; cat /tmp/openocd.log; exit 1; }

# Phase 1: Load and run
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

echo "[4/5] Loading and running..."
"$GDB" -batch -x "$GDB_LOAD" "$ELF" 2>&1 | grep -E "(Loading|Start address|Transfer|Error)" | head -10
rm -f "$GDB_LOAD"

# Wait for stall detection (100000 spins at ~50MHz ≈ 10ms, plus margin)
echo "Waiting for stall detection (~5s)..."
sleep 5

# Phase 2: Read diagnostics
GDB_READ=$(mktemp /tmp/gdb_read_XXXXXX.gdb)
cat > "$GDB_READ" <<'GDBEOF'
set architecture riscv:rv64
set pagination off
set confirm off
set remotetimeout 10
target remote :3333
interrupt

printf "\n=== ACCELERATOR STATE ===\n"
set $status = *(volatile unsigned long long*)0x50000018
set $diag = *(volatile unsigned long long*)0x50000020

printf "STATUS = 0x%016llx\n", $status
printf "  in_empty=%d in_full=%d out_empty=%d out_full=%d\n", $status & 1, ($status >> 1) & 1, ($status >> 2) & 1, ($status >> 3) & 1
printf "  ready_i=%d valid_o=%d busy=%d\n", ($status >> 4) & 1, ($status >> 5) & 1, ($status >> 6) & 1
printf "  push_cnt=%d\n", ($status >> 16) & 0xFFFF

set $cs0 = $diag & 0x1F
printf "\nDIAG = 0x%016llx\n", $diag
printf "  cstate0=%d ", $cs0
if $cs0 == 0
printf "(KG_INIT)"
end
if $cs0 == 1
printf "(KG_HASH_Z)"
end
if $cs0 == 2
printf "(KG_UNLOAD_HASH)"
end
if $cs0 == 3
printf "(KG_SAMPLE_S1)"
end
if $cs0 == 4
printf "(KG_SAMPLE_S2)"
end
if $cs0 == 5
printf "(KG_MULT_AS1)"
end
if $cs0 == 6
printf "(KG_NTTI_T)"
end
if $cs0 == 7
printf "(KG_ADD_T_S2)"
end
if $cs0 == 8
printf "(KG_ENCODE_T0)"
end
if $cs0 == 9
printf "(KG_UNLOAD_TR)"
end
if $cs0 == 10
printf "(KG_ENCODE_T1)"
end
printf "\n"

printf "  cstate1=%d cstate2=%d\n", ($diag >> 5) & 0x1F, ($diag >> 10) & 0x1F
printf "  ctr=%d\n", ($diag >> 27) & 0x7FF
printf "  s2_prereq=%d done_a=%d\n", ($diag >> 52) & 1, ($diag >> 53) & 1
printf "  done_op0=%d start_op0=%d ready_i_enc=%d\n", ($diag >> 55) & 1, ($diag >> 56) & 1, ($diag >> 57) & 1
printf "  addr1_sel_op=%d enc_phase=%d\n", ($diag >> 58) & 0x7, ($diag >> 61) & 1
printf "  mux_ctrl_k=%d done_s=%d\n", ($diag >> 26) & 1, ($diag >> 25) & 1
printf "  sampler_state=%d sample_state=%d sample_ctr=%d\n", ($diag >> 15) & 0x7, ($diag >> 18) & 0x1F, ($diag >> 44) & 0xFF

# 2nd read to check stability
set $diag2 = *(volatile unsigned long long*)0x50000020
printf "\nDIAG(2nd) = 0x%016llx\n", $diag2

# C code diagnostics
printf "\n--- C code vars ---\n"
printf "diag_status_read_idx = %d\n", diag_status_read_idx
printf "diag_stuck_cstate0 = %d\n", diag_stuck_cstate0
printf "diag_stuck_ctr = %d\n", diag_stuck_ctr
printf "diag_stuck_done_op = %d\n", diag_stuck_done_op
printf "diag_stuck_start_op = %d\n", diag_stuck_start_op
printf "diag_stuck_s2_prereq = %d\n", diag_stuck_s2_prereq
printf "diag_stuck_done_a = %d\n", diag_stuck_done_a
printf "diag_stuck_addr1_sel_op = %d\n", diag_stuck_addr1_sel_op
printf "diag_push_cnt_stuck = %d\n", diag_push_cnt_stuck

quit
GDBEOF

echo "[5/5] Reading diagnostics..."
"$GDB" -batch -x "$GDB_READ" "$ELF" 2>&1 | grep -v "^$" | grep -v "Ignoring packet" | grep -v "Traceback" | grep -v "Exception" | grep -v "KeyboardInterrupt" | tail -50

rm -f "$GDB_READ"
echo ""
echo "Done."
