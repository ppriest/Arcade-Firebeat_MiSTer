-- Item 1 workload run for the firebeat-meas MAME: one pass writes
--   gcu.csv     per-frame GCU counters (k057714 outputs <tag>:statNN; names below)
--   pc.txt      per-frame PPC PC histogram: "frame samples pc:n pc:n ..." (hex PCs)
--   ata.txt     every ATA register access except data-register words, with the frame;
--               data words are counted per frame in ata_words.csv
--   ymz.txt     every YMZ280B register write: frame, offset, data, mask
--   wram.txt    work RAM scan at each LOAD_WRAM_AT frame: highest non-zero byte and the
--               non-zero 64 KB blocks (a lower bound on what was touched)
-- Environment: LOAD_DIR (output directory), LOAD_SR (PC samples a second, default 20000),
-- LOAD_SNAP_EVERY (frames between snapshots, 0 = none), LOAD_PRESS ("frame:port:field:frames;..."),
-- LOAD_WRAM_AT ("frame,frame,...").
-- MAME runs the PPC under its DRC: a sample sees the PC at the last scheduler boundary.
local dir = assert(os.getenv("LOAD_DIR"), "LOAD_DIR")
local SR = tonumber(os.getenv("LOAD_SR") or "20000")
local snap_every = tonumber(os.getenv("LOAD_SNAP_EVERY") or "0")
local m = manager.machine
local cpu = m.devices[":maincpu"]
local space = cpu.spaces["program"]
local screen = m.screens:at(1)

local frame = 0

-- GCU counters
local names = { "imm_cmds", "dl_calls", "dl_entries", "dl_depth_max", "obj_cmds", "obj_src_px",
	"obj_dst_px", "obj_blend_px", "obj_clip_px", "fill_px", "chr_px", "fifo_words", "cmd_words",
	"rd_words", "disp_px", "vram_rd_max", "vram_wr_max" }
local gcu = m.devices[":gcu"]
local gcu_out = {}
for i = 0, #names - 1 do gcu_out[i] = gcu:output(string.format("stat%02d", i)) end
local fg = assert(io.open(dir .. "/gcu.csv", "w"))
fg:write("frame," .. table.concat(names, ",") .. "\n")

-- PC sampling
local fp = assert(io.open(dir .. "/pc.txt", "w"))
local pcstate = cpu.state["CURPC"]
local hist, nsamp = {}, 0
local function sampler_start()
	local co = coroutine.wrap(function()
	while true do
		emu.wait(1 / SR)
		local pc = pcstate.value
		hist[pc] = (hist[pc] or 0) + 1
		nsamp = nsamp + 1
	end
	end)
	co()
end

-- ATA: CS0 at 7FE00000, CS1 at 7FE80000, 16-bit registers on the 32-bit bus
local fa = assert(io.open(dir .. "/ata.txt", "w"))
fa:write("# frame rw cs reg data mask (reg = byte offset / 2)\n")
local faw = assert(io.open(dir .. "/ata_words.csv", "w"))
faw:write("frame,data_rd,data_wr\n")
local ata_rd, ata_wr = 0, 0
local function ata_log(rw, cs, offset, data, mask)
	local reg = (offset & 0xf) >> 1
	if mask == 0xffff0000 then reg = (offset & 0xc) >> 1
	elseif mask == 0x0000ffff then reg = ((offset & 0xc) >> 1) + 1 end
	if cs == 0 and reg == 0 then
		if rw == "R" then ata_rd = ata_rd + 1 else ata_wr = ata_wr + 1 end
		if rw == "R" then return end
	end
	fa:write(string.format("%d %s %d %d %08X %08X\n", frame, rw, cs, reg, data, mask))
end
local taps = {}
local function install_taps()
taps[#taps + 1] = space:install_read_tap(0x7fe00000, 0x7fe0000f, "ata0r",
	function(offset, data, mask) ata_log("R", 0, offset, data, mask) end)
