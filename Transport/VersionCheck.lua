-- Transport/VersionCheck.lua
-- Hidden version-handshake. Two reach paths:
--   1. PARTY/RAID/BATTLEGROUND/GUILD addon-message channels (anyone grouped/guilded with us)
--   2. ALCSync custom temp channel (any ALC user on the realm/faction)
--
-- We broadcast max(localVersion, latestSeen) so a peer who has seen a newer
-- version still tells the rest of the network about it, even if their own
-- install is older. The receiver only cares if the announced number is
-- higher than its own local version.
--
-- Display: a single chat-frame line shown ~10s after zoning, once per
-- session. ALC_Config.latest_seen_version persists across /reload so the
-- prompt re-shows on each session until the user actually updates.

local ALC = _G.ALC
local V = {}
ALC.Transport.VersionCheck = V

local PREFIX            = "ALCver"
local CHANNEL_NAME      = "ALCSync"
local DISPLAY_DELAY_S   = 10
local CHANNEL_JOIN_DELAY_S = 5  -- defer so default channels populate first
local BROADCAST_THROTTLE_S = 30
-- Schema version for the persisted version-check state. Bump this to
-- force-wipe ALC_Config.latest_seen_version on the next load (e.g. after
-- shipping a new addon version where prior test/dev state would mislead
-- the announce check). Independent from Core.Constants.SCHEMA_VERSION
-- which governs the inspect cache.
local VC_SCHEMA_VERSION = 1
-- Note: BATTLEGROUND deliberately omitted. Many private-server cores (incl.
-- some Ascension/Bronzebeard builds) reject it with "Unknown addon chat type"
-- and throw, killing the handler. RAID still reaches everyone in a BG raid.
-- Releases URL is resolved per-tenant at announce time from Core.Branding; it
-- can't be read at file-load because ALC.Profile isn't set until Init.boot().

V.localVersion = 0     -- numeric form, e.g. 0.1.6 -> 106
V.latestSeen   = 0
V.displayed    = false -- session-only latch

local channelId          = nil
local channelJoinScheduled = false
local lastBroadcastTs    = 0
local announceScheduled  = false

-- "0.1.6" -> 0*10000 + 1*100 + 6 = 106
local function versionToInt(s)
    if type(s) ~= "string" then return 0 end
    local maj, min, fix = string.match(s, "^(%d+)%.(%d+)%.(%d+)$")
    if not maj then
        maj, min = string.match(s, "^(%d+)%.(%d+)$")
        fix = "0"
    end
    return (tonumber(maj) or 0) * 10000
         + (tonumber(min) or 0) * 100
         + (tonumber(fix) or 0)
end

local function intToVersion(n)
    if not n or n <= 0 then return "?" end
    local maj = math.floor(n / 10000)
    local min = math.floor((n % 10000) / 100)
    local fix = n % 100
    return string.format("%d.%d.%d", maj, min, fix)
end

-- Suppress "Joined Channel: [N. ALCSync]" / "Left channel" system notices
-- so the channel never surfaces to the user. arg9 in CHAT_MSG_CHANNEL_NOTICE
-- on 3.3.5 carries the channel name.
local function noticeFilter(self, event, arg1, arg2, arg3, arg4, arg5, arg6, arg7, arg8, arg9)
    if arg9 == CHANNEL_NAME then return true end
    return false
end

-- Forward declaration so doJoin can fire a broadcast immediately after
-- joining the channel (broadcast itself is defined later because it uses
-- safeSend / channelId).
local broadcast

-- Move our channel slot to the bottom of /chatlist so ALCSync isn't the
-- first thing players see. Bounded by WoW's 10-channel cap.
local function pushChannelDown()
    if not channelId or channelId <= 0 then return end
    if type(MoveChannelDown) ~= "function" then return end
    for _ = 1, 10 do
        local nextSlot = channelId + 1
        local nextId   = GetChannelName(nextSlot)
        if not nextId or nextId == 0 then break end
        MoveChannelDown(channelId)
        channelId = nextSlot
    end
end

local function hideAndAdopt(id)
    channelId = id
    for i = 1, NUM_CHAT_WINDOWS do
        local frame = _G["ChatFrame" .. i]
        if frame then ChatFrame_RemoveChannel(frame, CHANNEL_NAME) end
    end
    pushChannelDown()
end

local function doJoin()
    -- Already in (e.g. post-/reload preserves channel state)?
    local existing = GetChannelName(CHANNEL_NAME)
    if existing and existing > 0 then
        hideAndAdopt(existing)
        broadcast(true)  -- force past the 30s throttle so peers see us
        return
    end
    JoinTemporaryChannel(CHANNEL_NAME)
    local id = GetChannelName(CHANNEL_NAME)
    if id and id > 0 then
        hideAndAdopt(id)
        broadcast(true)
    end
end

