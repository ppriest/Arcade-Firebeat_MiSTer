-- SPDX-License-Identifier: GPL-3.0-or-later
-- Keyboardmania reference (Phase 9 step 1). Through run.lua (MCP mame_run_lua), on the
-- firebeat-meas MAME. Runs gcu_stats.lua alongside (GCU_STATS_SCRIPT, its own GCU_* variables).
--
--   CORE_OUT     output directory:
--                io.txt  "frame R|W addr data" for every PPC access to the extend board
--                        (70000000-7000FFFF: MIDI UART, wheels, IRQ enable/active), the YMZ280B
--                        (7D000400) and the kbm lamps (7D000804)
--   KBM_PRESS    "frame|port|field|frames;..." presses, port without the leading colon
--                ("4000|IN0|Coin 1|10", "5000|kbd0:KEYBOARD|P1 C1|8")
--   KBM_MASH     "from|to|every": from frame `from` to `to`, press the next of P1's and P2's keys
--                in turn every `every` frames, held for every/2

dofile(assert(os.getenv("GCU_STATS_SCRIPT"), "GCU_STATS_SCRIPT unset"))

local out = assert(os.getenv("CORE_OUT"))
local m   = manager.machine
local pp  = m.devices[":maincpu"].spaces["program"]
local f   = assert(io.open(out .. "/io.txt", "w"))

local frame = 0
-- globals: dropped subscriptions stop firing (LESSONS_LEARNED, Lua section)
kbmtap_subs = {}
local function tap(lo, hi, name)
	kbmtap_subs[#kbmtap_subs + 1] = pp:install_read_tap(lo, hi, name .. "_r", function(off, data, mask)
		f:write(string.format("%d R %08X %08X %08X\n", frame, off, data, mask))
	end)
	kbmtap_subs[#kbmtap_subs + 1] = pp:install_write_tap(lo, hi, name .. "_w", function(off, data, mask)
		f:write(string.format("%d W %08X %08X %08X\n", frame, off, data, mask))
	end)
end
tap(0x70000000, 0x7000ffff, "ext")
tap(0x7d000400, 0x7d000403, "ymz")
tap(0x7d000804, 0x7d000807, "lamp")

local presses = {}
local function field(port, name)
	return assert(m.ioport.ports[":" .. port].fields[name], "no field " .. port .. " " .. name)
end
for spec in string.gmatch(os.getenv("KBM_PRESS") or "", "[^;]+") do
	local fr, port, name, len = string.match(spec, "^(%d+)|([^|]+)|([^|]+)|(%d+)$")
	presses[#presses + 1] = { at = tonumber(fr), len = tonumber(len), field = field(port, name) }
end
local notes = { "C1", "C1#", "D1", "D1#", "E1", "F1", "F1#", "G1", "G1#", "A1", "A1#", "B1",
	"C2", "C2#", "D2", "D2#", "E2", "F2", "F2#", "G2", "G2#", "A2", "A2#", "B2" }
local mf, mt, me = string.match(os.getenv("KBM_MASH") or "", "^(%d+)|(%d+)|(%d+)$")
if mf then
	mf, mt, me = tonumber(mf), tonumber(mt), tonumber(me)
	local i = 0
	for fr = mf, mt, me do
		local p = (i % 2 == 0) and "kbd0" or "kbd1"
		local n = notes[(i // 2) % #notes + 1]
		presses[#presses + 1] = { at = fr, len = me // 2,
			field = field(p .. ":KEYBOARD", "P1 " .. n) } -- midikbd names both keyboards' keys P1
		i = i + 1
	end
end

emu.register_frame_done(function()
	frame = frame + 1
	for _, p in ipairs(presses) do
		if frame == p.at then p.field:set_value(1) end
		if frame == p.at + p.len then p.field:clear_value() end
	end
end)

emu.add_machine_stop_notifier(function() f:close() end)
