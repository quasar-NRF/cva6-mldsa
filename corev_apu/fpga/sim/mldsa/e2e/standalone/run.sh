# ==================================================
# Giulio Golinelli - golinelli.giulio13@gmail.com
# TUMCREATE QUASAR RESEARCH ENGINEER
# Modified: 2026-06-17
# This file contains modifications vs. the upstream
# CVA6 / ML-DSA-OSH source fork.
# ==================================================

#!/bin/bash
# =============================================================================
# ML-DSA-65 End-to-End — STANDALONE accelerator simulation
# =============================================================================
# What this tests:
#   The full KeyGen → Sign → Verify pipeline on the accelerator alone (no AXI
#   bridge). The testbench:
#     1. Runs KeyGen from a KAT seed → captures PK + SK
#     2. Runs Sign using the captured SK + a KAT message → captures signature
#     3. Runs Verify using the captured PK + signature + message → reads fail bit
#
# What gets produced (chained):
#   PK (244 words) + SK (504 words)  →  from KeyGen
#   Signature (414 words)            →  from Sign
#   Fail bit (1 word)                →  from Verify
#
# Pass criterion:
#   Verify fail bit = 0 (signature accepted).
#
# Why this matters:
#   The standalone per-phase tests validate each phase against the NIST KAT.
#   This chained test validates that the phases compose correctly with REAL
#   outputs from each phase as inputs to the next — no pre-baked signatures.
# =============================================================================
# Usage:
#   ./run.sh
# =============================================================================

set -u

# TUMCREATE: NUM_TV is arg 1 (ignored for e2e — always uses vector 0),
# SEC_LVL is arg 2 (default 3 for backward compat).
# Valid SEC_LVL: 2 (ML-DSA-44), 3 (ML-DSA-65), 5 (ML-DSA-87).
NUM_TV="${1:-1}"
SEC_LVL="${2:-3}"
case "$SEC_LVL" in
  2) KAT_SUF="44" ;;
  3) KAT_SUF="65" ;;
  5) KAT_SUF="87" ;;
  *) echo "Invalid sec_lvl=$SEC_LVL (must be 2|3|5)"; exit 2 ;;
esac
HERE="$(cd "$(dirname "$0")" && pwd)"
PHASE_DIR="$(dirname "$HERE")"
PHASE="$(basename "$PHASE_DIR")"          # e2e
MLDSA="/home/quasart1/cva6/corev_apu/fpga/src/ML-DSA-OSH"
SRC="${MLDSA}/ref_combined/src"
COMMON="${MLDSA}/common"
KAT_DIR="${MLDSA}/KAT"

XVLOG=/opt/Xilinx/2025.2/Vivado/bin/xvlog
XVHDL=/opt/Xilinx/2025.2/Vivado/bin/xvhdl
XELAB=/opt/Xilinx/2025.2/Vivado/bin/xelab
XSIM=/opt/Xilinx/2025.2/Vivado/bin/xsim

TB_NAME="tb_e2e_standalone"
TB_FILE="${HERE}/${TB_NAME}.v"
LOG="${HERE}/run.log"
SIM_RUN_LOG="${HERE}/xsim_output.log"

cd "$HERE"
rm -rf xsim.dir xvhdl.log xvlog.log webtalk* 2>/dev/null

# TUMCREATE: patch tb_e2e_standalone.v to use the requested SEC_LVL.
# - Replace sec_lvl = 3'd3 with 3'd${SEC_LVL}
# - Replace all _65.txt references with _${KAT_SUF}.txt
cp "${HERE}/${TB_NAME}.v" "${TB_FILE}.patched"
sed -i "s/sec_lvl = 3'd3;/sec_lvl = 3'd${SEC_LVL};/" "${TB_FILE}.patched"
sed -i "s/_65\\.txt/_${KAT_SUF}.txt/g" "${TB_FILE}.patched"
TB_FILE="${TB_FILE}.patched"