local function scheduleAfter(delay, fn)
    if C_Timer and C_Timer.After then
        C_Timer.After(delay, fn)
        return
    end
    local elapsed = 0
    local f = CreateFrame("Frame")
    f:SetScript("OnUpdate", function(self, dt)
        elapsed = elapsed + dt
        if elapsed >= delay then
            self:SetScript("OnUpdate", nil)
            fn()
        end
    end)
end

local function joinSyncChannel()
    if channelId and channelId > 0 then
        -- Already joined; re-push in case new default channels appeared after us
        pushChannelDown()
        return channelId
    end
    -- Already in from a prior session? Adopt immediately, no delay needed.
    local existing = GetChannelName(CHANNEL_NAME)
    if existing and existing > 0 then
        hideAndAdopt(existing)
        return channelId
    end
    -- Fresh join: defer so Trade / World / LFG / etc. populate first,
    -- letting our slot land at the bottom of /chatlist naturally.
    if channelJoinScheduled then return nil end
    channelJoinScheduled = true
    scheduleAfter(CHANNEL_JOIN_DELAY_S, function()
        channelJoinScheduled = false
        doJoin()
    end)
    return nil
end

-- 3.3.5 SendAddonMessage does NOT support distribution="CHANNEL" (added in
-- Cataclysm). On WotLK we have to fall back to SendChatMessage with the
-- prefix encoded into the message body. The channel is hidden from every
-- chat frame via ChatFrame_RemoveChannel so nothing actually renders to
-- the user; receivers pick it up via CHAT_MSG_CHANNEL and parse the prefix.
local channelSendBlocked = false
local function safeSend(prefix, payload, kind, target)
    if kind == "CHANNEL" then
        if channelSendBlocked then return end
        local encoded = prefix .. ":" .. payload  -- e.g. "ALCver:VERSION:107"
        local ok = pcall(SendChatMessage, encoded, "CHANNEL", nil, target)
        if not ok then channelSendBlocked = true end
        return
    end
    pcall(SendAddonMessage, prefix, payload, kind, target)
end

broadcast = function(force)
    if V.localVersion <= 0 then return end
    local now = GetTime()
    if not force and (now - lastBroadcastTs) < BROADCAST_THROTTLE_S then return end
    lastBroadcastTs = now

    local advertise = (V.latestSeen > V.localVersion) and V.latestSeen or V.localVersion
    local payload = "VERSION:" .. advertise

    -- Only send to channels we're actually in.
    if GetNumRaidMembers and GetNumRaidMembers() > 0 then
        safeSend(PREFIX, payload, "RAID")
    elseif GetNumPartyMembers and GetNumPartyMembers() > 0 then
        safeSend(PREFIX, payload, "PARTY")
    end
    if IsInGuild and IsInGuild() then
        safeSend(PREFIX, payload, "GUILD")
    end
    if channelId and channelId > 0 then
        safeSend(PREFIX, payload, "CHANNEL", channelId)
    end
end

-- Forward declaration so ingestVersion can fire scheduleAnnounce when a
-- newer version arrives mid-session (not just on the next zone change).
local scheduleAnnounce

-- Shared parser used by both the addon-message and chat-channel paths.
local function ingestVersion(val)
    if type(val) ~= "number" or val <= 0 then return end
    if val > V.localVersion + 100000 then return end  -- sanity cap (+10.0.0)
    if val > V.latestSeen then
        V.latestSeen = val
        _G.ALC_Config = _G.ALC_Config or {}
        ALC_Config.latest_seen_version = val
        -- First time we've heard about a version newer than ours this
        -- session? Schedule the announce now so the user sees it without
        -- waiting for the next loading screen. The announceScheduled +
        -- displayed latches in scheduleAnnounce/maybeAnnounce keep it
        -- single-fire.
        if val > V.localVersion and not V.displayed and scheduleAnnounce then
            scheduleAnnounce()
        end
    end
end

local function onAddonMessage(event, prefix, msg, channel, sender)
    if prefix ~= PREFIX or not msg then return end
    local cmd, valStr = string.match(msg, "^(%w+):(.+)$")
    if cmd ~= "VERSION" then return end
    ingestVersion(tonumber(valStr))
end

-- CHAT_MSG_CHANNEL handler for the SendChatMessage-encoded path. Messages
-- look like "ALCver:VERSION:107". We don't bother filtering by channel
-- index - any message matching our prefix shape is ours, and the sanity
-- cap blocks anyone trying to inject a fake new version via /say etc.
local function onChatChannel(event, msg, sender)
    if type(msg) ~= "string" then return end
    local prefixPart, body = string.match(msg, "^(ALCver):(.+)$")
    if prefixPart ~= PREFIX or not body then return end
    local cmd, valStr = string.match(body, "^(%w+):(.+)$")
    if cmd ~= "VERSION" then return end
    ingestVersion(tonumber(valStr))
end

