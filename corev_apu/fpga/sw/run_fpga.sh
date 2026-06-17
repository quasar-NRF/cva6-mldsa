# ==================================================
# Giulio Golinelli - golinelli.giulio13@gmail.com
# TUMCREATE QUASAR RESEARCH ENGINEER
# Modified: 2026-06-17
# This file contains modifications vs. the upstream
# CVA6 / ML-DSA-OSH source fork.
# ==================================================

#!/bin/bash
# Compile and run a RISC-V program on the Genesys2 FPGA via OpenOCD + GDB.
# Usage: ./run_fpga.sh <source.c | file.elf> [--debug] [--keep-openocd] [--watch <var> ...]
set -euo pipefail

OPENOCD_CFG="$HOME/cva6/corev_apu/fpga/ariane.cfg"
GDB="/opt/riscv/bin/riscv-none-elf-gdb"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OPENOCD_PID=""
LAUNCHED_OPENOCD=0

cleanup() {
    if [ "$LAUNCHED_OPENOCD" -eq 1 ] && [ -n "$OPENOCD_PID" ]; then
        kill "$OPENOCD_PID" 2>/dev/null || true
        wait "$OPENOCD_PID" 2>/dev/null || true
    fi
}
trap cleanup EXIT

die() { echo "ERROR: $*" >&2; exit 1; }

# --- Parse args ---
INPUT=""
DEBUG=0
KEEP_OPENOCD=0
WATCH_VARS=()

while [ $# -gt 0 ]; do
    case "$1" in
        --debug)         DEBUG=1; shift ;;
        --keep-openocd)  KEEP_OPENOCD=1; shift ;;
        --watch)         WATCH_VARS+=("$2"); shift 2 ;;
        -*)              die "Unknown option: $1" ;;
        *)               INPUT="$1"; shift ;;
    esac
done
[ -z "$INPUT" ] && die "Usage: $(basename "$0") <source.c|file.elf> [--debug] [--keep-openocd] [--watch <var>]"
[ ! -f "$INPUT" ] && die "File not found: $INPUT"

# --- Compile if .c ---
if [[ "$INPUT" == *.c ]]; then
    ELF="${INPUT%.c}.elf"
    echo "[1/3] Compiling $(basename "$INPUT")..."
    "$SCRIPT_DIR/RISCV_compile.sh" "$INPUT" "$ELF" || die "Compilation failed"
else
    ELF="$INPUT"
fi

# --- Start OpenOCD if needed ---
if ss -tlnp 2>/dev/null | grep -q ':3333\b' || nc -z localhost 3333 2>/dev/null; then
    echo "[2/3] OpenOCD already running on port 3333"
    KEEP_OPENOCD=1
else
    echo "[2/3] Starting OpenOCD..."
    openocd -f "$OPENOCD_CFG" > /dev/null 2>&1 &
    OPENOCD_PID=$!
    LAUNCHED_OPENOCD=1
    # Wait for GDB server to be ready
    for i in $(seq 1 30); do
        nc -z localhost 3333 2>/dev/null && break
        sleep 0.5
    done
    nc -z localhost 3333 2>/dev/null || die "OpenOCD did not start (timeout 15s)"
fi

# --- Generate GDB script ---
GDB_SCRIPT=$(mktemp /tmp/run_fpga_XXXXXX.gdb)
cat > "$GDB_SCRIPT" <<'GDBEOF'
set architecture riscv:rv64
set pagination off
set confirm off
set print elements 50
target remote localhost:3333
load
delete
GDBEOF

echo "break main" >> "$GDB_SCRIPT"
echo "continue" >> "$GDB_SCRIPT"
echo "" >> "$GDB_SCRIPT"

if [ "$DEBUG" -eq 1 ]; then
    echo "[3/3] Launching interactive GDB (at main, type 'c' to run)..."
    "$GDB" -x "$GDB_SCRIPT" "$ELF"
else
    # Print watched variables at main
    for var in "${WATCH_VARS[@]+"${WATCH_VARS[@]}"}"; do
        echo "printf \"$var = 0x%lx\\n\", (unsigned long)$var" >> "$GDB_SCRIPT"
    done
    echo "quit" >> "$GDB_SCRIPT"

    echo "[3/3] Running $(basename "$ELF") on FPGA..."
    echo ""
    "$GDB" -batch -x "$GDB_SCRIPT" "$ELF" 2>&1 | grep -v "^$" | tail -20
fi

rm -f "$GDB_SCRIPT"
echo ""
echo "Done."
