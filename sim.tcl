# =============================================================================
#  sim.tcl -- run all three testbenches with the Vivado simulator (xsim).
#
#  Usage:
#      vivado -mode batch -source sim.tcl -log sim.log -journal sim.jou
#
#  Artifacts land in sim/run/ : frame_title.ppm, frame_play.ppm, frame_over.ppm
# =============================================================================

set script_dir [file normalize [file dirname [info script]]]
set bindir     [file dirname [file normalize [info nameofexecutable]]]

set xvlog "$bindir/xvlog"
set xelab "$bindir/xelab"
set xsim  "$bindir/xsim"

puts "==> simulator binaries in $bindir"

proc run {args} {
    puts ">>> $args"
    if {[catch {exec {*}$args 2>@1} out]} {
        puts $out
        error "command failed: $args"
    }
    puts $out
}

file mkdir $script_dir/sim/run
cd $script_dir/sim/run

# ------------------------------------------------------------------ compile
run $xvlog {*}[glob $script_dir/rtl/*.v] {*}[glob $script_dir/sim/tb_*.v]

# -------------------------------------------------------------- elaborate+run
set tbs {tb_flappy_system tb_i2c_init tb_btn_polarity}
set failed {}

foreach tb $tbs {
    puts "=============================================="
    puts "==> $tb"
    puts "=============================================="
    if {[catch {
        run $xelab $tb -snapshot "snap_$tb"
        run $xsim "snap_$tb" -R
    } err]} {
        puts "!!! $tb failed: $err"
        lappend failed $tb
    }
}

puts "=============================================="
if {[llength $failed] == 0} {
    puts "==> all testbenches ran"
} else {
    puts "==> testbenches with problems: $failed"
}
puts "==> frame dumps:"
foreach f [glob -nocomplain $script_dir/sim/run/*.ppm] { puts "      $f" }
