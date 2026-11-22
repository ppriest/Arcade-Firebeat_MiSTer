derive_pll_clocks
derive_clock_uncertainty

# core specific constraints

# BM3's scan-out clock (rtl/pll_vid.v) is asynchronous to the core's PLL; fb_gcu_disp synchronises
# what crosses. No match in the other revisions.
set vid_clk [get_clocks -nowarn {*|vid|pll|pll_inst|altera_pll_i|*[*].*|divclk}]
if {[get_collection_size $vid_clk] > 0} {
	set_clock_groups -asynchronous -group $vid_clk \
		-group [get_clocks -nowarn {emu|pll|pll_inst|altera_pll_i|*[*].*|divclk}]
}

# The SDRAM controller (rtl/mister/sdram/sdram.sv) takes a request's address, data and enables from
# clk_sys registers no earlier than two clk_mem cycles after they change, and they hold until the
# acknowledge: it acts on the request bits only after resampling them (rq0-rq2), which keep the
# single-cycle check.
set sdram_clk_sys [get_clocks -nowarn {emu|pll|pll_inst|altera_pll_i|general?0?.gpll~PLL_OUTPUT_COUNTER|divclk}]
set sdram_regs [remove_from_collection [get_registers -nowarn {*|firebeat_sdram:u_sdram|sdram:u_sdram|*}] \
	[get_registers -nowarn {*|firebeat_sdram:u_sdram|sdram:u_sdram|rq*}]]
if {[get_collection_size $sdram_clk_sys] > 0 && [get_collection_size $sdram_regs] > 0} {
	set_multicycle_path -from $sdram_clk_sys -to $sdram_regs -setup -end 2
	set_multicycle_path -from $sdram_clk_sys -to $sdram_regs -hold -end 2
}
