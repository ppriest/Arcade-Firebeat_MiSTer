-- SPDX-License-Identifier: GPL-3.0-or-later
-- Every ATA register access, data words included, from frame CORE_FROM to CORE_TO, then exit.
-- Through run.lua (MCP mame_run_lua).
--
--   CORE_OUT     output directory: ata.txt, "frame R|W cs reg data" (reg = register number,
--                cs 0 the command block, 1 the control block; data 16 bits)
--   CORE_FROM    first frame logged
--   CORE_TO      frame to exit at
--   CORE_EVENTS  "frame:port:mask:len,..." inputs to press (e.g. 9000:IN0:10:6)

local out    = os.getenv("CORE_OUT")
local from   = tonumber(os.getenv("CORE_FROM") or "0")
local to     = tonumber(os.getenv("CORE_TO") or "1000")
local events = os.getenv("CORE_EVENTS") or ""

local m  = manager.machine
local sp = m.devices[":maincpu"].spaces["program"]

-- globals: dropped subscriptions stop firing (LESSONS_LEARNED, Lua section)
atatap_subs = {}

local pressed, held = {}, {}
for f, port, mask, len in events:gmatch("(%d+):(%w+):(%x+):(%d+)") do
    pressed[#pressed + 1] = { f = tonumber(f), port = ":" .. port, mask = tonumber(mask, 16),
                              len = tonumber(len) }
end

local f_now = 0
local fa = assert(io.open(out .. "/ata.txt", "w"))
fa:write("# frame R|W cs reg data\n")

-- CS0 at 7FE00000, CS1 at 7FE80000: 16-bit registers, two to a 32-bit word (ppp_load.lua)
local function log(rw, cs, offset, data, mask)
    if f_now < from then return end
    local base = (offset & 0xc) >> 1
    if mask & 0xffff0000 ~= 0 then fa:write(string.format("%d %s %d %d %04X\n", f_now, rw, cs, base, (data >> 16) & 0xffff)) end
    if mask & 0x0000ffff ~= 0 then fa:write(string.format("%d %s %d %d %04X\n", f_now, rw, cs, base + 1, data & 0xffff)) end
end
for cs, base in pairs({ [0] = 0x7fe00000, [1] = 0x7fe80000 }) do
    atatap_subs[#atatap_subs + 1] = sp:install_read_tap(base, base + 0xf, "atatap_r" .. cs,
        function(offset, data, mask) log("R", cs, offset, data, mask) end)
    atatap_subs[#atatap_subs + 1] = sp:install_write_tap(base, base + 0xf, "atatap_w" .. cs,
        function(offset, data, mask) log("W", cs, offset, data, mask) end)
end

atatap_subs[#atatap_subs + 1] = emu.add_machine_frame_notifier(function()
    f_now = m.screens[":screen"]:frame_number()
    for _, p in ipairs(pressed) do
        if f_now == p.f then m.ioport.ports[p.port]:field(p.mask):set_value(1); held[p] = f_now + p.len end
        if held[p] and f_now >= held[p] then m.ioport.ports[p.port]:field(p.mask):set_value(0); held[p] = nil end
    end
    if f_now >= to then fa:close(); m:exit() end
end)
