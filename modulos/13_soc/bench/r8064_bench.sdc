// r8064_bench.sdc - timing constraint for Gowin EDA: 27 MHz board crystal on pin 4 (clk27); the rPLL output (27 MHz in REV53 with FPU, 43.2 or 57.375 MHz with R8064_CLK43/R8064_CLK57) is derived by the tool.
create_clock -name clk27 -period 37.037 -waveform {0 18.518} [get_ports {clk27}]
