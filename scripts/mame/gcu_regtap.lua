-- SPDX-License-Identifier: GPL-3.0-or-later
-- Log the main GCU's register writes (0x7E800000-0x7E80007F, less the FIFO ports 0x70/0x74) with
-- the frame and scanline they land on, from CORE_FROM to CORE_TO, inputs on a schedule as
-- vram_watch.lua. Through run.lua.
--   CORE_OUT    directory: regs.txt "frame line offset data mask"
--   CORE_FIFO   1: log the FIFO ports too
--   CORE_PC     1: add the main CPU's PC to each line (a DMA write shows the PC of the CPU at the time)
local out  = os.getenv("CORE_OUT")
local from = tonumber(os.getenv("CORE_FROM") or "0")
local to   = tonumber(os.getenv("CORE_TO"))
local fifo = os.getenv("CORE_FIFO") == "1"
local with_pc = os.getenv("CORE_PC") == "1"
local pressed, held = {}, {}
for f, port, mask, len in (os.getenv("CORE_EVENTS") or ""):gmatch("(%d+):(%w+):(%x+):(%d+)") do
    pressed[#pressed + 1] = { f = tonumber(f), port = ":" .. port, mask = tonumber(mask, 16), len = tonumber(len) }
end
local m    = manager.machine
local scr  = m.screens[":screen"]
local cpu  = m.devices[":maincpu"]
local prog = cpu.spaces["program"]

local frame_period = 1.0 / scr.refresh
local line_period
for _ = 1, 64 do
    local d = scr:time_until_pos(1) - scr:time_until_pos(0)
    if d > 0 and (line_period == nil or d < line_period) then
        line_period = d
    end
end
local vtotal = math.floor(frame_period / line_period + 0.5)

-- the line about to be scanned: time_until_pos(0) counts down to the next frame's line 0
local function cur_line()
    return math.floor((frame_period - scr:time_until_pos(0)) / line_period + 0.5) % vtotal
end

local ff = assert(io.open(out .. "/regs.txt", "w"))
ff:write(string.format("# vtotal %d\n", vtotal))
local logging = false
gcu_regtap = prog:install_write_tap(0x7e800000, 0x7e80007f, "gcu_regtap", function(offset, data, mask)
    local o = offset & 0xff
    if logging and (fifo or (o ~= 0x70 and o ~= 0x74)) then
        local pc = ""
        if with_pc then
            pc = string.format(" %08X", cpu.state["PC"].value)
        end
        ff:write(string.format("%d %d %02X %08X %08X%s\n", scr:frame_number(), cur_line(), o, data, mask, pc))
    end
end)

gcu_regtap_sub = emu.add_machine_frame_notifier(function()
    local f_now = scr:frame_number()
    for _, p in ipairs(pressed) do
        if f_now == p.f then
            m.ioport.ports[p.port]:field(p.mask):set_value(1)
            held[p] = f_now + p.len
        end
        if held[p] and f_now >= held[p] then
            m.ioport.ports[p.port]:field(p.mask):set_value(0)
            held[p] = nil
        end
    end
    logging = f_now >= from
    if f_now >= to then
        ff:close()
        m:exit()
    end
end)
