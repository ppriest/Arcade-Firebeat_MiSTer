-- SPDX-License-Identifier: GPL-3.0-or-later
-- Report the frames in which a VRAM region of the GCU changes, from CORE_FROM to CORE_TO, with
-- inputs pressed on a schedule (as bm3_fdc.lua). Through run.lua.
--   CORE_OUT    directory: watch.txt "frame changed_words nonzero_words"
--   CORE_ROW0, CORE_ROWS, CORE_COL0, CORE_COLS   the region in pixels (1,024-pixel rows)
--   CORE_FROM, CORE_TO, CORE_EVENTS
local out  = os.getenv("CORE_OUT")
local row0 = tonumber(os.getenv("CORE_ROW0"))
local rows = tonumber(os.getenv("CORE_ROWS"))
local col0 = tonumber(os.getenv("CORE_COL0") or "0")
local cols = tonumber(os.getenv("CORE_COLS") or "1024")
local from = tonumber(os.getenv("CORE_FROM") or "0")
local to   = tonumber(os.getenv("CORE_TO"))
local pressed, held = {}, {}
for f, port, mask, len in (os.getenv("CORE_EVENTS") or ""):gmatch("(%d+):(%w+):(%x+):(%d+)") do
    pressed[#pressed + 1] = { f = tonumber(f), port = ":" .. port, mask = tonumber(mask, 16), len = tonumber(len) }
end
local m   = manager.machine
local scr = m.screens[":screen"]

local vram
for i = 0, 100000 do
    local it = emu.item(i)
    if it.size == 0 and it.count == 0 then
        break
    end
    if it.size == 4 and it.count == 8388608 then
        vram = it
        break
    end
end
assert(vram, "no 8,388,608-word 32-bit save item")

-- a 32-bit item word holds two pixels; read each row's words
local function snapshot_region()
    local t = {}
    for r = 0, rows - 1 do
        local w0 = ((row0 + r) * 1024 + col0) // 2
        t[#t + 1] = vram:read_block(w0 * 4, (cols // 2) * 4)
    end
    return t
end

local ff = assert(io.open(out .. "/watch.txt", "w"))
local prev
vram_watch_sub = emu.add_machine_frame_notifier(function()
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
    if f_now >= from then
        local cur = snapshot_region()
        if prev then
            local changed = 0
            for r = 1, rows do
                if cur[r] ~= prev[r] then
                    changed = changed + 1
                end
            end
            if changed > 0 then
                ff:write(string.format("%d %d\n", f_now, changed))
                ff:flush()
            end
        end
        prev = cur
    end
    if f_now >= to then
        ff:close()
        m:exit()
    end
end)
