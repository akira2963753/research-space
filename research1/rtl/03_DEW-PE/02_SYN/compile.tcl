#=================================================================
#-------------------- Compile & Optimization ---------------------
#=================================================================
uniquify
set_fix_multiple_port_nets -all -buffer_constants [get_designs *]
current_design $DESIGN
compile_ultra -no_autoungroup