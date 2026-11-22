-- SPDX-License-Identifier: GPL-3.0-or-later
-- The GCU's VRAM and the screen a few frames after a savestate loads (MAME -state N). Through
-- run.lua.
--   CORE_OUT    directory: vram.raw (m_vram, host-order 32-bit words), snap.png
--   CORE_AFTER  frames to run after the load first (default 3)
local out   = os.getenv("CORE_OUT")
local after = tonumber(os.getenv("CORE_AFTER") or "3")
local m     = manager.machine
local scr   = m.screens[":screen"]

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

local n = 0
vram_state_sub = emu.add_machine_frame_notifier(function()
    n = n + 1
    if n == after then
        local f = assert(io.open(out .. "/vram.raw", "wb"))
        f:write(vram:read_block(0, vram.size * vram.count))
        f:close()
        scr:snapshot(out .. "/snap.png")
    end
    if n == after + 2 then
        m:exit()
    end
end)
