-- Core/Base64.lua
-- Combat-log-safe base64. Alphabet excludes |, comma, colon, double-quote
-- so the encoded payload cannot corrupt WoWCombatLog.txt framing.
-- Alphabet: A-Z a-z 0-9 + - _ (63 chars) + padding '.'

local ALC = _G.ALC
local B = {}
ALC.Core.Base64 = B

-- URL-safe alphabet, 64 chars. Excludes |, comma, colon, double-quote
-- so the encoded output cannot break combat log field framing.
local ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
assert(#ALPHABET == 64, "base64 alphabet must be 64 chars")

local decodeMap = {}
for i = 1, 64 do
    decodeMap[ALPHABET:sub(i, i)] = i - 1
end

function B.encode(data)
    if type(data) ~= "string" then return nil end
    local out = {}
    local len = #data
    local i = 1
    while i <= len do
        local b1 = data:byte(i) or 0
        local b2 = data:byte(i + 1) or 0
        local b3 = data:byte(i + 2) or 0
        local n = b1 * 65536 + b2 * 256 + b3

        local c1 = math.floor(n / 262144) % 64 + 1
        local c2 = math.floor(n / 4096)   % 64 + 1
        local c3 = math.floor(n / 64)     % 64 + 1
        local c4 = n % 64 + 1

        out[#out + 1] = ALPHABET:sub(c1, c1)
        out[#out + 1] = ALPHABET:sub(c2, c2)
        out[#out + 1] = (i + 1 <= len) and ALPHABET:sub(c3, c3) or "."
        out[#out + 1] = (i + 2 <= len) and ALPHABET:sub(c4, c4) or "."

        i = i + 3
    end
    return table.concat(out)
end

function B.decode(str)
    if type(str) ~= "string" then return nil end
    local out = {}
    local len = #str
    local i = 1
    while i <= len do
        local c1 = str:sub(i, i)
        local c2 = str:sub(i + 1, i + 1)
        local c3 = str:sub(i + 2, i + 2)
        local c4 = str:sub(i + 3, i + 3)

        local n1 = decodeMap[c1]
        local n2 = decodeMap[c2]
        local n3 = decodeMap[c3]
        local n4 = decodeMap[c4]

        if not n1 or not n2 then return nil end  -- malformed

        local n = n1 * 262144 + n2 * 4096 + (n3 or 0) * 64 + (n4 or 0)
        out[#out + 1] = string.char(math.floor(n / 65536) % 256)
        if c3 ~= "." and n3 then
            out[#out + 1] = string.char(math.floor(n / 256) % 256)
        end
        if c4 ~= "." and n4 then
            out[#out + 1] = string.char(n % 256)
        end

        i = i + 4
    end
    return table.concat(out)
end
