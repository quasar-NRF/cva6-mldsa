#!/bin/bash
# Run a single phase at all 3 sec levels, both standalone and bridge.
# Usage: run_phase_all_seclevels.sh <phase> [num_tv]
#   phase: keygen | sign | verify | e2e
#   num_tv: number of KAT vectors (default 1)
#
# Order: standalone@sec_lvl=3 (regression) → standalone@2 → standalone@5
#        → bridge@3 (regression) → bridge@2 → bridge@5
# Stops on first FAIL. Prints summary table at the end.

set -u

PHASE="${1:?usage: $0 <phase> [num_tv]}"
NUM_TV="${2:-1}"
case "$PHASE" in
  keygen|sign|verify|e2e) ;;
  *) echo "Invalid phase '$PHASE' (use keygen|sign|verify|e2e)"; exit 2 ;;
esac

BASE="/home/quasart1/cva6/corev_apu/fpga/sim/mldsa/$PHASE"
RESULTS=()
OVERALL_RC=0
START_TS=$(date +%s)

run_one() {
  local mode="$1"
  local sec="$2"
  local dir="${BASE}/${mode}"
  local t0 t1 elapsed rc
  t0=$(date +%s)
  echo "=========================================================="
  echo "  ${PHASE}/${mode} @ sec_lvl=${sec}"
  echo "=========================================================="
  # Pass arg order depends on mode (standalone: NUM_TV then SEC_LVL; bridge: SEC_LVL only)
  if [ "$mode" = "standalone" ]; then
    ( cd "$dir" && bash run.sh "$NUM_TV" "$sec" ) > "${dir}/run.log.lvl${sec}" 2>&1
  else
    ( cd "$dir" && bash run.sh "$sec" ) > "${dir}/run.log.lvl${sec}" 2>&1
  fi
  rc=$?
  t1=$(date +%s)
  elapsed=$((t1 - t0))
  if [ "$rc" -eq 0 ]; then
    RESULTS+=("PASS  ${PHASE}/${mode} @ sec_lvl=${sec}  (${elapsed}s)")
  else
    RESULTS+=("FAIL  ${PHASE}/${mode} @ sec_lvl=${sec}  rc=${rc}  (${elapsed}s)")
    OVERALL_RC=1
    return 1
  fi
  return 0
}

# Standalone first: 3, 2, 5 (regression-first per memory)
for sec in 3 2 5; do
  run_one "standalone" "$sec" || {
    echo "STOPPING: standalone@sec_lvl=${sec} failed"
    break
  }
done

# Bridge next: 3, 2, 5 (only if all standalone passed)
if [ $OVERALL_RC -eq 0 ]; then
  for sec in 3 2 5; do
    run_one "bridge" "$sec" || {
      echo "STOPPING: bridge@sec_lvl=${sec} failed"
      break
    }
  done
fi

TOTAL=$(( $(date +%s) - START_TS ))
echo ""
echo "=========================================================="
echo " ${PHASE} sweep summary — total ${TOTAL}s"
echo "=========================================================="
for r in "${RESULTS[@]}"; do echo "  $r"; done
echo "=========================================================="
if [ $OVERALL_RC -eq 0 ]; then
  echo " ${PHASE}: ALL 6 PASS (3 sec_lvls × 2 modes)"
else
  echo " ${PHASE}: some runs FAILED — see logs above"
fi
echo "=========================================================="
exit $OVERALL_RC
