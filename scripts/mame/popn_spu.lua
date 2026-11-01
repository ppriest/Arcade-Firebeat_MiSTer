-- SPDX-License-Identifier: GPL-3.0-or-later
-- Pop'n Music SPU board reference: every 68000 access outside its ROM and RAM, every PPC
-- access to the dual-port RAM, and a per-frame summary. Through run.lua (MCP mame_run_lua).
--
--   CORE_OUT     output directory:
--                spu.txt    "seconds frame side R|W addr data mask"; side P (PPC, 74000000-)
--                           or S (68000: DPRAM, ATA, DMA, bank, IRQ ack, LEDs, DSW)
--                rf5c.txt   "seconds frame R|W offset data mask" (68000 at 400000-400FFF)
--                frames.txt "frame ppc_pc m68k_pc spu_lines rf5c_lines" every frame
--                waveram.bin the RF5C400's 32 MB at CORE_TO, little-endian words
--   CORE_TO      frame to exit at
--   CORE_EVENTS  "frame:port:mask:len,..." inputs to press

local out    = os.getenv("CORE_OUT")
local to     = tonumber(os.getenv("CORE_TO") or "9000")
local events = os.getenv("CORE_EVENTS") or ""

local m   = manager.machine
local ppc = m.devices[":maincpu"]
local spu = m.devices[":audiocpu"]
local pp  = ppc.spaces["program"]
local sp  = spu.spaces["program"]

-- globals: dropped subscriptions stop firing (LESSONS_LEARNED, Lua section)
popnspu_subs = {}

local pressed, held = {}, {}
for f, port, mask, len in events:gmatch("(%d+):(%w+):(%x+):(%d+)") do
    pressed[#pressed + 1] = { f = tonumber(f), port = ":" .. port, mask = tonumber(mask, 16),
                              len = tonumber(len) }
end

local f_now, n_spu, n_rf = 0, 0, 0
local fs = assert(io.open(out .. "/spu.txt", "w"))
local fr = assert(io.open(out .. "/rf5c.txt", "w"))
local ff = assert(io.open(out .. "/frames.txt", "w"))
fs:write("# seconds frame side R|W addr data mask\n")
fr:write("# seconds frame R|W offset data mask\n")
ff:write("# frame ppc_pc m68k_pc spu_lines rf5c_lines\n")

local function tap(space, lo, hi, name, side, file)
    local function log(rw, offset, data, mask)
        if file == fr then
            n_rf = n_rf + 1
            fr:write(string.format("%.9f %d %s %06X %04X %04X\n", m.time:as_double(), f_now, rw, offset, data, mask))
        else
            n_spu = n_spu + 1
            fs:write(string.format("%.9f %d %s %s %08X %08X %08X\n", m.time:as_double(), f_now, side, rw, offset, data, mask))
        end
    end
    popnspu_subs[#popnspu_subs + 1] = space:install_read_tap(lo, hi, name .. "_r",
        function(offset, data, mask) log("R", offset, data, mask) end)
    popnspu_subs[#popnspu_subs + 1] = space:install_write_tap(lo, hi, name .. "_w",
        function(offset, data, mask) log("W", offset, data, mask) end)
end

-- firebeat.cpp spu_map: 200000-34000F are the board's registers, DPRAM and ATA
tap(pp, 0x74000000, 0x740003ff, "ppc_dpram", "P", fs)
tap(sp, 0x200000, 0x34000f, "spu_io", "S", fs)
tap(sp, 0x400000, 0x400fff, "rf5c", "S", fr)

popnspu_subs[#popnspu_subs + 1] = emu.add_machine_frame_notifier(function()
    f_now = m.screens[":screen"]:frame_number()
    ff:write(string.format("%d %08X %06X %d %d\n", f_now, ppc.state["PC"].value, spu.state["PC"].value, n_spu, n_rf))
    n_spu, n_rf = 0, 0
    for _, p in ipairs(pressed) do
        if f_now == p.f then m.ioport.ports[p.port]:field(p.mask):set_value(1); held[p] = f_now + p.len end
        if held[p] and f_now >= held[p] then m.ioport.ports[p.port]:field(p.mask):set_value(0); held[p] = nil end
    end
    if f_now >= to then
        fs:close(); fr:close(); ff:close()
        local share = m.memory.shares[":rf5c400_ram"]
        local fw = assert(io.open(out .. "/waveram.bin", "wb"))
        local buf = {}
        for a = 0, share.size - 1, 4 do
            buf[#buf + 1] = string.pack("<I4", share:read_u32(a))
            if #buf == 65536 then fw:write(table.concat(buf)); buf = {} end
        end
        fw:write(table.concat(buf))
        fw:close()
        m:exit()
    end
end)
