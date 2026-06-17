# ==================================================
# Giulio Golinelli - golinelli.giulio13@gmail.com
# TUMCREATE QUASAR RESEARCH ENGINEER
# Modified: 2026-06-17
# This file contains modifications vs. the upstream
# CVA6 / ML-DSA-OSH source fork.
# ==================================================

# Resume from completed synthesis — only run implementation + bitstream.
# Use when synth finished but impl failed (e.g. incremental property error).
#
# Usage: vivado -nojournal -mode batch -source scripts/impl_only.tcl

source scripts/prologue.tcl

# Constraints
if {$::env(BOARD) eq "genesys2"} {
    add_files -fileset constrs_1 -norecurse constraints/genesys-2.xdc
} elseif {$::env(BOARD) eq "kc705"} {
    add_files -fileset constrs_1 -norecurse constraints/kc705.xdc
} elseif {$::env(BOARD) eq "vc707"} {
    add_files -fileset constrs_1 -norecurse constraints/vc707.xdc
} elseif {$::env(BOARD) eq "nexys_video"} {
    add_files -fileset constrs_1 -norecurse constraints/nexys_video.xdc
} else { exit 1 }

# IPs
read_ip {
    "xilinx/xlnx_mig_7_ddr3/xlnx_mig_7_ddr3.srcs/sources_1/ip/xlnx_mig_7_ddr3/xlnx_mig_7_ddr3.xci"
    "xilinx/xlnx_axi_clock_converter/xlnx_axi_clock_converter.srcs/sources_1/ip/xlnx_axi_clock_converter/xlnx_axi_clock_converter.xci"
    "xilinx/xlnx_axi_dwidth_converter/xlnx_axi_dwidth_converter.srcs/sources_1/ip/xlnx_axi_dwidth_converter/xlnx_axi_dwidth_converter.xci"
    "xilinx/xlnx_axi_dwidth_converter_dm_slave/xlnx_axi_dwidth_converter_dm_slave.srcs/sources_1/ip/xlnx_axi_dwidth_converter_dm_slave/xlnx_axi_dwidth_converter_dm_slave.xci"
    "xilinx/xlnx_axi_dwidth_converter_dm_master/xlnx_axi_dwidth_converter_dm_master.srcs/sources_1/ip/xlnx_axi_dwidth_converter_dm_master/xlnx_axi_dwidth_converter_dm_master.xci"
    "xilinx/xlnx_axi_gpio/xlnx_axi_gpio.srcs/sources_1/ip/xlnx_axi_gpio/xlnx_axi_gpio.xci"
    "xilinx/xlnx_axi_quad_spi/xlnx_axi_quad_spi.srcs/sources_1/ip/xlnx_axi_quad_spi/xlnx_axi_quad_spi.xci"
    "xilinx/xlnx_clk_gen/xlnx_clk_gen.srcs/sources_1/ip/xlnx_clk_gen/xlnx_clk_gen.xci"
    "xilinx/xlnx_dpti_clk/xlnx_dpti_clk.srcs/sources_1/ip/xlnx_dpti_clk/xlnx_dpti_clk.xci"
}

set_property include_dirs {
    "src/axi_sd_bridge/include"
    "../../vendor/pulp-platform/common_cells/include"
    "../../vendor/pulp-platform/axi/include"
    "../../core/cache_subsystem/hpdcache/rtl/include"
    "../register_interface/include"
    "../instr_tracing/ITI/include"
    "../../core/include"
} [current_fileset]

source scripts/add_sources.tcl
set_property top ${project}_xilinx [current_fileset]

if {$::env(BOARD) eq "genesys2"} {
    read_verilog -sv {src/genesysii.svh ../../vendor/pulp-platform/common_cells/include/common_cells/registers.svh}
} elseif {$::env(BOARD) eq "kc705"} {
    read_verilog -sv {src/kc705.svh ../../vendor/pulp-platform/common_cells/include/common_cells/registers.svh}
} elseif {$::env(BOARD) eq "vc707"} {
    read_verilog -sv {src/vc707.svh ../../vendor/pulp-platform/common_cells/include/common_cells/registers.svh}
} elseif {$::env(BOARD) eq "nexys_video"} {
    read_verilog -sv {src/nexys_video.svh ../../vendor/pulp-platform/common_cells/include/common_cells/registers.svh}
}
set registers "../../vendor/pulp-platform/common_cells/include/common_cells/registers.svh"
set file_obj [get_files -of_objects [get_filesets sources_1] [list "*genesysii.svh" "*kc705.svh" "*vc707.svh" "*nexys_video.svh" "$registers"]]
set_property -dict { file_type {Verilog Header} is_global_include 1} -objects $file_obj
update_compile_order -fileset sources_1
add_files -fileset constrs_1 -norecurse constraints/$project.xdc

# Open the already-completed synthesis run
open_run synth_1

# --- Implementation ---
set ref_dcp "work-fpga/${project}_xilinx.dcp"
set_property -dict {
    steps.place_design.args.directive RuntimeOptimized
    steps.route_design.args.directive RuntimeOptimized
} [get_runs impl_1]

if {[file exists $ref_dcp]} {
    puts "INFO: Using incremental implementation with reference: $ref_dcp"
    set_property incremental_checkpoint $ref_dcp [get_runs impl_1]
} else {
    puts "INFO: No reference DCP, running full implementation"
}

launch_runs impl_1
wait_on_run impl_1
launch_runs impl_1 -to_step write_bitstream
wait_on_run impl_1
open_run impl_1

# --- MCS ---
set bitfile "work-fpga/${project}_xilinx.bit"
set mcsfile "work-fpga/${project}_xilinx.mcs"
if {[file exists $bitfile]} {
    if {$::env(BOARD) eq "genesys2"} {
        write_cfgmem -format mcs -interface SPIx4 -size 256 -loadbit "up 0x0 $bitfile" -file $mcsfile -force
    } elseif {$::env(BOARD) eq "vc707"} {
        write_cfgmem -format mcs -interface bpix16 -size 128 -loadbit "up 0x0 $bitfile" -file $mcsfile -force
    } elseif {$::env(BOARD) eq "kc705"} {
        write_cfgmem -format mcs -interface SPIx4 -size 128 -loadbit "up 0x0 $bitfile" -file $mcsfile -force
    } elseif {$::env(BOARD) eq "nexys_video"} {
        write_cfgmem -format mcs -interface SPIx4 -size 256 -loadbit "up 0x0 $bitfile" -file $mcsfile -force
    }
}

# Save checkpoint for future incremental builds
write_checkpoint -force $ref_dcp
