# ==================================================
# Giulio Golinelli - golinelli.giulio13@gmail.com
# TUMCREATE QUASAR RESEARCH ENGINEER
# Modified: 2026-06-17
# This file contains modifications vs. the upstream
# CVA6 / ML-DSA-OSH source fork.
# ==================================================

#!/bin/bash
# =============================================================================
# ML-DSA-65 KeyGen — BRIDGE simulation (accelerator + AXI bridge)
# =============================================================================
# What this tests:
#   The full memory-mapped peripheral path: an AXI4 master BFM in the
#   testbench drives axi_mldsa_bridge (which converts AXI-Lite to the
#   accelerator's streaming interface). This is exactly what the CVA6 CPU
#   will do at runtime — write input words to DATA_IN, assert CTRL.start,
#   drain DATA_OUT.
#
# Memory map (byte offsets, 64-bit aligned):
#   0x00 CTRL     [WO]  [0]=start  [2:1]=mode  [5:3]=sec_lvl
#   0x08 DATA_IN  [WO]  push 64-bit word to input FIFO
#   0x10 DATA_OUT [RO]  pop 64-bit word from output FIFO
#   0x18 STATUS   [RO]  [0]=in_empty [2]=out_empty [6]=busy
#   0x20 DIAG     [RO]  accelerator internal state
#
# KeyGen CTRL value: (sec_lvl=3 << 3) | (mode=0 << 1) | start=1 = 0x19
#
# What gets produced:
#   PK (244 words) and SK (504 words). Total 744 words drained from DATA_OUT.
#
# Pass criterion:
#   PK and SK match the NIST KeyGen KAT byte-for-byte.
# =============================================================================
# Usage:
#   ./run.sh
# =============================================================================

set -u

# TUMCREATE: SEC_LVL is arg 1 (default 3). Valid: 2 (ML-DSA-44), 3 (ML-DSA-65), 5 (ML-DSA-87).
# Forwarded to testbench via -DSEC_LVL=X so tb_keygen_bridge.sv can use \`SEC_LVL.
SEC_LVL="${1:-3}"
case "$SEC_LVL" in
  2) KAT_SUF="44" ;;
  3) KAT_SUF="65" ;;
  5) KAT_SUF="87" ;;
  *) echo "Invalid sec_lvl=$SEC_LVL (must be 2|3|5)"; exit 2 ;;
esac
HERE="$(cd "$(dirname "$0")" && pwd)"
PHASE_DIR="$(dirname "$HERE")"
PHASE="$(basename "$PHASE_DIR")"          # keygen
MLDSA="/home/quasart1/cva6/corev_apu/fpga/src/ML-DSA-OSH"
SRC="${MLDSA}/ref_combined/src"
COMMON="${MLDSA}/common"
KAT_DIR="${MLDSA}/KAT"
BRIDGE_DIR="/home/quasart1/cva6/corev_apu/fpga/src"

PULP_AXI="/home/quasart1/cva6/vendor/pulp-platform/axi/src"
PULP_AXI_INC="/home/quasart1/cva6/vendor/pulp-platform/axi/include"
PULP_COMMON="/home/quasart1/cva6/vendor/pulp-platform/common_cells/src"
PULP_COMMON_INC="/home/quasart1/cva6/vendor/pulp-platform/common_cells/include"

XVLOG=/opt/Xilinx/2025.2/Vivado/bin/xvlog
XVHDL=/opt/Xilinx/2025.2/Vivado/bin/xvhdl
XELAB=/opt/Xilinx/2025.2/Vivado/bin/xelab
XSIM=/opt/Xilinx/2025.2/Vivado/bin/xsim

TB_NAME="tb_keygen_bridge"
TB_FILE="${HERE}/${TB_NAME}.sv"
LOG="${HERE}/run.log"
SIM_RUN_LOG="${HERE}/xsim_output.log"

cd "$HERE"
rm -rf xsim.dir xvhdl.log xvlog.log webtalk* 2>/dev/null