-- Clickable-URL plumbing. WoW 3.3.5 has no native browser handoff, so the
-- canonical pattern is a custom hyperlink that pops a copy-paste box.
StaticPopupDialogs["ALC_COPY_URL"] = {
    text = "Press Ctrl+C to copy, then Esc to close:",
    button1 = OKAY,
    hasEditBox = true,
    editBoxWidth = 540,
    OnShow = function(self)
        -- The 3.3.5 StaticPopup template auto-sizes the dialog off
        -- editBoxWidth (popup width = editBoxWidth + 40). Manually
        -- overriding self:SetWidth exposes the hidden MoneyInputFrame, so
        -- just trust the template and only touch the editbox content.
        local eb = _G[self:GetName() .. "EditBox"]
        if eb and self.data then
            eb:SetText(self.data)
            eb:HighlightText()
            eb:SetFocus()
            eb:SetCursorPosition(0)
        end
    end,
    EditBoxOnEnterPressed  = function(self) self:GetParent():Hide() end,
    EditBoxOnEscapePressed = function(self) self:GetParent():Hide() end,
    OnAccept = function() end,
    timeout = 0, whileDead = true, hideOnEscape = true, preferredIndex = 3,
}

local urlHookInstalled = false
local function installUrlHook()
    if urlHookInstalled then return end
    urlHookInstalled = true
    local origSetItemRef = SetItemRef
    SetItemRef = function(link, text, button, chatFrame)
        if type(link) == "string" and string.sub(link, 1, 7) == "alcurl:" then
            local url = string.sub(link, 8)
            StaticPopup_Show("ALC_COPY_URL", nil, nil, url)
            return
        end
        return origSetItemRef(link, text, button, chatFrame)
    end
end

function V.maybeAnnounce()
    announceScheduled = false
    if V.displayed then return end
    if V.latestSeen <= V.localVersion then return end
    V.displayed = true
    local localStr   = intToVersion(V.localVersion)
    local remoteStr  = intToVersion(V.latestSeen)
    local RELEASES_URL = ALC.Core.Branding.releasesUrl()
    -- 3.3.5 chat ignores |cff color outside |H hyperlinks (forces a fixed
    -- link color), so the URL is shown as plain white text on its own line
    -- for readability, with a separate yellow clickable on the third line.
    DEFAULT_CHAT_FRAME:AddMessage(
        ALC.Core.Branding.titleRich() .. ": |cffffd200new version v"
        .. remoteStr .. "|r available (you have v" .. localStr .. ")."
    )
    DEFAULT_CHAT_FRAME:AddMessage("|cffffffff" .. RELEASES_URL .. "|r")
    DEFAULT_CHAT_FRAME:AddMessage(
        "|cffffd200|Halcurl:" .. RELEASES_URL .. "|h[Click to copy URL]|h|r"
    )
end

scheduleAnnounce = function()
    if announceScheduled then return end
    announceScheduled = true
    if C_Timer and C_Timer.After then
        C_Timer.After(DISPLAY_DELAY_S, V.maybeAnnounce)
        return
    end
    -- 3.3.5 fallback: OnUpdate timer
    local elapsed = 0
    local f = CreateFrame("Frame")
    f:SetScript("OnUpdate", function(self, dt)
        elapsed = elapsed + dt
        if elapsed >= DISPLAY_DELAY_S then
            self:SetScript("OnUpdate", nil)
            V.maybeAnnounce()
        end
    end)
end

local function onZoneOrLogin()
    joinSyncChannel()
    broadcast()
    scheduleAnnounce()
end

function V.start()
    V.localVersion = versionToInt(ALC.Core.Constants.VERSION)

    _G.ALC_Config = _G.ALC_Config or {}

    -- Schema-version guard: wipe persisted state if the marker mismatches.
    -- Catches stale dev/test values (e.g. a fake VERSION:200 we injected
    -- during testing) and gives us a clean migration path for future
    -- format changes.
    if ALC_Config.vc_schema ~= VC_SCHEMA_VERSION then
        ALC_Config.latest_seen_version = nil
        ALC_Config.vc_schema = VC_SCHEMA_VERSION
    end

    V.latestSeen = tonumber(ALC_Config.latest_seen_version) or 0

    ChatFrame_AddMessageEventFilter("CHAT_MSG_CHANNEL_NOTICE", noticeFilter)
    installUrlHook()

    ALC.RegisterEvent("CHAT_MSG_ADDON",          onAddonMessage)
    ALC.RegisterEvent("CHAT_MSG_CHANNEL",        onChatChannel)
    ALC.RegisterEvent("PLAYER_ENTERING_WORLD",   onZoneOrLogin)
    ALC.RegisterEvent("ZONE_CHANGED_NEW_AREA",   onZoneOrLogin)
    ALC.RegisterEvent("PARTY_MEMBERS_CHANGED",   broadcast)
    ALC.RegisterEvent("RAID_ROSTER_UPDATE",      broadcast)
end
