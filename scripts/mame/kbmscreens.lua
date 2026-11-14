-- SPDX-License-Identifier: GPL-3.0-or-later
-- Keyboardmania's two screens for sim/disp_tb: at the end of frame CORE_FRAME each GCU's VRAM and
-- registers, at the end of the next frame the screen MAME drew from them (vramwin.lua says why).
-- Driven by scripts/mame_kbm_screens.py, through run.lua.
--
--   vram_0.raw, regs_0.txt, screen_0.bin   gcu (0x7E800000), lscreen (F:1832)
--   vram_1.raw, regs_1.txt, screen_1.bin   gcu_sub (0x7E800100), rscreen (F:1841)
--
--   CORE_OUT    output directory
--   CORE_FRAME  the frame

local out  = os.getenv("CORE_OUT")
local from = tonumber(os.getenv("CORE_FRAME"))

local m   = manager.machine
local sp  = m.devices[":maincpu"].spaces["program"]
local scr = { m.screens[":lscreen"], m.screens[":rscreen"] }

local items = {}
for i = 0, 100000 do
	local it = emu.item(i)
	if it.size == 0 and it.count == 0 then break end
	if it.size == 4 and it.count == 8388608 then items[#items + 1] = it end
end
assert(#items >= 2, "expected two VRAM items, found " .. #items)

local regs = { {}, {} }
for g = 1, 2 do for i = 0, 255 do regs[g][i] = 0 end end
local function note(g, offset, data, mask)
	local a = offset & 0xff
	for b = 0, 3 do
		local sh = 8 * (3 - b)
		if mask & (0xff << sh) ~= 0 then regs[g][a + b] = (data >> sh) & 0xff end
	end
end

local subs = {}
local shadow = false
local function install_shadow()
	if shadow then return end
	shadow = true
	for g = 1, 2 do
		local base = 0x7e800000 + (g - 1) * 0x100
		subs[#subs + 1] = sp:install_write_tap(base, base + 0x6f, "ks_a" .. g,
			function(o, d, k) note(g, o, d, k) end)
		subs[#subs + 1] = sp:install_write_tap(base + 0x78, base + 0xff, "ks_b" .. g,
			function(o, d, k) note(g, o, d, k) end)
	end
end

local frame = 0
emu.register_frame_done(function()
	frame = frame + 1
	install_shadow()
	if frame == from then
		for g = 1, 2 do
			local f = assert(io.open(string.format("%s/vram_%d.raw", out, g - 1), "wb"))
			f:write(items[g]:read_block(0, items[g].size * items[g].count))
			f:close()
			if g == 2 then for k = 3, #items do
				local x = assert(io.open(string.format("%s/vram_%d.raw", out, k - 1), "wb"))
				x:write(items[k]:read_block(0, items[k].size * items[k].count))
				x:close()
			end end
			f = assert(io.open(string.format("%s/regs_%d.txt", out, g - 1), "w"))
			for a = 0, 252, 4 do
				f:write(string.format("%02X %02X%02X%02X%02X\n", a, regs[g][a], regs[g][a + 1], regs[g][a + 2], regs[g][a + 3]))
			end
			f:close()
		end
	elseif frame == from + 1 then
		local mf = assert(io.open(out .. "/manifest.txt", "w"))
		for g = 1, 2 do
			local s, w, h = scr[g]:pixels()
			local f = assert(io.open(string.format("%s/screen_%d.bin", out, g - 1), "wb"))
			f:write(s)
			f:close()
			mf:write(string.format("screen_%d %dx%d\n", g - 1, w, h))
			scr[g]:snapshot(string.format("%s/snap_%d.png", out, g - 1))
		end
		mf:close()
		print("KBMSCREENS_DONE " .. frame)
		m:exit()
	end
end)
