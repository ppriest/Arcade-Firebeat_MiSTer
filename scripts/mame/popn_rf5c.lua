-- SPDX-License-Identifier: GPL-3.0-or-later
-- RF5C400 reference for Pop'n Music: the 68000's register accesses and every wave RAM word the
-- chip reads, for sim/rf5c_tb. Run with -samplerate 44100 and -wavwrite so the .wav is the chip's
-- own samples, unresampled. Through run.lua (MCP mame_run_lua).
--
--   CORE_OUT   output directory:
--              rf5c.txt   "seconds frame R|W offset data mask" (68000 at 400000-400FFF)
--              rf5c_rd.bin  the chip's wave RAM reads, records "<d I4 I2": seconds, byte
--                           address, word. MAME's DMA writes the RAM directly, past any tap,
--                           so these are what the streamed buffers held when read.
--              waveram0.bin the 32 MB at the first register write, little-endian words
--   CORE_TO    frame to exit at

local out = os.getenv("CORE_OUT")
local to  = tonumber(os.getenv("CORE_TO") or "7400")

local m   = manager.machine
local spu = m.devices[":audiocpu"]
local rf  = m.devices[":rf5c400"]
local sp  = spu.spaces["program"]
local rs
for _, s in pairs(rf.spaces) do rs = s end

popnrf_subs = {}

local f_now = 0
local fr = assert(io.open(out .. "/rf5c.txt", "w"))
local fb = assert(io.open(out .. "/rf5c_rd.bin", "wb"))
fr:write("# seconds frame R|W offset data mask\n")
local rbuf, snap = {}, false

local function dump(name)
    local share = m.memory.shares[":rf5c400_ram"]
    local fw = assert(io.open(out .. "/" .. name, "wb"))
    local buf = {}
    for a = 0, share.size - 1, 4 do
        buf[#buf + 1] = string.pack("<I4", share:read_u32(a))
        if #buf == 65536 then fw:write(table.concat(buf)); buf = {} end
    end
    fw:write(table.concat(buf))
    fw:close()
end

local function log(rw, offset, data, mask)
    if not snap then snap = true; dump("waveram0.bin") end
    fr:write(string.format("%.9f %d %s %06X %04X %04X\n", m.time:as_double(), f_now, rw, offset, data, mask))
end
popnrf_subs[#popnrf_subs + 1] = sp:install_read_tap(0x400000, 0x400fff, "rf5c_r",
    function(offset, data, mask) log("R", offset, data, mask) end)
popnrf_subs[#popnrf_subs + 1] = sp:install_write_tap(0x400000, 0x400fff, "rf5c_w",
    function(offset, data, mask) log("W", offset, data, mask) end)
popnrf_subs[#popnrf_subs + 1] = rs:install_read_tap(0, 0x1ffffff, "rf5c_wave",
    function(offset, data, mask)
        rbuf[#rbuf + 1] = string.pack("<dI4I2", m.time:as_double(), offset, data & 0xFFFF)
        if #rbuf == 65536 then fb:write(table.concat(rbuf)); rbuf = {} end
    end)

popnrf_subs[#popnrf_subs + 1] = emu.add_machine_frame_notifier(function()
    f_now = m.screens[":screen"]:frame_number()
    if f_now >= to then
        fb:write(table.concat(rbuf)); fb:close(); fr:close()
        m:exit()
    end
end)
