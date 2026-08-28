#=================================================================
#---------- Synopsys Design Compiler Synthesis Scripts -----------
#=================================================================

#=================================================================
#--------------------- TOP Module Definition ---------------------
#=================================================================
set DESIGN "DEW_PE"
set CYCLE 10

#=================================================================
#------------- Create the Working and Saving Folders -------------
#=================================================================
sh mkdir -p Netlist
sh mkdir -p Report
sh mkdir -p Work
define_design_lib WORK -path Work

#=================================================================
#------------------- Set Operating Conditions --------------------
#=================================================================
set_operating_conditions -min fast -max slow

#=================================================================
#----------------- Analyze and Elaborate Design ------------------
#=================================================================
analyze -f sverilog -vcs "-f file.f" -library WORK
elaborate $DESIGN -library WORK
current_design $DESIGN
link

#=================================================================
#------------------------- Create Clock --------------------------
#=================================================================
create_clock -name clk -period $CYCLE [get_ports clk]
set_dont_touch [all_clocks]
set_ideal_network [all_clocks]
set_fix_hold [all_clocks]

# Clock Constraints
set_clock_uncertainty -hold 0.005 [all_clocks]
set_clock_uncertainty -setup 0.1 [all_clocks]
set_clock_latency 0.5 [all_clocks]
set_clock_latency -source 0 [all_clocks]
set_clock_transition 0.1 [all_clocks]

#=================================================================
#---------------------- Timing Constraints -----------------------
#=================================================================
set_input_delay [expr $CYCLE * 0.5] -clock clk [all_inputs]
set_output_delay [expr $CYCLE * 0.5] -clock clk [all_outputs]
set_input_transition 0.2 [all_inputs]
set_max_delay 0 -from [all_inputs] -to [all_outputs]

#=================================================================
#-------------------- Design Rule Constraints --------------------
#=================================================================
set_driving_cell -library tpzn90gv3wc -lib_cell PDIDGZ_33 -pin {C} [remove_from_collection [all_inputs] [get_ports clk]]
set_load [load_of "tpzn90gv3wc/PDO16CDG_33/I"] [all_outputs]

set_max_capacitance 0.1 [all_inputs]
set_max_fanout 10 [all_inputs]
set_max_transition 0.2 [all_inputs]

write_sdc ./Netlist/${DESIGN}_init.sdc
