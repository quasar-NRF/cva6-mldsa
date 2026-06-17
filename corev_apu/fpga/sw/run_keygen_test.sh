#!/bin/bash
# Complete KeyGen test: program FPGA, load firmware, run, read diagnostics
set -euo pipefail

GDB="/opt/riscv/bin/riscv-none-elf-gdb"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ELF="${1:-$SCRIPT_DIR/mldsa_keygen_diag.elf}"

echo "[1/4] Programming FPGA..."
pkill openocd 2>/dev/null || true
sleep 1
/opt/Xilinx/2025.2/Vivado/bin/vivado -nojournal -mode batch -source /tmp/program_fpga.tcl 2>&1 | grep -E "program_hw_devices|End of startup" | tail -2
sleep 2

echo "[2/4] Starting OpenOCD..."
openocd -f "$HOME/cva6/corev_apu/fpga/ariane.cfg" > /tmp/openocd.log 2>&1 &
for i in $(seq 1 30); do nc -z localhost 3333 2>/dev/null && break; sleep 0.5; done
nc -z localhost 3333 || { echo "OpenOCD failed"; exit 1; }

echo "[3/4] Loading and running..."
GDB_LOAD=$(mktemp)
cat > "$GDB_LOAD" <<'EOF'
set architecture riscv:rv64
set pagination off
set confirm off
set remotetimeout 10
target remote :3333
monitor reset halt
load
monitor resume
quit
EOF
$GDB -batch -x "$GDB_LOAD" "$ELF" 2>&1 | grep -E "Loading|Start address|Transfer" | head -5
rm -f "$GDB_LOAD"
sleep 5

echo "[4/4] Reading diagnostics..."
GDB_READ=$(mktemp)
cat > "$GDB_READ" <<'EOF'
set architecture riscv:rv64
set pagination off
set confirm off
set remotetimeout 10
target remote :3333
interrupt
printf "\n=== RESULT: kg_result = 0x%llx ===\n", kg_result
set $d = *(volatile unsigned long long*)0x50000020
set $owt = ((($d >> 10) & 0x1F) << 5) | (($d >> 5) & 0x1F)
set $t1 = ($d >> 15) & 0x3FF
set $t0 = ($d >> 25) & 0x3FF
set $tr = ($d >> 35) & 0xF
printf "FINAL: owt=%d t1=%d(240) t0=%d(312) tr=%d(8) sticky_t0=%d sticky_tr=%d\n", $owt, $t1, $t0, $tr, ($d >> 55) & 1, ($d >> 56) & 1
if $owt == 744
  printf "*** KEYGEN PASS: 744/744 ***\n"
else
  printf "*** KEYGEN FAIL: %d/744 (missing %d) ***\n", $owt, 744 - $owt
end
quit
EOF
$GDB -batch -x "$GDB_READ" "$ELF" 2>&1 | grep -v "^$" | grep -v "Ignoring" | grep -v "Traceback" | grep -v "Exception" | grep -v "Keyboard" | grep -v "Warning"
rm -f "$GDB_READ"
echo "Done."
