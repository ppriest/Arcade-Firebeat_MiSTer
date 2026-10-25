# Period set per run by scripts/synth_ppc.py (66 MHz = 15.152 ns, 50.35 MHz = 19.861 ns).
create_clock -name clk -period 15.152 [get_ports clk]
derive_clock_uncertainty
set_false_path -from [get_ports {reset din}] -to *
set_false_path -from * -to [get_ports dout]
