# ==================================================
# Giulio Golinelli - golinelli.giulio13@gmail.com
# TUMCREATE QUASAR RESEARCH ENGINEER
# Modified: 2026-06-17
# This file contains modifications vs. the upstream
# CVA6 / ML-DSA-OSH source fork.
# ==================================================

#!/bin/bash
# Full deploy pipeline for ML-DSA FPGA tests:
#   1. Compile C source
#   2. Reprogram FPGA (clean state)
#   3. Start OpenOCD
#   4. Load ELF, run test, wait for completion
#   5. Halt CPU, read result variables
#
# Usage: ./deploy_test.sh <source.c|file.elf> [--wait SECONDS] [--vars var1,var2,...]
#   --wait  : seconds to wait for test completion (default: 60)
#   --vars  : comma-separated result variables to read (default: phase,kg_result,sign_result,sign_out_cnt,verify_result)
#   --no-program : skip FPGA reprogramming (use if already clean)
set -euo pipefail

GDB="/opt/Xilinx/2025.2/gnu/riscv/lin/bin/riscv64-unknown-elf-gdb"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OPENOCD_CFG="$HOME/cva6/corev_apu/fpga/ariane.cfg"
BITSTREAM="$HOME/cva6/corev_apu/fpga/work-fpga/ariane_xilinx.bit"
PROGRAM_TCL="$SCRIPT_DIR/program_fpga.tcl"

# Defaults
WAIT_SECONDS=60
RESULT_VARS="phase,kg_result,sign_result,sign_out_cnt,verify_result"
NO_PROGRAM=0

# Parse args
INPUT=""
while [ $# -gt 0 ]; do
    case "$1" in
        --wait)        WAIT_SECONDS="$2"; shift 2 ;;
        --vars)        RESULT_VARS="$2"; shift 2 ;;
        --no-program)  NO_PROGRAM=1; shift ;;
        -*)            echo "Unknown option: $1" >&2; exit 1 ;;
        *)             INPUT="$1"; shift ;;
    esac
done

[ -z "$INPUT" ] && { echo "Usage: $0 <source.c|file.elf> [--wait N] [--vars v1,v2,...] [--no-program]" >&2; exit 1; }
[ ! -f "$INPUT" ] && { echo "File not found: $INPUT" >&2; exit 1; }

# Step 1: Compile if .c
if [[ "$INPUT" == *.c ]]; then
    ELF="${INPUT%.c}.elf"
    echo "[1/5] Compiling $(basename "$INPUT")..."
    "$SCRIPT_DIR/RISCV_compile.sh" "$INPUT" "$ELF" || { echo "Compilation failed"; exit 1; }
else
    ELF="$INPUT"
fi

# Step 2: Reprogram FPGA
if [ "$NO_PROGRAM" -eq 0 ]; then
    echo "[2/5] Reprogramming FPGA..."
    set +e +o pipefail
    /opt/Xilinx/2025.2/Vivado/bin/vivado -nojournal -mode batch -source "$PROGRAM_TCL" > /tmp/vivado_program.log 2>&1
    VIVADO_RC=$?
    set -e -o pipefail
    if [ "$VIVADO_RC" -ne 0 ]; then
        echo "Vivado program step FAILED (rc=$VIVADO_RC). Last 30 lines:"
        tail -30 /tmp/vivado_program.log
        exit 1
    fi
    if grep -qi "PROGRAMMED" /tmp/vivado_program.log; then
        echo "  FPGA programmed OK"
    else
        echo "  WARNING: Vivado exited 0 but no PROGRAMMED marker. Last 10 lines:"
        tail -10 /tmp/vivado_program.log
    fi
    sleep 2
else
    echo "[2/5] Skipping FPGA reprogram (--no-program)"
fi

# Step 3: Start OpenOCD
echo "[3/5] Starting OpenOCD..."
pkill openocd 2>/dev/null || true
sleep 2
openocd -f "$OPENOCD_CFG" > /tmp/openocd.log 2>&1 &
OPENOCD_PID=$!
sleep 4
# Check if OpenOCD is ready
for i in $(seq 1 20); do
    if grep -q "Listening on port 3333" /tmp/openocd.log 2>/dev/null; then
        break
    fi
    sleep 1
done
grep -q "Listening on port 3333" /tmp/openocd.log 2>/dev/null || { echo "OpenOCD failed to start"; cat /tmp/openocd.log; exit 1; }

# Step 4: Load and run test
GDB_LOAD=$(mktemp /tmp/gdb_deploy_XXXXXX.gdb)
cat > "$GDB_LOAD" <<GDBEOF
set architecture riscv:rv64
set pagination off
set confirm off
set remotetimeout 10
target remote localhost:3333
monitor halt
load
monitor resume
quit
GDBEOF

echo "[4/5] Loading and running test..."
$GDB -batch -x "$GDB_LOAD" "$ELF" 2>&1 | grep -E "(Loading|Start address|Transfer|Error)" | head -5
rm -f "$GDB_LOAD"

echo "  Test running, waiting ${WAIT_SECONDS}s..."
sleep "$WAIT_SECONDS"

# Step 5: Halt and read results
GDB_READ=$(mktemp /tmp/gdb_read_XXXXXX.gdb)
cat > "$GDB_READ" <<'GDBEOF'
set architecture riscv:rv64
set pagination off
set confirm off
set remotetimeout 10
target remote localhost:3333
monitor halt
GDBEOF

# Add variable reads
echo 'printf "\n=== TEST RESULTS ===\n"' >> "$GDB_READ"
IFS=',' read -ra VARS <<< "$RESULT_VARS"
for var in "${VARS[@]}"; do
    echo "printf \"$var = 0x%lx\\n\", (unsigned long)$var" >> "$GDB_READ"
done
echo 'printf "pc = 0x%lx\n\n", (unsigned long)$pc' >> "$GDB_READ"
echo "quit" >> "$GDB_READ"

echo "[5/5] Reading results..."
$GDB -batch -x "$GDB_READ" "$ELF" 2>&1 | grep -v "^$" | grep -v "Ignoring packet" | grep -v "Traceback" | grep -v "Exception" | grep -v "warning:" | grep -v "determining" | grep -v "0x00000000" | tail -20
rm -f "$GDB_READ"

echo ""
echo "Done."
