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
local BROADCAST_THROTTLE_S = 30
local MAX_CHANNEL_SLOTS    = 10  -- WoW 3.3.5 caps joined channels at 10
-- Slot management (see forceLastSlot below). We only act once the channel
-- list has stopped changing, because the server keeps joining channels for a
-- while after PLAYER_ENTERING_WORLD and every one of those changes the answer.
local PAD_CHANNEL_NAME     = "ALCPad"
local LIST_SETTLE_S        = 5   -- list must be quiet this long before we act
local JOIN_MAX_WAIT_S      = 45  -- ...but never wait longer than this to join
local TICK_S               = 2   -- settle-watch poll interval
local STEP_DELAY_S         = 3   -- gap between the leave/pad/rejoin steps
local MAX_REORDER_TRIES    = 2   -- per session
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
    if arg9 == CHANNEL_NAME or arg9 == PAD_CHANNEL_NAME then return true end
    return false
end

-- Forward declaration so doJoin can fire a broadcast immediately after
-- joining the channel (broadcast itself is defined later because it uses
-- safeSend / channelId).
local broadcast

-- ---------------------------------------------------------------------------
-- Channel slot placement
--
-- Goal: ALCSync is the LAST channel, so it never steals /1 and never sits at
-- the top of the Channels list. WotLK 3.3.5 gives us no direct lever for
-- this - MoveChannelUp/MoveChannelDown only exist from Cataclysm on, and are
-- nil here - so we work with the one rule the client does follow: a joining
-- channel takes the LOWEST FREE slot.
--
-- That means placement is purely a question of WHEN we join. Join before the
-- server has added its own channels (Ascension, Newcomers, zone channels) and
-- we get slot 1; join after them and we land at the end. A fixed delay loses
-- that race on slow logins, so we wait for the channel list to go quiet
-- instead, and repair the slot afterwards if we still ended up mid-list.
-- ---------------------------------------------------------------------------

local function occupiedSlots()
    local count, maxSlot = 0, 0
    for i = 1, MAX_CHANNEL_SLOTS do
        local id = GetChannelName(i)
        if id and id > 0 then
            count   = count + 1
            maxSlot = i
        end
    end
    return count, maxSlot
end

local function ourSlot()
    local id = GetChannelName(CHANNEL_NAME)
    if id and id > 0 then return id end
    return nil
end

local function isLastSlot()
    local slot = ourSlot()
    if not slot then return false end
    local _, maxSlot = occupiedSlots()
    return slot >= maxSlot
end

-- Kept for clients that DO expose the reorder API (Cataclysm-era cores, or a
-- private-server backport). No-op on stock 3.3.5, where MoveChannelDown is nil.
local function pushChannelDown()
    if type(MoveChannelDown) ~= "function" then return end
    local slot = ourSlot()
    if not slot then return end
    channelId = slot
    for _ = 1, MAX_CHANNEL_SLOTS do
        local nextId = GetChannelName(slot + 1)
        if not nextId or nextId == 0 then break end
        MoveChannelDown(slot)
        local moved = ourSlot()
        -- Bail if the move did not take, so we never spin or shuffle the
        -- other channels around.
        if not moved or moved <= slot then break end
        slot = moved
        channelId = slot
    end
end

local function removeFromChatFrames(name)
    for i = 1, NUM_CHAT_WINDOWS do
        local frame = _G["ChatFrame" .. i]
        if frame then ChatFrame_RemoveChannel(frame, name) end
    end
end

local function hideAndAdopt(id)
    channelId = id
    removeFromChatFrames(CHANNEL_NAME)
    pushChannelDown()
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

-- The pad is a throwaway channel whose only job is to occupy the slot we free
-- during a re-slot. Nothing is ever sent to it and it is dropped immediately,
-- but the leave is retried: staying in it would be worse than the problem we
-- are fixing, since it would show up in the Channels list itself.
local function leavePad(retries)
    local pad = GetChannelName(PAD_CHANNEL_NAME)
    if not pad or pad <= 0 then return end
    pcall(LeaveChannelByName, PAD_CHANNEL_NAME)
    if retries and retries > 0 then
        scheduleAfter(STEP_DELAY_S, function() leavePad(retries - 1) end)
    end
end

local reorderRunning = false
local reorderTries   = 0

