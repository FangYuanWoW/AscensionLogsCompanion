-- Core/Serialize.lua
-- Lua-only serializer with optional AceSerializer + LibDeflate path.
--
-- The Ace path is preferred for production (more compact, established
-- format). The fallback path is a custom string format that requires no
-- external libs - useful for development/testing before libs are vendored.

local ALC = _G.ALC
local S = {}
ALC.Core.Serialize = S

local function libs()
    if not LibStub then return {} end
    return {
        ser = LibStub:GetLibrary("AceSerializer-3.0", true),
        deflate = LibStub:GetLibrary("LibDeflate", true),
    }
end

--------------------------------------------------------------------------------
-- Fallback custom serializer (no external libs).
-- Format: simple recursive descent producing a string of the form
--   T{key1=value1;key2=value2;...}
-- where keys are unquoted identifiers and values are:
--   - numbers: literal n123 or f1.5
--   - booleans: t / f / nil
--   - strings: s"..."  (with backslash escaping for " and \)
--   - tables: T{...} recursively
-- The format is base64-safe-friendly (no |, no comma, no colon).
--------------------------------------------------------------------------------

local function escapeStr(s)
    return s:gsub('\\', '\\\\'):gsub('"', '\\"'):gsub('\n', '\\n')
end

local function serialize(v)
    local t = type(v)
    if t == "number" then
        if v == math.floor(v) then return "n" .. tostring(v) end
        return "f" .. tostring(v)
    elseif t == "string" then
        return 's"' .. escapeStr(v) .. '"'
    elseif t == "boolean" then
        return v and "t" or "f"
    elseif t == "nil" then
        return "z"
    elseif t == "table" then
        local parts = {}
        -- Sort keys for stable output (helps content-hash dedup)
        local keys = {}
        for k in pairs(v) do keys[#keys + 1] = k end
        table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
        for _, k in ipairs(keys) do
            local kt = type(k)
            local kStr
            if kt == "number" then
                kStr = "[" .. tostring(k) .. "]"
            else
                kStr = tostring(k)
            end
            parts[#parts + 1] = kStr .. "=" .. serialize(v[k])
        end
        return "T{" .. table.concat(parts, ";") .. "}"
    else
        return "?"  -- functions, userdata, etc. skipped
    end
end

--------------------------------------------------------------------------------
-- Public API
--------------------------------------------------------------------------------

-- Serialize a CI struct to a binary string ready for base64 encoding.
-- Uses Ace+Deflate if available, falls back to custom serializer.
function S.serializeCI(ci)
    if not ci then return nil end
    local l = libs()
    if l.ser and l.deflate then
        local s = l.ser:Serialize(ci)
        return l.deflate:CompressDeflate(s, { level = 5 })
    end
    -- Fallback: custom Lua serializer, no compression.
    return serialize(ci)
end

-- Inverse of serializeCI. Used by server-side parser; addon side rarely
-- deserializes its own output.
function S.deserializeCI(blob)
    if not blob then return nil end
    local l = libs()
    if l.ser and l.deflate then
        local decompressed = l.deflate:DecompressDeflate(blob)
        if not decompressed then return nil end
        local ok, ci = l.ser:Deserialize(decompressed)
        if not ok then return nil end
        return ci
    end
    -- Fallback parser is intentionally NOT implemented in the addon.
    -- The custom serializer's format is documented; server-side parser
    -- handles the demux + parse. Returning nil here is fine; addon
    -- doesn't need to round-trip its own output during normal operation.
    return nil
end

-- Indicate which path is active. Useful for /alc status output.
function S.activePath()
    local l = libs()
    if l.ser and l.deflate then return "ace" end
    return "fallback"
end
