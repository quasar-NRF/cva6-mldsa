#!/bin/bash
# =============================================================================
# ML-DSA-65 KeyGen — STANDALONE accelerator simulation
# =============================================================================
# What this tests:
#   The ML-DSA-65 accelerator (combined_top.v) with NO AXI bridge. The
#   testbench drives the accelerator's streaming interface (valid/ready/data)
#   directly. This isolates accelerator behavior from bridge/AXI concerns.
#
# What gets produced:
#   Public key (PK): 1952 bytes = 244 words
#     Layout: rho (4 words) || t1 (240 words)
#   Secret key (SK): 4032 bytes = 504 words
#     Layout: rho (4) || K (4) || tr (8) || s1 (80) || s2 (96) || t0 (312)
#
# Pass criterion:
#   Output PK and SK match the NIST KeyGen KAT byte-for-byte.
#
# Reference: FIPS 204, Module-Lattice Digital Signature Algorithm.
# =============================================================================
# Usage:
#   ./run.sh                # default: 1 KAT vector
#   ./run.sh 5              # first 5 KAT vectors
# =============================================================================

set -u

NUM_TV="${1:-1}"
HERE="$(cd "$(dirname "$0")" && pwd)"
PHASE_DIR="$(dirname "$HERE")"           # .../sim/mldsa/keygen
PHASE="$(basename "$PHASE_DIR")"          # keygen
MLDSA="/home/quasart1/cva6/corev_apu/fpga/src/ML-DSA-OSH"
SRC="${MLDSA}/ref_combined/src"
SRC_TB="${MLDSA}/ref_combined/src_tb"
COMMON="${MLDSA}/common"
KAT_DIR="${MLDSA}/KAT"

XVLOG=/opt/Xilinx/2025.2/Vivado/bin/xvlog
XVHDL=/opt/Xilinx/2025.2/Vivado/bin/xvhdl
XELAB=/opt/Xilinx/2025.2/Vivado/bin/xelab
XSIM=/opt/Xilinx/2025.2/Vivado/bin/xsim

TB_NAME="tb_keygen_top"
TB_FILE="${HERE}/${TB_NAME}_sim.v"
LOG="${HERE}/run.log"
SIM_RUN_LOG="${HERE}/xsim_output.log"

cd "$HERE"
rm -rf xsim.dir xvhdl.log xvlog.log webtalk* 2>/dev/null

# -----------------------------------------------------------------------------
# Step 1: Generate phase-specific testbench by copying upstream TB and patching
# -----------------------------------------------------------------------------
# Upstream testbenches (in ref_combined/src_tb/) iterate over all security
# levels. We patch:
#   - sec_lvl = 3     (ML-DSA-65, our target)
#   - NUM_TV = N      (default 1 vector for fast iteration)
cp "$SRC_TB/${TB_NAME}.v" "$TB_FILE"
sed -i "s/sec_lvl = 2;/sec_lvl = 3;/" "$TB_FILE"
sed -i "s/sec_lvl = 4;/sec_lvl = 3;/" "$TB_FILE"
sed -i "s/sec_lvl = 5;/sec_lvl = 3;/" "$TB_FILE"
sed -i -E "s/(localparam\s+NUM_TV\s*=\s*)[0-9]+/\1${NUM_TV}/" "$TB_FILE"
# Bound every $readmemh to vector 0 (documents intent — we only consume the
# first KAT vector). XSIM still emits "Too many words" warnings, which the
# tail/grep filter below strips from displayed output.
sed -i -E 's/\$readmemh\(("[^"]+"),\s*([A-Za-z_][A-Za-z0-9_]*)\)/\$readmemh(\1, \2, 0, 0)/g' "$TB_FILE"

# KAT files must be visible from CWD (xsim looks in CWD by default)
ln -sf "${COMMON}/zetas.txt" zetas.txt
for f in "$KAT_DIR"/*.txt; do
  ln -sf "$f" "$(basename $f)"
done

echo "==================================================================="
echo " ML-DSA KeyGen STANDALONE sim (sec_lvl=3, KAT vectors=${NUM_TV})"
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

# -----------------------------------------------------------------------------
# Pass/fail detection: upstream TB prints "testbench done" + WRONG byte counts
# -----------------------------------------------------------------------------
if grep -q "testbench done" "$SIM_RUN_LOG"; then
    WRONG_CNT=$(grep -c "WRONG" "$SIM_RUN_LOG" 2>/dev/null)
    WRONG_CNT=${WRONG_CNT:-0}
    if [ "${WRONG_CNT:-0}" -eq 0 ]; then
        echo "==========================================================="
        echo " RESULT: PASS — KeyGen matches KAT byte-for-byte"
        echo "==========================================================="
        exit 0
    else
        echo "==========================================================="
        echo " RESULT: FAIL — $WRONG_CNT WRONG byte(s)"
        echo "==========================================================="
        exit 1
    fi
else
    echo "==========================================================="
    echo " RESULT: UNKNOWN — sim did not reach 'testbench done'"
    echo "==========================================================="
    exit 1
fi