ln -sf "${COMMON}/zetas.txt" zetas.txt
for f in "$KAT_DIR"/*.txt; do
  ln -sf "$f" "$(basename $f)"
done

echo "==================================================================="
echo " ML-DSA End-to-End STANDALONE sim (sec_lvl=${SEC_LVL} / ML-DSA-${KAT_SUF}, KeyGen→Sign→Verify)"
echo "==================================================================="
echo "[1/5] Compile mldsa_params.v..." | tee "$LOG"
$XVLOG --relax "$COMMON/mldsa_params.v" 2>&1 \
    | grep -v "XSIM 43-3431" | grep -iE "ERROR[:[]" | head -3 | tee -a "$LOG"

echo "[2/5] Compile VHDL Keccak (dependency order)..." | tee -a "$LOG"
VHDL_FILES=(
    keccak_pkg sha3_pkg countern regn sr_reg piso sipo
    keccak_cons keccak_bytepad keccak_round sha3_fsm3
    keccak_fsm1 keccak_fsm2 keccak_datapath keccak_control keccak_top
)
for name in "${VHDL_FILES[@]}"; do
    R=$($XVHDL "$SRC/${name}.vhd" 2>&1 \
        | grep -v "XSIM 43-3431" | grep -iE "ERROR[:[]" | head -2)
    if [ -n "$R" ]; then
        echo "  FAIL ${name}.vhd:" | tee -a "$LOG"; echo "$R" | tee -a "$LOG"; exit 2
    fi
done
echo "  VHDL OK" | tee -a "$LOG"

echo "[3/5] Compile Verilog accelerator sources..." | tee -a "$LOG"
R=$($XVLOG --relax -i "$COMMON" -i "$SRC" $SRC/*.v 2>&1 \
    | grep -v "XSIM 43-3431" | grep -iE "ERROR[:[]" | head -10)
if [ -n "$R" ]; then
    echo "  Verilog FAIL:" | tee -a "$LOG"; echo "$R" | tee -a "$LOG"; exit 2
fi
echo "  Verilog OK" | tee -a "$LOG"

echo "[4/5] Compile testbench ${TB_NAME}..." | tee -a "$LOG"
R=$($XVLOG --relax -i "$COMMON" -i "$SRC" "$TB_FILE" 2>&1 \
    | grep -v "XSIM 43-3431" | grep -iE "ERROR[:[]" | head -5)
if [ -n "$R" ]; then
    echo "  TB FAIL:" | tee -a "$LOG"; echo "$R" | tee -a "$LOG"; exit 2
fi
echo "  TB OK" | tee -a "$LOG"

echo "[5/5] Elaborate + run sim (10min timeout)..." | tee -a "$LOG"
$XELAB --relax "work.${TB_NAME}" -snapshot "sim_${PHASE}" 2>&1 \
    | grep -v "XSIM 43-3431" | grep -iE "ERROR[:[]" | head -5 | tee -a "$LOG"

timeout 600 $XSIM "sim_${PHASE}" -R > "$SIM_RUN_LOG" 2>&1
XSIM_RC=$?

if [ $XSIM_RC -eq 124 ]; then
    echo "  SIM TIMEOUT — likely hung" | tee -a "$LOG"
    exit 1
fi

echo "" | tee -a "$LOG"
echo "=== SIM OUTPUT (tail 50) ===" | tee -a "$LOG"
tail -80 "$SIM_RUN_LOG" \
    | grep -vE "^\s*\*|^WARNING: Too many words|^source xsim|^# xsim|^Time resolution|^run -all|^Time \(s\)|^exit$|^INFO:" \
    | tee -a "$LOG"
echo "" | tee -a "$LOG"

if grep -q "testbench done - PASS" "$SIM_RUN_LOG"; then
    echo "==========================================================="
    echo " RESULT: PASS — chained KeyGen→Sign→Verify accepted the signature"
    echo "==========================================================="
    exit 0
elif grep -q "testbench done - FAIL" "$SIM_RUN_LOG"; then
    echo "==========================================================="
    echo " RESULT: FAIL — Verify rejected the chained signature"
    echo "==========================================================="
    exit 1
else
    echo "==========================================================="
    echo " RESULT: UNKNOWN — sim did not reach 'testbench done'"
    echo "==========================================================="
    exit 1
fi
