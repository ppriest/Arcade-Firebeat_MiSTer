-- SPDX-License-Identifier: GPL-3.0-or-later
-- Keyboardmania's Test-menu install on a stock MAME, for an RTC preset (scripts/rtc/<set>.nv,
-- docs/HARDWARE_NOTES "Keyboardmania in MAME"). Through run.lua (MCP mame_run_lua); the NVRAM
-- MAME writes at exit is the result.
--
--   KBM_PRESS  "frame|port|field|frames;..." presses, port without the leading colon
--              ("6000|IN1|Test|120", "6300|IN0|P2 Start|8")
--   KBM_SNAPS  "frame,frame,...": a snapshot at each; MAME exits two frames after the last

local m = manager.machine
local presses, snaps, last = {}, {}, 0
for spec in string.gmatch(os.getenv("KBM_PRESS") or "", "[^;]+") do
	local fr, port, name, len = string.match(spec, "^(%d+)|([^|]+)|([^|]+)|(%d+)$")
	local fld = assert(m.ioport.ports[":" .. port] and m.ioport.ports[":" .. port].fields[name],
		"no field " .. port .. " " .. name)
	presses[#presses + 1] = { at = tonumber(fr), len = tonumber(len), field = fld }
end
for fr in string.gmatch(os.getenv("KBM_SNAPS") or "", "%d+") do
	snaps[tonumber(fr)] = true
	last = math.max(last, tonumber(fr))
end

local frame = 0
kbm_install_sub = emu.add_machine_frame_notifier(function()
	frame = frame + 1
	for _, p in ipairs(presses) do
		if frame == p.at then p.field:set_value(1) end
		if frame == p.at + p.len then p.field:clear_value() end
	end
	if snaps[frame] then m.video:snapshot() end
	if last > 0 and frame == last + 2 then m:exit() end
end)
