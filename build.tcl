# =============================================================================
#  build.tcl -- create the KC705 Flappy Bird Vivado project and run the full
#               flow (synthesis, implementation, bitstream, reports).
#
#  Usage (no GUI anywhere):
#      cd ~/kc705_flappy
#      vivado -mode batch -source build.tcl -log build.log -journal build.jou
#
#  Target: Kintex-7 KC705, part xc7k325tffg900-2
# =============================================================================

set script_dir [file normalize [file dirname [info script]]]
cd $script_dir

set part_name  "xc7k325tffg900-2"
set proj_name  "kc705_flappy"
set proj_dir   "$script_dir/build"
set jobs       8

puts "==> project dir: $script_dir"
puts "==> part: $part_name"

file mkdir $proj_dir
file mkdir $script_dir/reports

# ---------------------------------------------------------------- project
create_project -force $proj_name $proj_dir -part $part_name

# ---- design sources ----
add_files -norecurse [glob $script_dir/rtl/*.v]
set_property top kc705_flappy_top [current_fileset]

# ---- constraints ----
add_files -fileset constrs_1 -norecurse $script_dir/kc705_flappy.xdc

# ---- simulation sources ----
add_files -fileset sim_1 -norecurse [glob $script_dir/sim/*.v]
set_property top tb_flappy_system [get_filesets sim_1]

update_compile_order -fileset sources_1

puts "==> sources:"
foreach f [get_files -of_objects [get_filesets sources_1]] { puts "      $f" }

# ------------------------------------------------------------- synthesis
puts "==> launching synthesis"
launch_runs synth_1 -jobs $jobs
wait_on_run synth_1

set synth_status [get_property STATUS [get_runs synth_1]]
set synth_prog   [get_property PROGRESS [get_runs synth_1]]
puts "==> synth_1 status: $synth_status ($synth_prog)"
if {$synth_prog ne "100%"} {
    error "SYNTHESIS FAILED - see $proj_dir/$proj_name.runs/synth_1/runme.log"
}

open_run synth_1 -name synth_1
report_utilization    -file $script_dir/reports/utilization_synth.rpt
report_timing_summary -file $script_dir/reports/timing_synth.rpt
report_clock_interaction -file $script_dir/reports/clock_interaction.rpt

# collect critical warnings from the synthesis log (scanning the log is more
# reliable than get_msg_config, which configures rather than queries messages)
set synth_log "$proj_dir/$proj_name.runs/synth_1/runme.log"
set ncrit 0
if {[file exists $synth_log]} {
    set fh_in  [open $synth_log r]
    set fh_out [open "$script_dir/reports/synth_critical_warnings.txt" w]
    while {[gets $fh_in line] >= 0} {
        if {[string match "*CRITICAL WARNING*" $line]} {
            puts $fh_out $line
            incr ncrit
        }
    }
    close $fh_in
    close $fh_out
}
puts "==> synthesis critical warnings: $ncrit (see reports/synth_critical_warnings.txt)"

# -------------------------------------------------------- implementation
puts "==> launching implementation + bitstream"
# The pixel path is route-dominated (hcnt -> renderer -> packer spans a lot of
# the die once the scaling ROMs exist), so ask for an effort level that spends
# real time on placement; default effort leaves ~1 ns on the table.
set_property STEPS.place_design.ARGS.DIRECTIVE Explore [get_runs impl_1]
set_property STEPS.post_route_phys_opt_design.IS_ENABLED 1 [get_runs impl_1]
launch_runs impl_1 -to_step write_bitstream -jobs $jobs
wait_on_run impl_1

set impl_prog [get_property PROGRESS [get_runs impl_1]]
set impl_status [get_property STATUS [get_runs impl_1]]
puts "==> impl_1 status: $impl_status ($impl_prog)"
if {$impl_prog ne "100%"} {
    error "IMPLEMENTATION FAILED - see $proj_dir/$proj_name.runs/impl_1/runme.log"
}

open_run impl_1
report_timing_summary -file $script_dir/reports/timing_impl.rpt
report_utilization    -file $script_dir/reports/utilization_impl.rpt
report_drc            -file $script_dir/reports/drc.rpt
report_power          -file $script_dir/reports/power.rpt

# ------------------------------------------------------------- summaries
set wns [get_property STATS.WNS [get_runs impl_1]]
set whs [get_property STATS.WHS [get_runs impl_1]]
set tns [get_property STATS.TNS [get_runs impl_1]]
set ths [get_property STATS.THS [get_runs impl_1]]
set wpws [get_property STATS.WPWS [get_runs impl_1]]

puts "=============================================================="
puts "  timing after implementation"
puts "    WNS  (setup)   = $wns ns"
puts "    WHS  (hold)    = $whs ns"
puts "    TNS  (setup)   = $tns ns"
puts "    THS  (hold)    = $ths ns"
puts "    WPWS (pulse)   = $wpws ns"
puts "=============================================================="

set bitfile [glob -nocomplain $proj_dir/$proj_name.runs/impl_1/*.bit]
puts "==> bitstream: $bitfile"

# ------------------------------------------------- flash image for QSPI boot
# The KC705 boots from its onboard Quad SPI flash in Master SPI mode
# (SW13 M[2:0] = 001).  Note it CANNOT boot from the SD card slot: that
# connector is wired to FPGA user I/O, not to the configuration logic, so an
# SD card can only be used by logic inside the design.
set binfile "$script_dir/$proj_name.bin"
write_cfgmem -format BIN -interface SPIx4 -size 16 \
             -loadbit "up 0x0 $bitfile" -force $binfile
puts "==> flash image (QSPI): $binfile"

set rf [open "$script_dir/reports/summary.txt" w]
puts $rf "part          : $part_name"
puts $rf "synth status  : $synth_status"
puts $rf "impl status   : $impl_status"
puts $rf "WNS           : $wns"
puts $rf "WHS           : $whs"
puts $rf "TNS           : $tns"
puts $rf "THS           : $ths"
puts $rf "bitstream     : $bitfile"
close $rf

if {$wns < 0 || $whs < 0} {
    puts "==> WARNING: timing not met"
} else {
    puts "==> TIMING MET"
}

puts "==> build.tcl done"