# KAT files visible from CWD
ln -sf "${COMMON}/zetas.txt" zetas.txt
for f in "$KAT_DIR"/*.txt; do
  ln -sf "$f" "$(basename $f)"
done

echo "==================================================================="
echo " ML-DSA KeyGen BRIDGE sim (sec_lvl=${SEC_LVL} / ML-DSA-${KAT_SUF}, AXI BFM + axi_mldsa_bridge)"
echo "==================================================================="

echo "[1/7] Compile mldsa_params.v..." | tee "$LOG"
$XVLOG --relax "$COMMON/mldsa_params.v" 2>&1 \
    | grep -v "XSIM 43-3431" | grep -iE "ERROR[:[]" | head -3 | tee -a "$LOG"

echo "[2/7] Compile VHDL Keccak..." | tee -a "$LOG"
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

echo "[3/7] Compile Verilog accelerator sources..." | tee -a "$LOG"
R=$($XVLOG --relax -i "$COMMON" -i "$SRC" $SRC/*.v 2>&1 \
    | grep -v "XSIM 43-3431" | grep -iE "ERROR[:[]" | head -10)
if [ -n "$R" ]; then
    echo "  Verilog FAIL:" | tee -a "$LOG"; echo "$R" | tee -a "$LOG"; exit 2
fi
echo "  Verilog OK" | tee -a "$LOG"

echo "[4/7] Compile pulp-platform AXI pkg + intf..." | tee -a "$LOG"
R=$($XVLOG --sv --relax -d XSIM -d VERILATOR -i "$PULP_AXI_INC" \
    "$PULP_AXI/axi_pkg.sv" "$PULP_AXI/axi_intf.sv" 2>&1 \
    | grep -v "XSIM 43-3431" | grep -iE "ERROR[:[]" | head -5)
if [ -n "$R" ]; then
    echo "  pulp intf FAIL:" | tee -a "$LOG"; echo "$R" | tee -a "$LOG"; exit 2
fi
echo "  pulp intf OK" | tee -a "$LOG"

echo "[5/7] Compile pulp axi_to_axi_lite + axi_lite_regs + deps..." | tee -a "$LOG"
# cf_math_pkg is a SV package used by axi_lite_regs — must be compiled first,
# in its own xvlog call, otherwise xvlog analyzes out-of-order.
R=$($XVLOG --sv --relax -d XSIM -d VERILATOR "$PULP_COMMON/cf_math_pkg.sv" 2>&1 \
    | grep -v "XSIM 43-3431" | grep -iE "ERROR[:[]" | head -5)
if [ -n "$R" ]; then
    echo "  cf_math_pkg FAIL:" | tee -a "$LOG"; echo "$R" | tee -a "$LOG"; exit 2
fi
PULP_AXI_SRCS=(
    "$PULP_AXI/axi_multicut.sv"   "$PULP_AXI/axi_cut.sv"
    "$PULP_AXI/axi_join.sv"       "$PULP_AXI/axi_delayer.sv"
    "$PULP_AXI/axi_to_axi_lite.sv" "$PULP_AXI/axi_burst_splitter.sv"
    "$PULP_AXI/axi_id_prepend.sv" "$PULP_AXI/axi_atop_filter.sv"
    "$PULP_AXI/axi_err_slv.sv"    "$PULP_AXI/axi_mux.sv"
    "$PULP_AXI/axi_demux.sv"      "$PULP_AXI/axi_xbar.sv"
    "$PULP_AXI/axi_lite_regs.sv"
)
PULP_CC_SRCS=(
    "$PULP_COMMON/fifo_v3.sv"        "$PULP_COMMON/lfsr.sv"
    "$PULP_COMMON/lfsr_8bit.sv"      "$PULP_COMMON/stream_arbiter.sv"
    "$PULP_COMMON/stream_arbiter_flushable.sv" "$PULP_COMMON/stream_mux.sv"
    "$PULP_COMMON/stream_demux.sv"   "$PULP_COMMON/lzc.sv"
    "$PULP_COMMON/rr_arb_tree.sv"    "$PULP_COMMON/shift_reg.sv"
    "$PULP_COMMON/unread.sv"         "$PULP_COMMON/popcount.sv"
    "$PULP_COMMON/exp_backoff.sv"    "$PULP_COMMON/counter.sv"
    "$PULP_COMMON/delta_counter.sv"  "$PULP_COMMON/id_queue.sv"
    "$PULP_COMMON/onehot_to_bin.sv"  "$PULP_COMMON/cdc_2phase.sv"
    "$PULP_COMMON/spill_register_flushable.sv" "$PULP_COMMON/spill_register.sv"
    "$PULP_COMMON/stream_register.sv" "$PULP_COMMON/addr_decode.sv"
    "$PULP_COMMON/rstgen.sv"         "$PULP_COMMON/rstgen_bypass.sv"
    "$PULP_COMMON/sync.sv"           "$PULP_COMMON/sync_wedge.sv"
    "$PULP_COMMON/edge_detect.sv"
    "$PULP_COMMON/deprecated/fifo_v1.sv" "$PULP_COMMON/deprecated/fifo_v2.sv"
)
R=$($XVLOG --sv --relax -d XSIM -d VERILATOR -i "$PULP_AXI_INC" -i "$PULP_COMMON_INC" \
    "${PULP_CC_SRCS[@]}" "${PULP_AXI_SRCS[@]}" 2>&1 \
    | grep -v "XSIM 43-3431" | grep -iE "ERROR[:[]" | head -15)
if [ -n "$R" ]; then
    echo "  pulp axi_lite FAIL:" | tee -a "$LOG"; echo "$R" | tee -a "$LOG"; exit 2
fi
echo "  pulp axi_lite OK" | tee -a "$LOG"

echo "[6/7] Compile bridge + testbench..." | tee -a "$LOG"
# TUMCREATE: pass -d SEC_LVL so the bridge TB can use \`SEC_LVL for CTRL value, KAT suffix, etc.
R=$($XVLOG --sv --relax -d XSIM -d VERILATOR -d SEC_LVL=${SEC_LVL} -i "$PULP_AXI_INC" -i "$PULP_COMMON_INC" \
    -i "$COMMON" -i "$SRC" \
    "$BRIDGE_DIR/axi_mldsa_bridge.sv" "$TB_FILE" 2>&1 \
    | grep -v "XSIM 43-3431" | grep -iE "ERROR[:[]" | head -10)
if [ -n "$R" ]; then
    echo "  Bridge/TB FAIL:" | tee -a "$LOG"; echo "$R" | tee -a "$LOG"; exit 2
fi
echo "  Bridge/TB OK" | tee -a "$LOG"

echo "[7/7] Elaborate + run sim (15min timeout)..." | tee -a "$LOG"
$XELAB --relax -d XSIM -d VERILATOR -d SEC_LVL=${SEC_LVL} "work.${TB_NAME}" -snapshot "sim_bridge_${PHASE}" 2>&1 \
    | grep -v "XSIM 43-3431" | grep -iE "ERROR[:[]" | head -10 | tee -a "$LOG"

timeout 900 $XSIM "sim_bridge_${PHASE}" -R > "$SIM_RUN_LOG" 2>&1
XSIM_RC=$?

if [ $XSIM_RC -eq 124 ]; then
    echo "  SIM TIMEOUT (15 min) — likely hung" | tee -a "$LOG"; exit 1
fi

echo "" | tee -a "$LOG"
echo "=== SIM OUTPUT (tail 60) ===" | tee -a "$LOG"
tail -80 "$SIM_RUN_LOG" \
    | grep -vE "^\s*\*|^WARNING: Too many words|^source xsim|^# xsim|^Time resolution|^run -all|^Time \(s\)|^exit$|^INFO:" \
    | tee -a "$LOG"
echo "" | tee -a "$LOG"

if grep -q "testbench done - PASS" "$SIM_RUN_LOG"; then
    echo "==========================================================="
    echo " RESULT: PASS — KeyGen through bridge matches KAT byte-for-byte"
    echo "==========================================================="
    exit 0
elif grep -q "testbench done - FAIL" "$SIM_RUN_LOG"; then
    echo "==========================================================="
    echo " RESULT: FAIL — PK/SK mismatch (see sim output)"
    echo "==========================================================="
    exit 1
elif grep -q "watchdog timeout" "$SIM_RUN_LOG"; then
    echo "==========================================================="
    echo " RESULT: FAIL — watchdog timeout (sim hung)"
    echo "==========================================================="
    exit 1
else
    echo "==========================================================="
    echo " RESULT: UNKNOWN — check $SIM_RUN_LOG"
    echo "==========================================================="
    exit 1
fi
