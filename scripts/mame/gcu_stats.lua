-- Per-frame GCU workload from the firebeat-meas MAME (k057714 counters, outputs <tag>:statNN,
-- latched at vblank). Writes one CSV row per frame to GCU_STATS_FILE; with GCU_SNAP_EVERY = N,
-- saves a snapshot every N frames to the snap directory. GCU_TAGS lists the GCUs ("gcu" or
-- "gcu,gcu_sub"). GCU_PRESS holds timed presses, "frame:port:field:frames;..." (field by
-- name, as ports.lua prints it: "120:IN0:Service Mode:10").
local names = { "imm_cmds", "dl_calls", "dl_entries", "dl_depth_max", "obj_cmds", "obj_src_px",
	"obj_dst_px", "obj_blend_px", "obj_clip_px", "fill_px", "chr_px", "fifo_words", "cmd_words",
	"rd_words", "disp_px", "vram_rd_max", "vram_wr_max" }
local file = os.getenv("GCU_STATS_FILE") or "gcu_stats.csv"
local snap_every = tonumber(os.getenv("GCU_SNAP_EVERY") or "0")
local tags = {}
for t in string.gmatch(os.getenv("GCU_TAGS") or "gcu", "[^,]+") do tags[#tags + 1] = t end

local items = {}
for _, t in ipairs(tags) do
	local dev = assert(manager.machine.devices[":" .. t], "no device :" .. t)
	items[t] = {}
	for i = 0, #names - 1 do items[t][i] = dev:output(string.format("stat%02d", i)) end
end
local screen = manager.machine.screens:at(1)
local f = assert(io.open(file, "w"))
local hdr = { "frame" }
for _, t in ipairs(tags) do
	for _, n in ipairs(names) do hdr[#hdr + 1] = t .. "_" .. n end
end
f:write(table.concat(hdr, ",") .. "\n")

local presses = {}
for spec in string.gmatch(os.getenv("GCU_PRESS") or "", "[^;]+") do
	local fr, port, field, len = string.match(spec, "^(%d+):([^:]+):([^:]+):(%d+)$")
	local fld = assert(manager.machine.ioport.ports[":" .. port].fields[field], "no field " .. spec)
	presses[#presses + 1] = { at = tonumber(fr), len = tonumber(len), field = fld }
end

local frame = 0
emu.register_frame_done(function()
	frame = frame + 1
	for _, p in ipairs(presses) do
		if frame == p.at then p.field:set_value(1) end
		if frame == p.at + p.len then p.field:clear_value() end
	end
	local row = { tostring(frame) }
	for _, t in ipairs(tags) do
		for i = 0, #names - 1 do
			row[#row + 1] = tostring(items[t][i]:get())
		end
	end
	f:write(table.concat(row, ",") .. "\n")
	if snap_every > 0 and frame % snap_every == 0 then screen:snapshot() end
end)

emu.add_machine_stop_notifier(function() f:close() end)
