# gowin_build.tcl - synthesis + place and route of the R8064 cartridge (r8064_cart_top) in Gowin EDA (gw_sh).
# Run with rodar_gowin.bat (or: gw_sh gowin_build.tcl). Results in proj\impl\ (pnr\*.rpt.txt, *.tr, bitstream pnr\r8064_cart.fs).
set root [file dirname [file normalize [info script]]]
create_project -name r8064_cart -dir $root/proj -pn GW2AR-LV18QN88C8/I7 -device_version C -force
add_file $root/src/r8064_cart_all.v
add_file $root/src/tangnano20k_cart.cst
add_file $root/src/r8064_cart.sdc
set_option -top_module r8064_cart_top
set_option -output_base_name r8064_cart
set_option -verilog_std sysv2017
set_option -global_freq 28.64
set_option -timing_driven 1
set_option -gen_text_timing_rpt 1
set_option -print_all_synthesis_warning 1
set_option -use_mspi_as_gpio 1
set_option -use_sspi_as_gpio 1
set_option -use_ready_as_gpio 1
set_option -use_done_as_gpio 1
set_option -use_reconfign_as_gpio 1
run all
run close
