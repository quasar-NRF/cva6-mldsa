#!/bin/bash
# =============================================================================
# ML-DSA-65 Verify — BRIDGE simulation (accelerator + AXI bridge)
# =============================================================================
# What this tests:
#   The full memory-mapped peripheral path for Verify: an AXI4 master BFM
#   drives axi_mldsa_bridge, which feeds the accelerator. This is exactly
#   what the CVA6 CPU does when checking a signature at runtime.
#
# Memory map: see keygen/bridge/run.sh header.
# Verify CTRL value: (sec_lvl=3 << 3) | (mode=1 << 1) | start=1 = 0x1B
#
# Verify input word sequence (sec_lvl=3):
#   1. PK rho       : 4 words   (32B)
#   2. c_tilde      : 6 words   (48B)
#   3. z            : 400 words (3200B)
#   4. PK t1        : 240 words (1920B)
#   5. mlen+ctxlen  : 1 word
#   6. message_fmtd : ceil((2 + ctxlen + mlen) / 8) words
#   7. h            : 8 words   (61B, last padded)
#
# Verify output: 1 word. Bit 0 is the fail flag.
#   0 = signature VALID
#   1 = signature INVALID
#
# Pass criterion:
#   Output fail bit matches the NIST SigVer KAT expected result.
# =============================================================================
# Usage:
#   ./run.sh
# =============================================================================

set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
PHASE_DIR="$(dirname "$HERE")"
PHASE="$(basename "$PHASE_DIR")"          # verify
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

TB_NAME="tb_verify_bridge"
TB_FILE="${HERE}/${TB_NAME}.sv"
LOG="${HERE}/run.log"
SIM_RUN_LOG="${HERE}/xsim_output.log"

cd "$HERE"
rm -rf xsim.dir xvhdl.log xvlog.log webtalk* 2>/dev/null

ln -sf "${COMMON}/zetas.txt" zetas.txt
for f in "$KAT_DIR"/*.txt; do
  ln -sf "$f" "$(basename $f)"
done

echo "==================================================================="
echo " ML-DSA Verify BRIDGE sim (sec_lvl=3, AXI BFM + axi_mldsa_bridge)"
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
R=$($XVLOG --sv --relax -d XSIM -d VERILATOR -i "$PULP_AXI_INC" -i "$PULP_COMMON_INC" \
    -i "$COMMON" -i "$SRC" \
    "$BRIDGE_DIR/axi_mldsa_bridge.sv" "$TB_FILE" 2>&1 \
    | grep -v "XSIM 43-3431" | grep -iE "ERROR[:[]" | head -10)
if [ -n "$R" ]; then
    echo "  Bridge/TB FAIL:" | tee -a "$LOG"; echo "$R" | tee -a "$LOG"; exit 2
fi
echo "  Bridge/TB OK" | tee -a "$LOG"

echo "[7/7] Elaborate + run sim (15min timeout)..." | tee -a "$LOG"
$XELAB --relax -d XSIM -d VERILATOR "work.${TB_NAME}" -snapshot "sim_bridge_${PHASE}" 2>&1 \
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
    echo " RESULT: PASS — Verify fail bit matches KAT expected"
    echo "==========================================================="
    exit 0
elif grep -q "testbench done - FAIL" "$SIM_RUN_LOG"; then
    echo "==========================================================="
    echo " RESULT: FAIL — fail bit mismatch (see sim output)"
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
