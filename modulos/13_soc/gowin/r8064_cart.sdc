// r8064_cart.sdc - timing constraint for Gowin EDA: 14.31818 MHz input on pin 80 (clk14m); the rPLL x2 output (28.636 MHz, REV53 with FPU) is derived by the tool.
create_clock -name clk14m -period 69.841 -waveform {0 34.920} [get_ports {clk14m}]
