-- SPDX-License-Identifier: GPL-3.0-or-later
-- Beatmania III's effects (ROADMAP Phase 10 step 6a): the ST-224's MIDI (PC16552D chan1), the
-- RF5C400's per-channel main (reg 6) and effect-send (reg 7) levels and its global writes, with
-- the pedals pressed and the seven effect dials set on a schedule. Through run.lua.
--   CORE_OUT    directory: midi.txt "frame seconds byte", rf5c.txt "frame seconds ch reg data"
--               (ch -1: global register), dials.txt "frame dial value" as applied
--   CORE_TO     frame to exit at
--   CORE_EVENTS "frame:port:mask:len,..." inputs to press (as bm3_survey.lua)
--   CORE_DIALS  "frame:dial:value,..." dial 1-7 set to 0-31 from that frame on
--   CORE_SNAP   a snapshot every this many frames (0: none)
local out = os.getenv("CORE_OUT")
local to  = tonumber(os.getenv("CORE_TO") or "30000")
local snap_every = tonumber(os.getenv("CORE_SNAP") or "0")
local pressed, held, sched = {}, {}, {}
for f, port, mask, len in (os.getenv("CORE_EVENTS") or ""):gmatch("(%d+):(%w+):(%x+):(%d+)") do
    pressed[#pressed + 1] = { f = tonumber(f), port = ":" .. port, mask = tonumber(mask, 16), len = tonumber(len) }
end
for f, d, v in (os.getenv("CORE_DIALS") or ""):gmatch("(%d+):(%d+):(%d+)") do
    sched[#sched + 1] = { f = tonumber(f), d = tonumber(d), v = tonumber(v) }
end
local m   = manager.machine
local pp  = m.devices[":maincpu"].spaces["program"]
local sp  = m.devices[":audiocpu"].spaces["program"]
bm3fx_subs = {}
local f_now = 0
local dial = { 0, 0, 0, 0, 0, 0, 0 }
local fm = assert(io.open(out .. "/midi.txt", "w"))
local fr = assert(io.open(out .. "/rf5c.txt", "w"))
local fd = assert(io.open(out .. "/dials.txt", "w"))
local function t() return m.time:as_double() end

-- chan1 at 70000800 (THR/DLL), 70000B00 LCR; a byte goes out when DLAB is clear
local dlab = false
bm3fx_subs[#bm3fx_subs + 1] = pp:install_write_tap(0x70000800, 0x70000bff, "st224", function(o, d, mk)
    local b = (d >> 24) & 0xff
    if (o & 0xf00) == 0xb00 then dlab = (b & 0x80) ~= 0
    elseif (o & 0xf00) == 0x800 and not dlab then fm:write(string.format("%d %.6f %02X\n", f_now, t(), b)) end
end)

-- sensor_r: halfword k at 7d000340 + 2k; dials are k = 9..15
bm3fx_subs[#bm3fx_subs + 1] = pp:install_read_tap(0x7d000340, 0x7d00035f, "dials", function(o, d, mk)
    local base = ((o & ~3) - 0x7d000340) >> 1
    local r = d
    if (mk & 0xffff0000) ~= 0 and base >= 9 and base <= 15 then
        r = (r & 0x0000ffff) | ((dial[base - 8] | 0x100) << 16)
    end
    if (mk & 0x0000ffff) ~= 0 and base + 1 >= 9 and base + 1 <= 15 then
        r = (r & 0xffff0000) | (dial[base - 7] | 0x100)
    end
    if r ~= d then return r end
end)

bm3fx_subs[#bm3fx_subs + 1] = sp:install_write_tap(0x400000, 0x400fff, "rf5c_w", function(o, d, mk)
    local w = (o - 0x400000) >> 1
    if w < 0x400 then
        if w >= 0x20 and w < 0x40 then fr:write(string.format("%d %.6f -1 %02X %04X\n", f_now, t(), w, d)) end
    else
        local reg = w & 0x1f
        if reg == 6 or reg == 7 then fr:write(string.format("%d %.6f %d %d %04X\n", f_now, t(), (w >> 5) & 0x1f, reg, d)) end
    end
end)

bm3fx_subs[#bm3fx_subs + 1] = emu.add_machine_frame_notifier(function()
    f_now = m.screens[":screen"]:frame_number()
    for _, p in ipairs(pressed) do
        if f_now == p.f then m.ioport.ports[p.port]:field(p.mask):set_value(1); held[p] = f_now + p.len end
        if held[p] and f_now >= held[p] then m.ioport.ports[p.port]:field(p.mask):set_value(0); held[p] = nil end
    end
    for _, s in ipairs(sched) do
        if f_now == s.f then dial[s.d] = s.v; fd:write(string.format("%d %d %d\n", f_now, s.d, s.v)) end
    end
    if snap_every > 0 and f_now > 0 and f_now % snap_every == 0 and f_now < to then m.video:snapshot() end
    if f_now >= to then
        fm:close(); fr:close(); fd:close()
        m:exit()
    end
end)
