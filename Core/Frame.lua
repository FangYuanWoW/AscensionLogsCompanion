-- Core/Frame.lua
-- ALC `F`-frame ENCODER (codec overhaul Phase 4). A frame is the deflate input:
-- a tiny header + a sequence of typed records, each one already-AceSerialized.
-- The server slices records back out by type+len. Lets one deflate-with-dict
-- stream span CI + TS + PP records and consolidates the small ones into one row.
--
--   frame  := MAGIC(0xA1) VER(0x01) record*
--   record := type:u8  len:uvarint  body[len]
--
-- Reference twin / server decoder: addons/alc-codec/frame.js.

local ALC = _G.ALC
local F = {}
ALC.Core.Frame = F

F.MAGIC = 0xA1
F.VERSION = 0x01
F.TYPE = { CI = 0x01, PP = 0x02, TS = 0x03, KS = 0x04, KEYFRAME_REF = 0x12 }

local schar, concat, floor = string.char, table.concat, math.floor

-- unsigned LEB128 varint, arithmetic-only (no bit lib dependency)
local function uvarint(out, n)
    n = n % 4294967296
    while n >= 0x80 do
        out[#out + 1] = schar((n % 0x80) + 0x80)
        n = floor(n / 0x80)
    end
    out[#out + 1] = schar(n)
end

-- records: array of { type = <u8>, body = <string> } -> frame string
function F.encode(records)
    local out = { schar(F.MAGIC), schar(F.VERSION) }
    for i = 1, #records do
        local r = records[i]
        out[#out + 1] = schar(r.type % 256)
        uvarint(out, #r.body)
        out[#out + 1] = r.body
    end
    return concat(out)
end

return F
