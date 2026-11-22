-- SPDX-License-Identifier: GPL-3.0-or-later
-- Beatmania III's floppy (ROADMAP Phase 10 step 9a): every FDC37C665GT access (70001000-70001FFF,
-- top byte lane) with the inputs pressed on a schedule; run with a disk in -flop. Through run.lua.
--   CORE_OUT    directory: fdc.txt "frame seconds R|W register data"
--   CORE_TO     frame to exit at
--   CORE_EVENTS "frame:port:mask:len,..." inputs to press (as bm3_survey.lua)
--   CORE_SNAP   a snapshot every this many frames (0: none)
local out = os.getenv("CORE_OUT")
local to  = tonumber(os.getenv("CORE_TO") or "30000")
local snap_every = tonumber(os.getenv("CORE_SNAP") or "0")
local pressed, held = {}, {}
for f, port, mask, len in (os.getenv("CORE_EVENTS") or ""):gmatch("(%d+):(%w+):(%x+):(%d+)") do
    pressed[#pressed + 1] = { f = tonumber(f), port = ":" .. port, mask = tonumber(mask, 16), len = tonumber(len) }
end
local m  = manager.machine
local pp = m.devices[":maincpu"].spaces["program"]
bm3fdc_subs = {}
local f_now = 0
local ff = assert(io.open(out .. "/fdc.txt", "w"))
local function t()
    return m.time:as_double()
end

local function log(rw, o, d, mk)
    if (mk & 0xff000000) ~= 0 then
        ff:write(string.format("%d %.6f %s %X %02X\n", f_now, t(), rw, (o - 0x70001000) >> 2, (d >> 24) & 0xff))
    end
end
bm3fdc_subs[#bm3fdc_subs + 1] = pp:install_read_tap(0x70001000, 0x70001fff, "fdc_r", function(o, d, mk)
    log("R", o, d, mk)
end)
bm3fdc_subs[#bm3fdc_subs + 1] = pp:install_write_tap(0x70001000, 0x70001fff, "fdc_w", function(o, d, mk)
    log("W", o, d, mk)
end)

bm3fdc_subs[#bm3fdc_subs + 1] = emu.add_machine_frame_notifier(function()
    f_now = m.screens[":screen"]:frame_number()
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
    if snap_every > 0 and f_now > 0 and f_now % snap_every == 0 and f_now < to then
        m.video:snapshot()
    end
    if f_now >= to then
        ff:close()
        m:exit()
    end
end)
