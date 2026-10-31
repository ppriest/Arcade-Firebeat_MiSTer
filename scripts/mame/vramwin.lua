-- SPDX-License-Identifier: GPL-3.0-or-later
-- A window of K057714 activity for sim/gcu_tb: VRAM and the register file at the start, every
-- write to 0x7E800000-0x7E8000FF during the window, VRAM and MAME's screens at both ends.
-- Driven by scripts/mame_vram_window.py, through run.lua.
--
-- MAME draws a frame's screen at the start of the frame, from the state left at the end of the
-- previous one, so the screen that goes with the VRAM dumped at the end of frame N is frame
-- N+1's. The capture therefore runs one frame past the window:
--
-- at the end of frame CORE_FRAME:
--   vram_in.raw      32 MB, the GCU's m_vram as MAME holds it (host-order 32-bit words)
--   regs_in.txt      the 64 registers as last written, "NN XXXXXXXX" (big-endian value)
--   items_in.txt     the GCU's save items around m_vram, for cross-checking regs_in.txt
-- then records writes; at the end of frame CORE_FRAME+1, the screen drawn from them:
--   snap_in.png, screen_in.bin
-- at the end of frame CORE_FRAME+CORE_FRAMES:
--   gcu_writes.txt   "W addr mask data", the same format as ppcwin.lua's io.txt
--   vram_out.raw, regs_out.txt, items_out.txt
-- and at the end of frame CORE_FRAME+CORE_FRAMES+1, the screen drawn from those:
--   snap_out.png, screen_out.bin, manifest.txt
--
-- The register file is a shadow of the writes from machine start: MAME's device_reset values
-- are not observable, but every register the display uses is written by the game at boot. The
-- shadow taps skip the data ports 0x70/0x74 -- a tap there would run for every VRAM word the
-- game uploads, tens of millions of Lua calls over a run -- and the window tap covers them.
-- The VRAM item is the first 32-bit save item of 8,388,608 entries (k057714.cpp:44); the
-- second, if any, is the unused second GCU of Keyboardmania.
--
--   CORE_OUT      output directory
--   CORE_FRAME    first frame of the window
--   CORE_FRAMES   frames to record (default 8)
--   CORE_EVENTS   "frame:port:mask:len,..." presses before the window (e.g. 9000:IN0:10:10)
--   CORE_VRAM_ITEM  save-item index, if the search picks the wrong one

local out     = os.getenv("CORE_OUT")
local game    = os.getenv("CORE_GAME") or "?"
local from    = tonumber(os.getenv("CORE_FRAME") or "0")
local nframes = tonumber(os.getenv("CORE_FRAMES") or "8")
local events  = os.getenv("CORE_EVENTS") or ""

local m   = manager.machine
local sp  = m.devices[":maincpu"].spaces["program"]
local scr = m.screens[":screen"]
local gcu = m.devices[":gcu"]

local items = {}                     -- keep the item userdata alive
local function find_vram()
	local want = tonumber(os.getenv("CORE_VRAM_ITEM") or "-1")
	if want >= 0 then
		items[1] = emu.item(want)
		return items[1], want
	end
	for i = 0, 100000 do
		local it = emu.item(i)
		if it.size == 0 and it.count == 0 then break end
		if it.size == 4 and it.count == 8388608 then
			items[1] = it
			return it, i
		end
	end
	error("no 8,388,608-word 32-bit save item")
end
local vram, vram_index = find_vram()

-- the register shadow: the last byte written to each of 0x00-0xFF
local regs = {}
for i = 0, 255 do regs[i] = 0 end

local recording = false
local logf
local writes = 0

local function note(offset, data, mask)
	local a = offset & 0xff
	for b = 0, 3 do
		local sh = 8 * (3 - b)
		if mask & (0xff << sh) ~= 0 then
			regs[a + b] = (data >> sh) & 0xff
		end
	end
end

local function on_write(offset, data, mask)
	note(offset, data, mask)
	if recording and logf then
		logf:write(string.format("W %08X %08X %08X\n", offset, mask, data))
		writes = writes + 1
	end
end

-- the shadow, from boot: everything but the VRAM data ports. Installed on the first frame, not
-- at script load: a tap installed then is not in the machine's finished address space and never
-- sees a write (the window tap, installed in a frame callback, does).
local subs = {}
local shadow = false
local function install_shadow()
	if shadow then return end
	shadow = true
	subs[#subs + 1] = sp:install_write_tap(0x7e800000, 0x7e80006f, "vramwin_regs0",
		function(offset, data, mask) note(offset, data, mask) end)
	subs[#subs + 1] = sp:install_write_tap(0x7e800078, 0x7e8000ff, "vramwin_regs1",
		function(offset, data, mask) note(offset, data, mask) end)