taps[#taps + 1] = space:install_write_tap(0x7fe00000, 0x7fe0000f, "ata0w",
	function(offset, data, mask) ata_log("W", 0, offset, data, mask) end)
taps[#taps + 1] = space:install_read_tap(0x7fe80000, 0x7fe8000f, "ata1r",
	function(offset, data, mask) ata_log("R", 1, offset, data, mask) end)
taps[#taps + 1] = space:install_write_tap(0x7fe80000, 0x7fe8000f, "ata1w",
	function(offset, data, mask) ata_log("W", 1, offset, data, mask) end)
end

-- YMZ280B
local fy = assert(io.open(dir .. "/ymz.txt", "w"))
fy:write("# frame offset data mask\n")
local function install_taps2()
taps[#taps + 1] = space:install_write_tap(0x7d000400, 0x7d000403, "ymzw",
	function(offset, data, mask) fy:write(string.format("%d %08X %08X %08X\n", frame, offset, data, mask)) end)
end

-- control_w, for the pixel-clock mode
local fc = assert(io.open(dir .. "/control.txt", "w"))
local function install_taps3()
taps[#taps + 1] = space:install_write_tap(0x7d000500, 0x7d000503, "ctlw",
	function(offset, data, mask) fc:write(string.format("%d %08X %08X %08X\n", frame, offset, data, mask)) end)
end

-- work RAM scan
local wram_at = {}
for f in string.gmatch(os.getenv("LOAD_WRAM_AT") or "", "%d+") do wram_at[tonumber(f)] = true end
local fw = assert(io.open(dir .. "/wram.txt", "w"))
local function wram_scan()
	local hi, blocks = -1, {}
	for b = 0, 511 do
		local base = b * 0x10000
		local s = space:read_range(base, base + 0xffff, 8)
		local last = nil
		for i = #s, 1, -1 do
			if s:byte(i) ~= 0 then last = i; break end
		end
		if last then
			blocks[#blocks + 1] = string.format("%03X", b)
			hi = base + last - 1
		end
	end
	fw:write(string.format("frame %d highest_nonzero %08X blocks %d : %s\n", frame, hi, #blocks,
		table.concat(blocks, " ")))
	fw:flush()
end

-- timed presses
local presses = {}
for spec in string.gmatch(os.getenv("LOAD_PRESS") or "", "[^;]+") do
	local fr, port, field, len = string.match(spec, "^(%d+):([^:]+):([^:]+):(%d+)$")
	local fld = assert(m.ioport.ports[":" .. port].fields[field], "no field " .. spec)
	presses[#presses + 1] = { at = tonumber(fr), len = tonumber(len), field = fld }
end

-- The machine is not running when the script loads: the taps and the sampler start on the
-- first frame. Frame 1's histogram and ATA log are therefore empty.
local started = false
emu.register_frame_done(function()
	if not started then
		started = true
		install_taps(); install_taps2(); install_taps3()
		sampler_start()
	end
	frame = frame + 1
	for _, p in ipairs(presses) do
		if frame == p.at then p.field:set_value(1) end
		if frame == p.at + p.len then p.field:clear_value() end
	end
	local row = { tostring(frame) }
	for i = 0, #names - 1 do row[#row + 1] = tostring(gcu_out[i]:get()) end
	fg:write(table.concat(row, ",") .. "\n")
	local parts = { tostring(frame), tostring(nsamp) }
	for pc, n in pairs(hist) do parts[#parts + 1] = string.format("%X:%d", pc, n) end
	fp:write(table.concat(parts, " ") .. "\n")
	hist, nsamp = {}, 0
	faw:write(string.format("%d,%d,%d\n", frame, ata_rd, ata_wr))
	ata_rd, ata_wr = 0, 0
	if wram_at[frame] then wram_scan() end
	if snap_every > 0 and frame % snap_every == 0 then screen:snapshot() end
end)

emu.add_machine_stop_notifier(function()
	for _, f in ipairs({ fg, fp, fa, faw, fy, fc, fw }) do f:close() end
end)

