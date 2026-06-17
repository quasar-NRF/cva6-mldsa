# Quick incremental rebuild — re-runs the full Vivado flow but skips
# IP generation (IPs are already built in xilinx/ directories).
# This saves ~50-70% of build time compared to a clean build.
#
# Usage (from repo root):  make -C corev_apu/fpga quick

# Just delegate to the normal flow — IPs are already on disk
source scripts/prologue.tcl
source scripts/run.tcl
