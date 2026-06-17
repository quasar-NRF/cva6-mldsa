# ==================================================
# Giulio Golinelli - golinelli.giulio13@gmail.com
# TUMCREATE QUASAR RESEARCH ENGINEER
# Modified: 2026-06-17
# This file contains modifications vs. the upstream
# CVA6 / ML-DSA-OSH source fork.
# ==================================================

#!/bin/bash
# Run ML-DSA test N times and capture results for consistency checking.
# Usage: ./consistency_test.sh <bitstream.bit> <test.c|test.elf> <num_runs> [--no-program]
set -uo pipefail

GDB="/opt/Xilinx/2025.2/gnu/riscv/lin/bin/riscv64-unknown-elf-gdb"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OPENOCD_CFG="$HOME/cva6/corev_apu/fpga/ariane.cfg"
PROGRAM_TCL="/tmp/program_fpga.tcl"

BITSTREAM=""
INPUT=""
RUN_COUNT=""
NO_PROGRAM=0

while [ $# -gt 0 ]; do
    case "$1" in
        --no-program) NO_PROGRAM=1; shift ;;
        -*) echo "Unknown option: $1" >&2; exit 1 ;;
        *)
            if [ -z "$BITSTREAM" ]; then BITSTREAM="$1"
            elif [ -z "$INPUT" ]; then INPUT="$1"
            elif [ -z "$RUN_COUNT" ]; then RUN_COUNT="$1"
            else echo "Too many args: $1" >&2; exit 1
            fi
            shift ;;
    esac
done
NUM_RUNS=${RUN_COUNT:-3}

[ -z "$BITSTREAM" ] && { echo "Usage: $0 <bitstream.bit> <test.c|test.elf> [num_runs] [--no-program]" >&2; exit 1; }
[ -z "$INPUT" ] && INPUT="$SCRIPT_DIR/mldsa_full_test.c"
[ ! -f "$BITSTREAM" ] && { echo "Bitstream not found: $BITSTREAM"; exit 1; }

# Compile if .c
if [[ "$INPUT" == *.c ]]; then
    ELF="${INPUT%.c}.elf"
    echo "[PREP] Compiling $(basename "$INPUT")..."
    "$SCRIPT_DIR/RISCV_compile.sh" "$INPUT" "$ELF" || { echo "Compilation failed"; exit 1; }
else
    ELF="$INPUT"
fi

RESULT_VARS="phase,kg_result,sign_result,sign_out_cnt,verify_result,sign_step,sign_diag_pre,sign_diag_mid,sign_diag_post_input,sign_diag,sign_status"

echo ""
echo "=========================================="
echo "  Consistency Test: $(basename "$BITSTREAM")"
echo "  Test: $(basename "$INPUT")"
echo "  Runs: $NUM_RUNS"
echo "=========================================="
echo ""

ALL_PASS=true

for run in $(seq 1 "$NUM_RUNS"); do
    echo "--- Run $run/$NUM_RUNS ($(date +%H:%M:%S)) ---"

    # Program FPGA (first run always programs, subsequent runs reprogram for clean state)
    if [ "$NO_PROGRAM" -eq 0 ]; then
        # Update the bitstream path in the program TCL
        cat > "$PROGRAM_TCL" <<TCLEOF
