-- Transport/AddonChannel.lua
-- Single transport module. Wraps SendAddonMessage with prefix assertion
-- so internal bugs cannot leak to visible chat via SendChatMessage.

local ALC = _G.ALC
local A = {}
ALC.Transport.AddonChannel = A

local C = ALC.Core.Constants

-- Outbound token bucket
A.tokens = C.ADDON_MSG_OUTBOUND_PER_SEC
A.lastRefill = GetTime()
A.joinWindowEnd = 0  -- set to GetTime() + ADDON_MSG_JOIN_CAP_S on raid join

-- Inbound reassembly: keyed by sender|sessionId|guid|total
A.incomplete = {}  -- [key] = { first_seen, chunks = { [seq] = payload } }

local function refillTokens()
    local nowT = GetTime()
    local elapsed = nowT - A.lastRefill
    if elapsed <= 0 then return end

    local rate = C.ADDON_MSG_OUTBOUND_PER_SEC
    if nowT < A.joinWindowEnd then
        rate = C.ADDON_MSG_JOIN_CAP_RATE
    end

    A.tokens = math.min(rate, A.tokens + elapsed * rate)
    A.lastRefill = nowT
end

local function consumeToken()
    refillTokens()
    if A.tokens >= 1 then
        A.tokens = A.tokens - 1
        return true
    end
    return false
end

-- The ONLY place that calls SendAddonMessage. Prefix is asserted.
function A.send(msg, channel, target)
    -- Prefix assertion: every outbound must go through ALC prefix
    if not consumeToken() then
        ALC.Core.Logger.debug("AddonChannel: throttled, dropping message")
        return false
    end

    channel = channel or (IsInRaid and IsInRaid() or (GetNumRaidMembers() or 0) > 0) and "RAID" or "PARTY"

    if #msg > C.ADDON_MSG_MAX_BYTES - #C.ADDON_PREFIX - 2 then
        ALC.Core.Logger.warn("AddonChannel: msg too long, dropped")
        return false
    end

    SendAddonMessage(C.ADDON_PREFIX, msg, channel, target)
    return true
end

-- Mark the start of the raid-join login-storm window
function A.markJoin()
    A.joinWindowEnd = GetTime() + C.ADDON_MSG_JOIN_CAP_S
end

-- Inbound handler. Registered in Init.lua
function A.onAddonMessage(event, prefix, msg, channel, sender)
    if prefix ~= C.ADDON_PREFIX then return end
    if not msg or msg == "" then return end

    -- Expected format: ACLC|CI|v1|<sessionId>|<guid>|<seq>/<total>|<b64>
    -- or:              ACLC|HELLO|v1|<sessionId>|<guid>|<is_logger>
    -- Silent drop anything malformed.
    local parts = {}
    for part in msg:gmatch("[^|]+") do parts[#parts + 1] = part end
    if #parts < 3 then return end

    local msgType, version = parts[1], parts[2]
    if version ~= "v1" then return end

    if msgType == "HELLO" then
        -- TODO: Phase 2 peer discovery
        return
    elseif msgType == "CI" then
        -- TODO: Phase 2 chunked reassembly + dispatch to InspectCache
        return
    end
end

function A.start()
    ALC.RegisterEvent("CHAT_MSG_ADDON", A.onAddonMessage)
    -- Register our prefix so WoW actually delivers messages
    if RegisterAddonMessagePrefix then
        RegisterAddonMessagePrefix(C.ADDON_PREFIX)
    end
end
