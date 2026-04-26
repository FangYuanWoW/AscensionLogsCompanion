-- Core/Hash.lua
-- Cheap content-hash for CI snapshot-change detection. Avoids reserializing
-- unchanged CIs. Not cryptographic; collisions are harmless (false-negative
-- means an extra broadcast; false-positive means a skipped broadcast within
-- the same hash value, also harmless given 5 min rescan interval).

local ALC = _G.ALC
local H = {}
ALC.Core.Hash = H

-- FNV-1a 32-bit. Works on strings.
function H.fnv1a(s)
    if type(s) ~= "string" then return 0 end
    local h = 2166136261
    for i = 1, #s do
        h = bit.bxor(h, s:byte(i))
        h = (h * 16777619) % 4294967296
    end
    return h
end

-- Canonical stringification for a CI struct, then hash.
-- Order-stable via sorted keys at every table level.
local function canon(v)
    local t = type(v)
    if t == "table" then
        local keys = {}
        for k in pairs(v) do keys[#keys + 1] = tostring(k) end
        table.sort(keys)
        local parts = {}
        for _, k in ipairs(keys) do
            parts[#parts + 1] = k .. "=" .. canon(v[k])
        end
        return "{" .. table.concat(parts, ",") .. "}"
    elseif t == "string" then
        return '"' .. v .. '"'
    else
        return tostring(v)
    end
end

function H.hashCI(ci)
    return H.fnv1a(canon(ci))
end
