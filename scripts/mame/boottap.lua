-- SPDX-License-Identifier: GPL-3.0-or-later
-- Device accesses from power-on, for sim/board_tb's boot run. Driven by scripts/mame_boot_capture.py
-- through run.lua.
--
-- io.txt: every PPC access to the ranges ppcwin.lua taps (the 403's serial port, firebeat_map's
-- devices), "R|W addr mask data", and at the end of each frame a line "F frame pc".
-- Stops after CORE_FRAMES frames.
--
--   CORE_OUT     output directory
--   CORE_FRAMES  frames to run
--   CORE_EVENTS  "frame:port:mask:len,..." inputs to press (as ppcwin.lua)

local out    = os.getenv("CORE_OUT")
local frames = tonumber(os.getenv("CORE_FRAMES") or "600")
local events = os.getenv("CORE_EVENTS") or ""

local m   = manager.machine
local cpu = m.devices[":maincpu"]
local sp  = cpu.spaces["program"]

boottap_subs = {}
boottap_err = nil

local pressed, held = {}, {}
for f, port, mask, len in events:gmatch("(%d+):(%w+):(%x+):(%d+)") do
    pressed[#pressed + 1] = { f = tonumber(f), port = ":" .. port, mask = tonumber(mask, 16), len = tonumber(len) }
end

local iof = assert(io.open(out .. "/io.txt", "w"))
iof:setvbuf("full")
local function log_access(rw, offset, data, mask)
    local ok, e = pcall(function() iof:write(string.format("%s %08X %08X %08X\n", rw, offset, mask, data)) end)
    if not ok and not boottap_err then boottap_err = tostring(e) end
end

for _, r in ipairs({ { 0x40000000, 0x4000000f }, { 0x70000000, 0x7ff7ffff } }) do
    boottap_subs[#boottap_subs + 1] = sp:install_read_tap(r[1], r[2], "boottap_r" .. r[1],
        function(offset, data, mask) log_access("R", offset, data, mask) end)
    boottap_subs[#boottap_subs + 1] = sp:install_write_tap(r[1], r[2], "boottap_w" .. r[1],
        function(offset, data, mask) log_access("W", offset, data, mask) end)
end

boottap_subs[#boottap_subs + 1] = emu.add_machine_frame_notifier(function()
    local f = m.screens[":screen"]:frame_number()
    for _, p in ipairs(pressed) do
        if f == p.f then m.ioport.ports[p.port]:field(p.mask):set_value(1); held[p] = f + p.len end
        if held[p] and f >= held[p] then m.ioport.ports[p.port]:field(p.mask):set_value(0); held[p] = nil end
    end
    iof:write(string.format("F %d %08X\n", f, cpu.state["PC"].value))
    if boottap_err then print("BOOTTAP_ERROR " .. boottap_err) end
    if f >= frames then
        iof:close()
        print("BOOTTAP_DONE " .. f)
        m:exit()
    end
end)
print("BOOTTAP_ARMED")
