-- Core/Transport8.lua
-- ALC transport codec `c1`: raw 8-bit byte-stuffing for the WoWCombatLog.txt
-- fail-reason field, replacing base64 (Core/Base64.lua) on the c1 path.
--
-- Byte envelope proven by the 2026-05-30 probe: 0x80-0xFF + most printable
-- bytes survive raw; "(0x22) and \(0x5C) are escaped by the GAME (\" \\) and the
-- server un-escapes them, so they are NOT stuffed here; 0x00 / 0x0A / 0x0D must
-- never appear raw and are stuffed behind ESC (0x7F). | (0x7C) confirmed safe
-- raw including ||/|c/|H adjacency, so it is NOT stuffed.
--
-- Measured ~23.5% smaller on-disk than base64 (+2.3% vs +33.7%). Gated behind
-- ALC_Config.ci_transport_c1; OFF by default until the server c1 decoder ships.
-- Reference twin: addons/alc-codec/transport8.js (the server decodes with it).

local ALC = _G.ALC
local T = {}
ALC.Core.Transport8 = T

local ESC = 127            -- 0x7F DEL (probe-confirmed clean)
local STUFF   = { [0] = 64, [10] = 65, [13] = 66, [127] = 67 }   -- raw -> tag
local UNSTUFF = { [64] = 0, [65] = 10, [66] = 13, [67] = 127 }   -- tag -> raw
local schar, sbyte, concat = string.char, string.byte, table.concat

-- Encode raw bytes into field-safe bytes (before the game's own CSV escaping).
function T.encode(data)
    if type(data) ~= "string" then return nil end
    local out, n = {}, 0
    for i = 1, #data do
        local b = sbyte(data, i)
        local tag = STUFF[b]
        if tag then
            n = n + 1; out[n] = schar(ESC)
            n = n + 1; out[n] = schar(tag)
        else
            n = n + 1; out[n] = schar(b)
        end
    end
    return concat(out)
end

-- Inverse of encode(). Returns nil on a malformed escape sequence.
function T.decode(str)
    if type(str) ~= "string" then return nil end
    local out, n, i, len = {}, 0, 1, #str
    while i <= len do
        local b = sbyte(str, i)
        if b == ESC then
            i = i + 1
            if i > len then return nil end
            local raw = UNSTUFF[sbyte(str, i)]
            if not raw then return nil end
            n = n + 1; out[n] = schar(raw)
        else
            n = n + 1; out[n] = schar(b)
        end
        i = i + 1
    end
    return concat(out)
end

return T
