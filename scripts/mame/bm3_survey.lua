-- SPDX-License-Identifier: GPL-3.0-or-later
-- Beatmania III survey (ROADMAP Phase 10): the SPU ATA task-file writes (the HDD's commands), the
-- DMA and wave-bank registers, the PPC's accesses to the extend board (MIDI UART, FDC, spectrum
-- analyser), the YMZ280B, the sensors and 7D000330; access counts at the end, a snapshot.
-- Run headless: firebeat.exe bm3 -video none -nodebug -sound none -autoboot_script this.
--   CORE_OUT  directory: ata.txt "seconds frame W<reg>|C<reg>|D<addr> data", ppc_io.txt
--             "frame R|W addr data mask" (not the sensors or YMZ), frames.txt, counts.txt
--   CORE_TO   frame to exit at
--   CORE_EVENTS "frame:port:mask:len,..." inputs to press (as popn_spu.lua)
--   CORE_SNAP  a snapshot every this many frames (0: only at the end)
local out = os.getenv("CORE_OUT")
local to  = tonumber(os.getenv("CORE_TO") or "6000")
local snap_every = tonumber(os.getenv("CORE_SNAP") or "0")
local pressed, held = {}, {}
for f, port, mask, len in (os.getenv("CORE_EVENTS") or ""):gmatch("(%d+):(%w+):(%x+):(%d+)") do
    pressed[#pressed + 1] = { f = tonumber(f), port = ":" .. port, mask = tonumber(mask, 16), len = tonumber(len) }
end
local m   = manager.machine
local ppc = m.devices[":maincpu"]
local spu = m.devices[":audiocpu"]
local pp  = ppc.spaces["program"]
local sp  = spu.spaces["program"]
bm3subs = {}
local f_now = 0
local fa = assert(io.open(out .. "/ata.txt", "w"))
local fp = assert(io.open(out .. "/ppc_io.txt", "w"))
local ff = assert(io.open(out .. "/frames.txt", "w"))
local cnt = {}
local function inc(k) cnt[k] = (cnt[k] or 0) + 1 end
local tf = {}
-- SPU ATA cs0 300000-30000F, cs1 340000-34000F
bm3subs[#bm3subs+1] = sp:install_write_tap(0x300000, 0x30000f, "ata0w", function(o, d, mk)
    local r = (o - 0x300000) >> 1
    if r == 0 then inc("ata_data_w") return end
    tf[r] = d
    fa:write(string.format("%.6f %d W%d %04X\n", m.time:as_double(), f_now, r, d))
    if r == 7 then inc(string.format("ata_cmd_%02X", d & 0xff)) end
end)
bm3subs[#bm3subs+1] = sp:install_read_tap(0x300000, 0x30000f, "ata0r", function(o, d, mk)
    local r = (o - 0x300000) >> 1
    if r == 0 then inc("ata_data_r") else inc("ata_r" .. r) end
end)
bm3subs[#bm3subs+1] = sp:install_write_tap(0x340000, 0x34000f, "ata1w", function(o, d, mk)
    fa:write(string.format("%.6f %d C%d %04X\n", m.time:as_double(), f_now, (o - 0x340000) >> 1, d))
end)
bm3subs[#bm3subs+1] = sp:install_write_tap(0x240000, 0x260001, "dmaw", function(o, d, mk)
    fa:write(string.format("%.6f %d D%06X %04X\n", m.time:as_double(), f_now, o, d))
end)
local function ptap(lo, hi, name)
    bm3subs[#bm3subs+1] = pp:install_read_tap(lo, hi, name .. "r", function(o, d, mk)
        inc(name .. "_r")
        if name ~= "sensor" and name ~= "ymz" then fp:write(string.format("%d R %08X %08X %08X\n", f_now, o, d, mk)) end
    end)
    bm3subs[#bm3subs+1] = pp:install_write_tap(lo, hi, name .. "w", function(o, d, mk)
        inc(name .. "_w")
        fp:write(string.format("%d W %08X %08X %08X\n", f_now, o, d, mk))
    end)
end
ptap(0x70000000, 0x70000fff, "midi")
ptap(0x70001000, 0x70001fff, "fdc")
ptap(0x70008000, 0x7000807f, "spectrum")
ptap(0x7d000400, 0x7d000403, "ymz")
ptap(0x7d000340, 0x7d00035f, "sensor")
ptap(0x7d000330, 0x7d00033f, "x330")
bm3subs[#bm3subs+1] = emu.add_machine_frame_notifier(function()
    f_now = m.screens[":screen"]:frame_number()
    if f_now % 100 == 0 then
        ff:write(string.format("%d %08X %06X\n", f_now, ppc.state["PC"].value, spu.state["PC"].value)); ff:flush()
    end
    for _, p in ipairs(pressed) do
        if f_now == p.f then m.ioport.ports[p.port]:field(p.mask):set_value(1); held[p] = f_now + p.len end
        if held[p] and f_now >= held[p] then m.ioport.ports[p.port]:field(p.mask):set_value(0); held[p] = nil end
    end
    if snap_every > 0 and f_now > 0 and f_now % snap_every == 0 and f_now < to then m.video:snapshot() end
    if f_now >= to then
        local fc = assert(io.open(out .. "/counts.txt", "w"))
        local ks = {}
        for k in pairs(cnt) do ks[#ks+1] = k end
        table.sort(ks)
        for _, k in ipairs(ks) do fc:write(k .. " " .. cnt[k] .. "\n") end
        fc:close(); fa:close(); fp:close(); ff:close()
        m.video:snapshot()
        m:exit()
    end
end)