open_hw_manager
connect_hw_server -url localhost:3121 -allow_non_jtag
refresh_hw_server
set targets [get_hw_targets]
puts "Available targets: \$targets"
open_hw_target [lindex \$targets 0]
current_hw_device [get_hw_devices xc7k325t_0]
set_property PROGRAM.FILE {$BITSTREAM} [get_hw_devices xc7k325t_0]
program_hw_devices [get_hw_devices xc7k325t_0]
refresh_hw_device [lindex [get_hw_devices xc7k325t_0] 0]
puts "FPGA programmed successfully!"
TCLEOF
        if ! /opt/Xilinx/2025.2/Vivado/bin/vivado -nojournal -mode batch -source "$PROGRAM_TCL" 2>&1 | grep -E "(programmed|ERROR|FAIL)" | head -3; then
            echo "  WARNING: Vivado programming may have had issues"
        fi
        sleep 2
    fi

    # Start OpenOCD
    pkill openocd 2>/dev/null || true
    sleep 2
    openocd -f "$OPENOCD_CFG" > /tmp/openocd_consistency.log 2>&1 &
    OPENOCD_PID=$!
    sleep 4
    for i in $(seq 1 20); do
        grep -q "Listening on port 3333" /tmp/openocd_consistency.log 2>/dev/null && break
        sleep 1
    done
    if ! grep -q "Listening on port 3333" /tmp/openocd_consistency.log 2>/dev/null; then
        echo "  OpenOCD FAILED to start"
        kill $OPENOCD_PID 2>/dev/null || true
        echo "  RESULT: OPENOCD_FAIL"
        ALL_PASS=false
        continue
    fi

    # Load and run
    GDB_LOAD=$(mktemp /tmp/gdb_consistency_load_XXXXXX.gdb)
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
    $GDB -batch -x "$GDB_LOAD" "$ELF" 2>&1 | grep -E "(Loading|Error|Transfer)" | head -3
    rm -f "$GDB_LOAD"

    # Wait for test completion (KeyGen ~3s, Sign ~10s, Verify ~15s, use 60s total)
    sleep 60

    # Halt and read results
    GDB_READ=$(mktemp /tmp/gdb_consistency_read_XXXXXX.gdb)
    cat > "$GDB_READ" <<'GDBEOF'
set architecture riscv:rv64
set pagination off
set confirm off
set remotetimeout 10
target remote localhost:3333
monitor halt
printf "\n=== TEST RESULTS ===\n"
GDBEOF
    IFS=',' read -ra VARS <<< "$RESULT_VARS"
    for var in "${VARS[@]}"; do
        echo "printf \"$var = 0x%lx\\n\", (unsigned long)$var" >> "$GDB_READ"
    done
    echo 'printf "pc = 0x%lx\n", (unsigned long)$pc' >> "$GDB_READ"
    echo "quit" >> "$GDB_READ"

    RESULTS=$($GDB -batch -x "$GDB_READ" "$ELF" 2>&1 | grep -v "^$" | grep -v "Ignoring packet" | grep -v "Traceback" | grep -v "Exception" | grep -v "warning:" | grep -v "determining" | grep -v "0x00000000" | tail -20)
    rm -f "$GDB_READ"

    echo "$RESULTS" | grep -E "^(===|phase|kg_result|sign_result|sign_out_cnt|verify_result|sign_step|pc)"

    # Parse key results
    PHASE=$(echo "$RESULTS" | grep "^phase = " | awk '{print $NF}')
    KG=$(echo "$RESULTS" | grep "^kg_result = " | awk '{print $NF}')
    SIGN=$(echo "$RESULTS" | grep "^sign_result = " | awk '{print $NF}')
    SIGN_OUT=$(echo "$RESULTS" | grep "^sign_out_cnt = " | awk '{print $NF}')

    # Evaluate
    # KeyGen success: kg_result = 0x2e8 (744)
    # Sign success: sign_result = 0x19e (414) and sign_out_cnt = 0x19e
    if [ "$KG" = "0x2e8" ]; then
        echo "  KeyGen: PASS ($KG = 744 words)"
    else
        echo "  KeyGen: FAIL ($KG)"
        ALL_PASS=false
    fi

    if [ "$SIGN" = "0x19e" ] && [ "$SIGN_OUT" = "0x19e" ]; then
        echo "  Sign:  PASS ($SIGN = 414 words)"
    else
        echo "  Sign:  FAIL (result=$SIGN, out_cnt=$SIGN_OUT)"
        ALL_PASS=false
    fi

    # Cleanup OpenOCD
    kill $OPENOCD_PID 2>/dev/null || true
    pkill openocd 2>/dev/null || true
    sleep 2

    echo ""
done

echo "=========================================="
if $ALL_PASS; then
    echo "  ALL $NUM_RUNS RUNS PASSED KeyGen+Sign"
else
    echo "  SOME RUNS FAILED - NOT CONSISTENT"
fi
echo "=========================================="