-- Re-slot ALCSync to the end of the list: leave it, park the pad in the slot
-- we just freed, re-join (which now lands past the last channel), then drop
-- the pad. Correct whether the client leaves a hole behind on leave or shifts
-- the higher channels down - in both cases the re-join lands last.
local function forceLastSlot()
    if reorderRunning or isLastSlot() then return end
    if reorderTries >= MAX_REORDER_TRIES then return end
    local count = occupiedSlots()
    -- Need headroom for the pad; never risk failing to get back into ALCSync.
    if count >= MAX_CHANNEL_SLOTS - 1 then return end
    reorderTries   = reorderTries + 1
    reorderRunning = true

    pcall(LeaveChannelByName, CHANNEL_NAME)
    channelId = nil
    scheduleAfter(STEP_DELAY_S, function()
        JoinTemporaryChannel(PAD_CHANNEL_NAME)
        removeFromChatFrames(PAD_CHANNEL_NAME)
        scheduleAfter(STEP_DELAY_S, function()
            JoinTemporaryChannel(CHANNEL_NAME)
            -- Strip it from the chat frames immediately: the re-join re-adds
            -- ALCSync to every window, and we adopt it only a step later.
            removeFromChatFrames(CHANNEL_NAME)
            scheduleAfter(STEP_DELAY_S, function()
                local id = ourSlot()
                if id then
                    hideAndAdopt(id)
                    broadcast(true)
                end
                leavePad(3)
                reorderRunning = false
            end)
        end)
    end)
end

local function doJoin()
    -- Already in (e.g. post-/reload preserves channel state)?
    local existing = ourSlot()
    if existing then
        hideAndAdopt(existing)
        broadcast(true)  -- force past the 30s throttle so peers see us
        return
    end
    JoinTemporaryChannel(CHANNEL_NAME)
    local id = ourSlot()
    if id then
        hideAndAdopt(id)
        broadcast(true)
    end
end

-- Settle watcher. One reusable frame (a hidden frame runs no OnUpdate, so
-- Show starts it and Hide parks it). Every channel join/leave notice bumps
-- lastChangeTs; once the list has been quiet for LIST_SETTLE_S we either join
-- for the first time or repair our slot, then park the frame again.
local watcher      = CreateFrame("Frame")
local tickAccum    = 0
local lastChangeTs = 0
local watchStartTs = 0
watcher:Hide()

local function onTick()
    if reorderRunning then return end  -- never re-join mid-repair
    local now    = GetTime()
    local quiet  = (now - lastChangeTs) >= LIST_SETTLE_S
    local joined = ourSlot() ~= nil

    if not joined then
        -- Wait for the server to finish adding its own channels so our slot
        -- lands after theirs; JOIN_MAX_WAIT_S keeps a chatty list from
        -- deferring the version handshake forever.
        if quiet or (now - watchStartTs) >= JOIN_MAX_WAIT_S then
            doJoin()
        end
        return
    end

    if not quiet then return end
    if isLastSlot() then
        watcher:Hide()
        return
    end
    forceLastSlot()
    if reorderTries >= MAX_REORDER_TRIES and not reorderRunning then
        watcher:Hide()  -- give up rather than churn channels all session
    end
end

watcher:SetScript("OnUpdate", function(self, dt)
    tickAccum = tickAccum + (dt or 0)
    if tickAccum < TICK_S then return end
    tickAccum = 0
    onTick()
end)

-- Called on login/zone and on every channel-list change.
local function startWatch(listChanged)
    local now = GetTime()
    if listChanged then lastChangeTs = now end
    if reorderRunning then return end
    if not watcher:IsShown() then
        watchStartTs = now
        tickAccum    = 0
        -- Treat the start of the watch as a change: on a fresh login the
        -- server has usually not sent a single channel yet, and joining into
        -- that emptiness is exactly how we end up as channel 1.
        if lastChangeTs == 0 then lastChangeTs = now end
        watcher:Show()
    end
end

local function joinSyncChannel()
    -- Already in from a prior session (/reload)? Adopt straight away so the
    -- handshake works; the watcher still audits our slot afterwards.
    local existing = ourSlot()
    if existing and channelId ~= existing then hideAndAdopt(existing) end
    startWatch(false)
    return channelId
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
    -- Resolve the slot fresh: a cached index goes stale the moment any
    -- lower channel is left, and sending to a stale index would dump the
    -- handshake line into whatever public channel now owns that slot.
    local ch = GetChannelName(CHANNEL_NAME)
    if ch and ch > 0 then
        channelId = ch
        safeSend(PREFIX, payload, "CHANNEL", ch)
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

-- Every join/leave restarts the settle clock: the list is not final while the
-- server is still adding channels, and our slot only means something once it is.
local function onChannelNotice(event, noticeType)
    if noticeType ~= "YOU_JOINED" and noticeType ~= "YOU_LEFT" then return end
    startWatch(true)
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
    ALC.TryRegisterEvent("CHAT_MSG_CHANNEL_NOTICE", onChannelNotice)
    ALC.RegisterEvent("PLAYER_ENTERING_WORLD",   onZoneOrLogin)
    ALC.RegisterEvent("ZONE_CHANGED_NEW_AREA",   onZoneOrLogin)
    ALC.RegisterEvent("PARTY_MEMBERS_CHANGED",   broadcast)
    ALC.RegisterEvent("RAID_ROSTER_UPDATE",      broadcast)
end
