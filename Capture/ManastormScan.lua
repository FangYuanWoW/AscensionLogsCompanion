-- Capture/ManastormScan.lua
-- Manastorm lifecycle capture. Fifth ALC chunk family (MS), parallel to CI, PP,
-- TS and KS. Like KS it is EVENT-driven, not periodic. It emits three record
-- types, each as a small priority chunk:
--   run_started   on ENTER_MANASTORM_RESULT (a1="ENTER_MANASTORM_OK")  -- start time
--   level_cleared on MANASTORM_LEVEL_COMPLETED (a1 = level number)     -- success per level
--   run_failed    on MANASTORM_FAILED                                  -- kicked out / failed
--
-- The Manastorm is a CoA-only scaling scenario (levels 1..N; clear a level to
-- advance, wipe and you're failed/ejected). Proven by probe 2026-06-08 (see
-- state/coa/manastorm-research/API-FINDINGS.md):
--   MANASTORM_LEVEL_COMPLETED(level) fires once per level CLEARED (a1=level);
--   ENTER_MANASTORM_RESULT(result) on entry; MANASTORM_FAILED on a fail;
--   ACTIVE_MANASTORM_UPDATED(prev,new) tracks the current level (new==0 = out).
--
-- Envelope: [[ALC_MS_v1_<sessionId>_<eventId>_<seq>/<total>]]<b64> (own base36
-- eventId counter so reassembly groups never collide with CI/PP/TS/KS).
-- Transit: SpellFailedRelay priority lane (matches family prefix [[ALC_, so
-- landed-evidence + UIErrorsFrame suppression inherit for free). Records fire
-- mid-run, so an organic failed cast carries them almost immediately;
-- MS_KEEPALIVE_S covers the between-levels lull.
--
-- CoA-only: C_Manastorm is absent on Bronzebeard/Epoch, so isAvailable()
-- short-circuits and the module is inert there. The API IS the gate.

local ALC = _G.ALC
local M = {}
ALC.Capture.ManastormScan = M

local C = ALC.Core.Constants

M.started = false
M.eventCounter = 0
-- Most recent boss seen on the current level (for record enrichment). Reset on
-- each ACTIVE_MANASTORM_UPDATED (new level / eject).
M.currentBoss = nil   -- { encounter_id, name, success }
-- Last known active level from ACTIVE_MANASTORM_UPDATED, so run_failed can name
-- the failed level even if the API has already started resetting.
M.currentLevel = nil
-- Stashed ENTER_MANASTORM_RESULT code, attached to the next run_started record.
M.lastEnterResult = nil

------------------------------------------------------------------------------
-- Helpers

local function nowMs()
    return time() * 1000
end

local DIGITS36 = "0123456789abcdefghijklmnopqrstuvwxyz"
local function toBase36(n)
    if n == 0 then return "0" end
    local out, x = "", n
    while x > 0 do
        local r = x - math.floor(x / 36) * 36
        out = DIGITS36:sub(r + 1, r + 1) .. out
        x = math.floor(x / 36)
    end
    return out
end

-- pcall a no-arg C_Manastorm getter and return its first result, or nil.
local function callCM(fnName)
    local ns = _G.C_Manastorm
    if type(ns) ~= "table" or type(ns[fnName]) ~= "function" then return nil end
    local ok, a = pcall(ns[fnName])
    if not ok then return nil end
    return a
end

------------------------------------------------------------------------------
-- Availability + scope gate (CoA-only, by API presence)

local function isAvailable()
    local ns = _G.C_Manastorm
    return type(ns) == "table" and type(ns.IsInManastorm) == "function"
end

function M.isInManastorm()
    if not isAvailable() then return false end
    return callCM("IsInManastorm") == true
end

local function shouldPublish()
    if not isAvailable() then return false end
    if not _G.ALC_Config then return false end
    if ALC_Config.manastorm_enabled == false then return false end
    if not ALC_Config.is_logger then return false end
    return true
end

------------------------------------------------------------------------------
-- Live read (only valid while inside; the API zeroes the instant you're ejected,
-- so read at event time, never poll afterward). Shared by the MS chunk body and
-- the thin CI marker in LocalScan.

function M.readActiveManastorm()
    if not M.isInManastorm() then return nil end
    -- NOTE: GetMaxCompletedLevels is intentionally NOT called here. No-arg it
    -- fails server-side validation ("Script::ValidateInput Invalid argument
    -- count. Expected 1, got 0" -> spammed Error.txt; pcall swallowed it but the
    -- return was empty). It needs an argument (manastorm type/id) we haven't
    -- pinned down. The lifetime PB is informational only; if wanted later,
    -- capture it from the MANASTORM_COMPLETED_LEVELS_UPDATED event instead.
    return {
        is_active      = true,
        level          = callCM("GetActiveLevel"),
        manastorm_id   = callCM("GetActiveManastormID"),
        manastorm_type = callCM("GetActiveManastormType"),
    }
end

------------------------------------------------------------------------------
-- Envelope + transit (mirrors KeystoneScan)

local function buildChunk(sessionId, eventId, seq, total, b64)
    return string.format("%s%s_%s_%d/%d%s%s",
        C.MS_SENTINEL_PREFIX,
        sessionId, eventId, seq, total,
        C.CI_SENTINEL_SUFFIX,
        b64)
end

-- Returns the list of chunk strings emitted, or nil on failure. `priority`
-- routes through the relay's priority lane (drains ahead of the CI/PP/TS ring).
local function enqueuePayload(body, sessionId, eventId, priority)
    local compressed = ALC.Core.Serialize.serializeCI(body)
    if not compressed then
        ALC.Core.Logger.debug("ManastormScan: serializer returned nil (libs not ready)")
        return nil
    end
    local b64 = ALC.Core.Base64.encode(compressed)
    if not b64 then return nil end

    local relay = ALC.Transport.SpellFailedRelay
    local maxBody = C.CHUNK_PAYLOAD_MAX_BYTES
    local total = math.ceil(#b64 / maxBody)
    if total < 1 then total = 1 end
    local chunks = {}
    for seq = 1, total do
        local startIdx = (seq - 1) * maxBody + 1
        local endIdx = math.min(startIdx + maxBody - 1, #b64)
        local chunk = buildChunk(sessionId, eventId, seq, total, b64:sub(startIdx, endIdx))
        chunks[seq] = chunk
        if priority and relay.enqueueFront then
            relay.enqueueFront(chunk)
        else
            relay.enqueue(chunk)
        end
    end
    return chunks
end

-- Build a Manastorm record from a live read + caller-supplied `extra` (merged
-- into the manastorm sub-object: level override, success, boss_name,
-- enter_result, ...) and push it through the relay (priority lane). eventType:
-- "run_started" | "level_cleared" | "run_failed". `toast` (optional) =
-- { text=..., success=bool } shown when all chunks land.
local function publishManastormEvent(eventType, extra, toast)
    if not shouldPublish() then return false end

    local sessionId = (_G.ALC_LocalState or {}).session_id
    if not sessionId then
        ALC.Core.Logger.debug("ManastormScan: no session_id, skipping " .. eventType)
        return false
    end

    local live = M.readActiveManastorm()
    local manastorm = {
        level          = live and live.level,
        level_live     = live and live.level,   -- GetActiveLevel() at event time
        manastorm_id   = live and live.manastorm_id,
        manastorm_type = live and live.manastorm_type,
        max_completed  = live and live.max_completed_levels,
    }
    if extra then for k, v in pairs(extra) do manastorm[k] = v end end

    M.eventCounter = M.eventCounter + 1
    local eventId = toBase36(M.eventCounter)

    local body = {
        schema_version   = C.MS_SCHEMA_VERSION,
        addon_version    = C.VERSION,
        stream           = "manastorm",
        event_type       = eventType,
        session_id       = sessionId,
        event_id         = eventId,
        captured_at      = nowMs(),
        captured_by_guid = UnitGUID("player"),
        server           = ALC.Profile or "unknown",
        manastorm        = manastorm,
    }

    local chunks = enqueuePayload(body, sessionId, eventId, true)
    if chunks then
        if ALC.Core.Metrics then ALC.Core.Metrics.inc("manastorm_events_queued") end

        -- Drain-INDEPENDENT capture record (mirrors keystone_log): survives a DC
        -- and is the source of truth for /alc manastorm even when no chunk lands.
        _G.ALC_LocalState = _G.ALC_LocalState or {}
        local mlog = _G.ALC_LocalState.manastorm_log or {}
        mlog[#mlog + 1] = {
            at           = nowMs(),
            event        = eventType,
            level        = manastorm.level,
            success      = manastorm.success,
            manastorm_id = manastorm.manastorm_id,
            boss_name    = manastorm.boss_name,
            session_id   = sessionId,
            event_id     = eventId,
            chunk_count  = #chunks,
        }
        while #mlog > 20 do table.remove(mlog, 1) end
        _G.ALC_LocalState.manastorm_log = mlog

        ALC.Core.Logger.debug(string.format(
            "ManastormScan enqueued: %s level=%s boss=%s chunks=%d",
            eventType, tostring(manastorm.level),
            tostring(manastorm.boss_name), #chunks))

        if toast then M.beginFlush(chunks, toast) end
        return true
    end
    return false
end

------------------------------------------------------------------------------
-- Flush: priority drain + short keepalive + toast on confirmed landing.
-- M.pendingFlush holds the chunk set we're still waiting to see land + the toast.

M.pendingFlush = nil   -- { set = {chunk=true,...}, count = N, toast = {text,success} }

local toastFrame
local function ensureToast()
    if toastFrame then return toastFrame end
    local f = CreateFrame("Frame", "ALC_ManastormToast", UIParent)
    f:SetWidth(480); f:SetHeight(44)
    f:SetPoint("TOP", UIParent, "TOP", 0, -240)
    f:SetFrameStrata("HIGH")
    local bg = f:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints(f)
    bg:SetTexture(0, 0, 0, 0.55)
    local fs = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    fs:SetPoint("CENTER", f, "CENTER", 0, 0)
    f.text = fs
    f:Hide()
    toastFrame = f
    return f
end

function M.showToast(text, success)
    local f = ensureToast()
    f.text:SetText(text)
    if success then f.text:SetTextColor(0.2, 1.0, 0.3) else f.text:SetTextColor(1.0, 0.55, 0.2) end
    f:SetAlpha(1)
    f:Show()
    f._holdUntil = GetTime() + 4.0
    f:SetScript("OnUpdate", function(self, elapsed)
        if GetTime() < self._holdUntil then return end
        local a = self:GetAlpha() - (elapsed / 1.5)
        if a <= 0 then
            self:Hide()
            self:SetScript("OnUpdate", nil)
        else
            self:SetAlpha(a)
        end
    end)
    if type(_G.PlaySound) == "function" then pcall(PlaySound, success and "LEVELUP" or "igQuestFailed") end
end

function M.beginFlush(chunks, toast)
    local set, n = {}, 0
    for i = 1, #chunks do set[chunks[i]] = true; n = n + 1 end
    M.pendingFlush = { set = set, count = n, toast = toast }

    -- Keep the relay awake briefly so an organic failed cast right after the
    -- event carries the priority chunk even through the between-levels lull.
    if _G.ALC_Config and ALC_Config.manastorm_keepalive ~= false then
        local relay = ALC.Transport.SpellFailedRelay
        if relay.requestKeepalive then relay.requestKeepalive(C.MS_KEEPALIVE_S or 30) end
    end
end

function M.onChunkLanded(chunk)
    local pf = M.pendingFlush
    if not pf or not pf.set[chunk] then return end
    pf.set[chunk] = nil
    pf.count = pf.count - 1
    if pf.count > 0 then return end

    if ALC.Core.Metrics then ALC.Core.Metrics.inc("manastorm_events_landed") end
    if _G.ALC_Config and ALC_Config.manastorm_toast ~= false and pf.toast then
        M.showToast(pf.toast.text, pf.toast.success)
    end
    M.pendingFlush = nil
end

------------------------------------------------------------------------------
-- Lifecycle events

-- ENTER_MANASTORM_RESULT fires at the entry REQUEST, often BEFORE
-- IsInManastorm() flips true and before the level is set - so publishing here
-- yielded an empty/skipped record. Instead we stash the result string and emit
-- run_started from the reliable ACTIVE_MANASTORM_UPDATED(0 -> >=1) entry edge.
local function onEnterResult(result)
    M.lastEnterResult = result
end

local function onLevelCompleted(a1)
    -- a1 = the cleared level number.
    publishManastormEvent("level_cleared", {
        level             = a1,
        success           = true,
        boss_name         = M.currentBoss and M.currentBoss.name,
        boss_encounter_id = M.currentBoss and M.currentBoss.encounter_id,
    }, { text = "Manastorm Level " .. tostring(a1) .. " cleared - exported to combat log", success = true })
end

local function onRunFailed()
    -- MANASTORM_FAILED fires before the ACTIVE_MANASTORM_UPDATED(->0) reset, so
    -- the live read usually still has the failed level; M.currentLevel backstops.
    local level = M.currentLevel
    publishManastormEvent("run_failed", {
        level             = level,
        success           = false,
        boss_name         = M.currentBoss and M.currentBoss.name,
        boss_encounter_id = M.currentBoss and M.currentBoss.encounter_id,
    }, { text = "Manastorm failed at Level " .. tostring(level or "?") .. " - exported to combat log", success = false })
end

local function onActive(a1, a2)
    -- New level (or eject, a2==0): the previous level's boss no longer applies.
    M.currentBoss = nil
    local prev, new = tonumber(a1), tonumber(a2)
    -- prev 0 -> new >=1 is a fresh run start (fires again on each restart).
    -- Emit run_started here: by this edge IsInManastorm() is true and the level
    -- is set, and we carry the stashed ENTER_MANASTORM_RESULT code for context.
    if prev == 0 and new and new >= 1 then
        publishManastormEvent("run_started", { level = new, enter_result = M.lastEnterResult })
    end
    if new and new > 0 then
        M.currentLevel = new
    end
    -- Leave M.currentLevel intact on a2==0 so a MANASTORM_FAILED that arrives
    -- around the same time can still name the level. It is refreshed on the next
    -- run's first transition.
end

local function onEncEnd(id, name, success)
    M.currentBoss = {
        encounter_id = id,
        name         = name,
        success      = (success == 1) or (success == true),
    }
end

local function onBossKill(id, name)
    M.currentBoss = { encounter_id = id, name = name, success = true }
end

function M.start()
    if M.started then return end
    M.started = true

    if not isAvailable() then
        ALC.Core.Logger.debug("ManastormScan: C_Manastorm absent (profile="
            .. tostring(ALC.Profile) .. "), module inert")
        return
    end

    local function reg(event, handler)
        pcall(ALC.RegisterEvent, event, handler)
    end
    reg("ENTER_MANASTORM_RESULT",    function(_e, a1) onEnterResult(a1) end)
    reg("MANASTORM_LEVEL_COMPLETED", function(_e, a1) onLevelCompleted(a1) end)
    reg("MANASTORM_FAILED",          function() onRunFailed() end)
    reg("ACTIVE_MANASTORM_UPDATED",  function(_e, a1, a2) onActive(a1, a2) end)
    reg("ENCOUNTER_END",             function(_e, id, name, _d, _sz, ok) onEncEnd(id, name, ok) end)
    reg("BOSS_KILL",                 function(_e, id, name) onBossKill(id, name) end)

    local relay = ALC.Transport.SpellFailedRelay
    if relay and relay.addLandedHook then
        relay.addLandedHook(function(chunk) M.onChunkLanded(chunk) end)
    end

    ALC.Core.Logger.debug("ManastormScan started (Manastorm lifecycle capture armed)")
end

------------------------------------------------------------------------------
-- Diagnostics (/alc manastorm)

function M.probe(logger)
    local log = logger or ALC.Core.Logger.info
    log("ManastormScan: started=" .. tostring(M.started)
        .. " available=" .. tostring(isAvailable())
        .. " enabled=" .. tostring(_G.ALC_Config and ALC_Config.manastorm_enabled)
        .. " is_logger=" .. tostring(_G.ALC_Config and ALC_Config.is_logger))
    local ms = M.readActiveManastorm()
    if ms then
        log("In Manastorm: level=" .. tostring(ms.level)
            .. " id=" .. tostring(ms.manastorm_id)
            .. " type=" .. tostring(ms.manastorm_type)
            .. " max_completed=" .. tostring(ms.max_completed_levels))
    else
        log("In Manastorm: no")
    end

    local mlog = (_G.ALC_LocalState or {}).manastorm_log
    if mlog and #mlog > 0 then
        log("Captured Manastorm events (" .. #mlog .. " logged, newest last):")
        local from = math.max(1, #mlog - 6)
        for i = from, #mlog do
            local e = mlog[i]
            log("  [" .. i .. "] " .. tostring(e.event)
                .. " level=" .. tostring(e.level)
                .. " success=" .. tostring(e.success)
                .. " boss=" .. tostring(e.boss_name)
                .. " chunks=" .. tostring(e.chunk_count))
        end
    else
        log("Captured Manastorm events: NONE logged yet")
    end
end
