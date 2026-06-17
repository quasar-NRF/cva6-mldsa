# ==================================================
# Giulio Golinelli - golinelli.giulio13@gmail.com
# TUMCREATE QUASAR RESEARCH ENGINEER
# Modified: 2026-06-17
# This file contains modifications vs. the upstream
# CVA6 / ML-DSA-OSH source fork.
# ==================================================

open_hw_manager
connect_hw_server -url localhost:3121
open_hw_target localhost:3121/xilinx_tcf/Digilent/200300BD8274B

current_hw_device [get_hw_devices xc7k325t_0]
set_property PROGRAM.FILE {/home/quasart1/cva6/corev_apu/fpga/work-fpga/ariane_xilinx.bit} [get_hw_devices xc7k325t_0]
program_hw_devices [get_hw_devices xc7k325t_0]
close_hw_target

puts "PROGRAMMED"
