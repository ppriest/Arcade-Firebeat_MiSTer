-- YMZ280B reference for a bench: every PPC access to the chip (7D000400-7D000403) with its
-- emulated time, to YMZ_LOG; run with FIREBEAT_MUTE_CDDA=1 and -wavwrite (firebeat-meas MAME)
-- so the WAV holds the YMZ280B alone. Lines: "seconds rw offset data mask".
local m = manager.machine
local sp = m.devices[":maincpu"].spaces["program"]
local f = assert(io.open(assert(os.getenv("YMZ_LOG"), "YMZ_LOG"), "w"))
ymzcap_taps = {}
local started = false
emu.register_frame_done(function()
	if started then return end
	started = true
	local function log(rw, offset, data, mask)
		f:write(string.format("%.9f %s %08X %08X %08X\n", m.time:as_double(), rw, offset, data, mask))
	end
	ymzcap_taps[1] = sp:install_write_tap(0x7d000400, 0x7d000403, "ymzcap_w",
		function(offset, data, mask) log("W", offset, data, mask) end)
	ymzcap_taps[2] = sp:install_read_tap(0x7d000400, 0x7d000403, "ymzcap_r",
		function(offset, data, mask) log("R", offset, data, mask) end)
end)
emu.add_machine_stop_notifier(function() f:close() end)
