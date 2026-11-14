-- SPDX-License-Identifier: GPL-3.0-or-later
-- The main CPU's PC once a frame, and the longest runs of frames it spent inside a window: how long a
-- loop the board's watchdog must outlast (probe W gives the PC where it fired). Through run.lua.
--
--   PC_LO, PC_HI  the window, hex
--   CORE_OUT      writes pc_dwell.txt: each run of 5+ frames in the window, "first last frames"

local lo, hi = tonumber(os.getenv("PC_LO"), 16), tonumber(os.getenv("PC_HI"), 16)
local cpu = manager.machine.devices[":maincpu"]
local out = io.open((os.getenv("CORE_OUT") or ".") .. "/pc_dwell.txt", "w")
local frame, start, best = 0, nil, 0
pc_dwell_sub = emu.add_machine_frame_notifier(function()
	frame = frame + 1
	local pc = cpu.state["PC"].value
	local inside = pc >= lo and pc < hi
	if inside and not start then start = frame end
	if not inside and start then
		local n = frame - start
		if n >= 5 then out:write(string.format("%d %d %d\n", start, frame - 1, n)); out:flush() end
		best = math.max(best, n)
		start = nil
	end
	if frame % 600 == 0 then out:write(string.format("# frame %d pc %08X longest %d\n", frame, pc, best)); out:flush() end
end)