end

local function dump_vram(name)
	local f = assert(io.open(out .. "/" .. name, "wb"))
	f:write(vram:read_block(0, vram.size * vram.count))
	f:close()
end

-- the screen as rendered (palette applied), 32-bit pixels, alongside the snapshot
local function dump_screen(name)
	local s, w, h = scr:pixels()
	local f = assert(io.open(out .. "/" .. name, "wb"))
	f:write(s)
	f:close()
	return w, h
end

-- the GCU's own save-item values around m_vram (diagnostic: the device's authoritative state)
local function dump_items(name)
	local f = assert(io.open(out .. "/" .. name, "w"))
	for i = 240, 340 do
		local it = emu.item(i)
		if it.size == 0 and it.count == 0 then break end
		f:write(string.format("%d %d %d", i, it.size, it.count))
		for k = 0, math.min(it.count, 8) - 1 do
			f:write(string.format(" %X", it:read(k)))
		end
		f:write("\n")
	end
	f:close()
end

local function dump_regs(name)
	local f = assert(io.open(out .. "/" .. name, "w"))
	for a = 0, 252, 4 do
		f:write(string.format("%02X %02X%02X%02X%02X\n", a,
			regs[a], regs[a + 1], regs[a + 2], regs[a + 3]))
	end
	f:close()
end

-- the GCU's per-frame counters, latched at vblank (gcu_stats.lua's names)
local stat_names = { "imm_cmds", "dl_calls", "dl_entries", "dl_depth_max", "obj_cmds",
	"obj_src_px", "obj_dst_px", "obj_blend_px", "obj_clip_px", "fill_px", "chr_px",
	"fifo_words", "cmd_words", "rd_words", "disp_px", "vram_rd_max", "vram_wr_max" }
local function dump_stats(f, tag)
	for i = 0, #stat_names - 1 do
		local o = gcu:output(string.format("stat%02d", i))
		f:write(string.format("%s %s %d\n", tag, stat_names[i + 1], o:exists() and o:get() or -1))
	end
end

-- presses, as ppcwin.lua: a port's field by mask, held for len frames
local pressed, held = {}, {}
for f, port, mask, len in events:gmatch("(%d+):(%w+):(%x+):(%d+)") do
	pressed[#pressed + 1] = { f = tonumber(f), port = ":" .. port, mask = tonumber(mask, 16),
	                          len = tonumber(len) }
end

local frame = 0
local done = false
local screen_w, screen_h = 0, 0
emu.register_frame_done(function()
	frame = frame + 1
	for _, p in ipairs(pressed) do
		if frame == p.f then m.ioport.ports[p.port]:field(p.mask):set_value(1); held[p] = frame + p.len end
		if held[p] and frame >= held[p] then m.ioport.ports[p.port]:field(p.mask):set_value(0); held[p] = nil end
	end
	if done then return end
	install_shadow()
	if frame == from then
		dump_vram("vram_in.raw")
		dump_regs("regs_in.txt")
		dump_items("items_in.txt")
		logf = assert(io.open(out .. "/gcu_writes.txt", "w"))
		subs[#subs + 1] = sp:install_write_tap(0x7e800000, 0x7e8000ff, "vramwin_win", on_write)
		recording = true
		print(string.format("VRAMWIN_IN frame %d item %d", frame, vram_index))
	elseif frame == from + 1 then
		scr:snapshot(out .. "/snap_in.png")
		screen_w, screen_h = dump_screen("screen_in.bin")
	elseif frame == from + nframes then
		recording = false
		logf:close()
		dump_vram("vram_out.raw")
		dump_regs("regs_out.txt")
		dump_items("items_out.txt")
	elseif frame == from + nframes + 1 then
		scr:snapshot(out .. "/snap_out.png")
		dump_screen("screen_out.bin")
		local mf = assert(io.open(out .. "/manifest.txt", "w"))
		mf:write(string.format("game %s\nframe_in %d\nframe_out %d\nframes %d\nitem %d\n" ..
			"words %d\nwrites %d\nscreen %dx%d\nscreen_frames %d %d\n", game, from,
			from + nframes, nframes, vram_index, vram.count, writes, screen_w, screen_h,
			from + 1, from + nframes + 1))
		dump_stats(mf, "in")
		dump_stats(mf, "out")
		mf:close()
		done = true
		print(string.format("VRAMWIN_OUT frame %d writes %d", frame, writes))
		m:exit()
	end
end)

emu.add_machine_stop_notifier(function()
	if logf then logf:close() end
end)
