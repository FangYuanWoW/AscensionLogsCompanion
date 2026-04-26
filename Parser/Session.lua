-- Parser/Session.lua
-- Session UUID generation + persistence. One session per PLAYER_LOGIN.

local ALC = _G.ALC
local S = {}
ALC.Parser.Session = S

-- Cheap UUID-like identifier. Not cryptographic.
local function genId()
    local chars = "abcdefghijklmnopqrstuvwxyz0123456789"
    local parts = {}
    for i = 1, 12 do
        local n = math.random(1, #chars)
        parts[i] = chars:sub(n, n)
    end
    return tostring(time()) .. "-" .. table.concat(parts)
end

function S.init()
    _G.ALC_LocalState = _G.ALC_LocalState or {}
    ALC_LocalState.session_id = genId()
    ALC_LocalState.session_started_at = time() * 1000
    ALC_LocalState.last_own_ci_snapshot_serial = 0
end

function S.id()
    return (_G.ALC_LocalState or {}).session_id
end
