# ==================================================
# Giulio Golinelli - golinelli.giulio13@gmail.com
# TUMCREATE QUASAR RESEARCH ENGINEER
# Modified: 2026-06-17
# This file contains modifications vs. the upstream
# CVA6 / ML-DSA-OSH source fork.
# ==================================================

#!/usr/bin/env tclsh

# Ensure Vivado sees the board repository in batch mode.
# Priority:
# - Use environment variable XILINX_BOARD_REPO_PATHS if set (colon-separated list)
# - Otherwise fall back to the default user Xilinx board store path

if {[info exists ::env(XILINX_BOARD_REPO_PATHS)] && $::env(XILINX_BOARD_REPO_PATHS) != ""} {
    set board_repos $::env(XILINX_BOARD_REPO_PATHS)
} else {
    set board_repos "/home/quasart1/.Xilinx/Vivado/2025.2/xhub/board_store/xilinx_board_store"
}

# Convert colon-separated string to Tcl list if needed
if {[string first ":" $board_repos] >= 0} {
    set repo_list [split $board_repos ":"]
} else {
    set repo_list [list $board_repos]
}

puts "[set ::vivado_board_repo_paths $repo_list]"
set_param board.repoPaths $repo_list
