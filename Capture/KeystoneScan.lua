-- Capture/KeystoneScan.lua
-- Mythic+ keystone lifecycle capture. Fourth ALC chunk family (KS), parallel
-- to CI (combatant info), PP (pet pairs) and TS (telemetry). Unlike TS this is
-- EVENT-driven, not periodic: it emits exactly one "start" record on
-- MYTHIC_PLUS_STARTED and one "complete" record on MYTHIC_PLUS_COMPLETE.
--
-- The complete record's `completed_timed` field carries MYTHIC_PLUS_COMPLETE's
-- arg1 - the authoritative timed-vs-depleted signal. Confirmed both ways by
-- probe: 2026-05-27 Gnomeregan +8 depleted (a1=false) and 2026-05-30 Scarlet
-- Monastery +5 timed (a1=true). See addons/alc-keystone-probe-findings.md.
--
-- Envelope: [[ALC_KS_v1_<sessionId>_<eventId>_<seq>/<total>]]<b64>
--   - eventId is a per-session base36 counter (own counter, independent from
--     CI/PP/TS so the demuxer never collides reassembly groups).
-- Transit: SpellFailedRelay (matches the family prefix [[ALC_, so the relay's
--   landed-evidence + UIErrorsFrame suppression inherit for free; no relay
--   changes needed).
--
-- Ascension-only: the whole C_MythicPlus namespace is absent on Epoch and
-- vanilla, so isAvailable() short-circuits and the module is inert there. No
-- serverType gate beyond the API-presence check is needed (the API IS the
-- gate), but we also bail when ALC.Profile == "epoch" for clarity.
--
-- Affixes / dungeonID / level are Ascension INTERNAL ids (huge numbers, not
-- Blizzard's small ids). Captured raw; the backend resolves names.

local ALC = _G.ALC
local K = {}
ALC.Capture.KeystoneScan = K

local C = ALC.Core.Constants

K.started = false
K.eventCounter = 0
-- Latch driven by the lifecycle events. timer_state mirrors the proposed
-- schema in the findings doc: idle -> pending -> running -> complete.
K.state = {
    timer_state     = "idle",
    countdown_at_ms = nil,
    started_at_ms   = nil,
    completed_at_ms = nil,
    completed_timed = nil,
}

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

-- pcall a no-arg C_MythicPlus getter and return its first result, or nil.
local function callCMP(fnName)
    local ns = _G.C_MythicPlus
    if type(ns) ~= "table" or type(ns[fnName]) ~= "function" then return nil end
    local ok, a, b = pcall(ns[fnName])
    if not ok then return nil end
    return a, b
end

-- Copy a numeric-keyed list into a plain array (defends against the engine
-- handing back a proxy table or extra string keys).
local function copyList(t)
    if type(t) ~= "table" then return nil end
    local out = {}
    for i = 1, #t do out[i] = t[i] end
    if #out == 0 then return nil end
    return out
end

------------------------------------------------------------------------------
-- Availability + scope gate

local function isAvailable()
    if ALC.Profile == "epoch" then return false end
    local ns = _G.C_MythicPlus
    return type(ns) == "table" and type(ns.IsKeystoneActive) == "function"
end

function K.isKeystoneActive()
    if not isAvailable() then return false end
    local active = callCMP("IsKeystoneActive")
    return active and true or false
end

local function shouldPublish()
    if not isAvailable() then return false end
    if not _G.ALC_Config then return false end
    if ALC_Config.keystone_enabled == false then return false end
    if not ALC_Config.is_logger then return false end
    return true
end

------------------------------------------------------------------------------
-- Read the live keystone state into a flat table. Returns nil when no key is
-- active. Shared by both the KS chunk body and the thin CI marker in
-- LocalScan (instanceInfo()).

function K.readActiveKeystone()
    if not K.isKeystoneActive() then return nil end

    local out = { is_active = true }

    local info = callCMP("GetActiveKeystoneInfo")
    if type(info) == "table" then
        out.level             = info.keystoneLevel
        out.dungeon_id        = info.dungeonID
        out.reward_multiplier = info.rewardMultiplier
        out.active_affix_ids  = copyList(info.activeAffixes)
    end

    -- map_id from GetInstanceInfo (different id-space from dungeonID; the
    -- backend keys the friendly zone off this, like it does for CI.instance).
    if type(_G.GetInstanceInfo) == "function" then
        local _n, _t, _d, _dn, _mp, _pd, _dyn, mapId = GetInstanceInfo()
        out.map_id = mapId
    end

    local remaining, budget = callCMP("GetActiveKeystoneTime")
    out.time_remaining_s = remaining
    out.time_budget_s    = budget

    local enc = callCMP("GetActiveKeystoneEncounters")
    if type(enc) == "table" then
        out.encounters_done     = enc.encountersCompleted
        out.encounters_required = enc.encountersRequired
    end

    local trash = callCMP("GetActiveKeystoneTrash")
    if type(trash) == "table" then
        out.trash_done     = trash.trashDead
        out.trash_required = trash.trashRequired
    end

    local champ = callCMP("GetActiveKeystoneChampions")
    if type(champ) == "table" then
        out.champions_done     = champ.championsDead
        out.champions_required = champ.championsRequired
    end

    out.weekly_affix_pool = copyList(callCMP("GetCurrentAffixes"))

    return out
end

------------------------------------------------------------------------------
-- Envelope + transit (mirrors PetPipeline / Telemetry chunkers)

local function buildChunk(sessionId, eventId, seq, total, b64)
    return string.format("%s%s_%s_%d/%d%s%s",
        C.KS_SENTINEL_PREFIX,
        sessionId, eventId, seq, total,
        C.CI_SENTINEL_SUFFIX,
        b64)
end

-- Returns the list of chunk strings emitted (so the caller can track which
-- chunks to watch for landed-evidence), or nil on failure. `priority` routes
-- through the relay's priority lane (drains ahead of the CI/PP/TS ring).
local function enqueuePayload(body, sessionId, eventId, priority)
    local compressed = ALC.Core.Serialize.serializeCI(body)
    if not compressed then
        ALC.Core.Logger.debug("KeystoneScan: serializer returned nil (libs not ready)")
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

-- eventType: "start" | "complete". Builds the record from the current latch
-- state + a live keystone read and pushes it through the relay.
local function publishEvent(eventType)
    if not shouldPublish() then return false end

    local sessionId = (_G.ALC_LocalState or {}).session_id
    if not sessionId then
        ALC.Core.Logger.debug("KeystoneScan: no session_id, skipping " .. eventType)
        return false
    end

    -- The getters stay populated through MYTHIC_PLUS_COMPLETE (the library
    -- doesn't auto-reset on completion - see findings), so a live read at the
    -- "complete" event still yields the final level/encounters/trash/time.
    local keystone = K.readActiveKeystone()

    K.eventCounter = K.eventCounter + 1
    local eventId = toBase36(K.eventCounter)

    local body = {
        schema_version   = C.KS_SCHEMA_VERSION,
        addon_version    = C.VERSION,
        stream           = "keystone",
        event_type       = eventType,
        session_id       = sessionId,
        event_id         = eventId,
        captured_at      = nowMs(),
        captured_by_guid = UnitGUID("player"),
        server           = ALC.Profile or "unknown",
        keystone         = keystone,
        -- Latch correlation timestamps (ms). Let the backend stitch the
        -- start/complete pair and derive run duration.
        countdown_at_ms  = K.state.countdown_at_ms,
        started_at_ms    = K.state.started_at_ms,
        completed_at_ms  = K.state.completed_at_ms,
    }
    local isComplete = (eventType == "complete")
    if isComplete then
        body.completed_timed = K.state.completed_timed
    end

    -- The outcome (complete) record jumps the queue via the priority lane so
    -- it isn't stuck behind a full encounter's CI/TS backlog as the player
    -- leaves the instance.
    local chunks = enqueuePayload(body, sessionId, eventId, isComplete)
    if chunks then
        if ALC.Core.Metrics then ALC.Core.Metrics.inc("keystone_events_queued") end

        -- Drain-INDEPENDENT capture record. The relay drain is DC-fragile (a
        -- disconnect at key-end loses the in-memory priority chunk), and the
        -- metrics counter only persists on clean logout - so neither proves
        -- whether capture fired. This SavedVariablesPerCharacter log records
        -- every captured event the instant it fires; it survives a normal DC
        -- (being booted to char-select flushes SVs) and is the source of truth
        -- for "/alc keystone" and any future re-enqueue-on-login durability.
        _G.ALC_LocalState = _G.ALC_LocalState or {}
        local klog = _G.ALC_LocalState.keystone_log or {}
        klog[#klog + 1] = {
            at         = nowMs(),
            event      = eventType,
            session_id = sessionId,
            event_id   = eventId,
            level      = keystone and keystone.level,
            dungeon_id = keystone and keystone.dungeon_id,
            timed      = body.completed_timed,
            chunk_count = #chunks,
        }
        while #klog > 20 do table.remove(klog, 1) end
        _G.ALC_LocalState.keystone_log = klog
        ALC.Core.Logger.debug(string.format(
            "KeystoneScan enqueued: %s level=%s dungeon=%s timed=%s chunks=%d",
            eventType,
            tostring(keystone and keystone.level),
            tostring(keystone and keystone.dungeon_id),
            tostring(body.completed_timed),
            #chunks))
        if isComplete then
            K.beginOutcomeFlush(chunks, K.state.completed_timed)
        end
        return true
    end
    return false
end

------------------------------------------------------------------------------
-- Outcome flush: priority drain + keepalive + best-effort forced fail-cast,
-- with a toast fired only on confirmed landing. K.pendingOutcome holds the set
-- of outcome chunk strings we're still waiting to see land.

K.pendingOutcome = nil   -- { set = {chunk=true,...}, count = N, timed = bool, deadline = sec }

-- NOTE: a "forced fail-cast" drain (self-casting a harmful spell to manufacture
-- a SPELL_CAST_FAILED out of combat) was prototyped here and REMOVED: every way
-- to programmatically trigger a cast goes through a protected function
-- (CastSpellByName / SpellStopCasting / SpellStopTargeting), which taints from
-- insecure code ("AddOn 'AscensionLogsCompanion' tainted the call of the secure
-- function 'UNKNOWN()'"). Suppressing the message doesn't stop the taint
-- propagating to other secure actions. So the outcome relies on priority lane +
-- keepalive + ORGANIC failed casts; the toast fires only if/when it truly lands.

-- Minimal fading on-screen toast. Lazily built; reused across outcomes.
local toastFrame
local function ensureToast()
    if toastFrame then return toastFrame end
    local f = CreateFrame("Frame", "ALC_KeystoneToast", UIParent)
    f:SetWidth(460); f:SetHeight(44)
    f:SetPoint("TOP", UIParent, "TOP", 0, -200)
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

function K.showToast(text, success)
    local f = ensureToast()
    f.text:SetText(text)
    if success then
        f.text:SetTextColor(0.2, 1.0, 0.3)
    else
        f.text:SetTextColor(1.0, 0.55, 0.2)
    end
    f:SetAlpha(1)
    f:Show()
    f._holdUntil = GetTime() + 4.0   -- full-opacity hold, then fade
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
    if type(_G.PlaySound) == "function" then
        pcall(PlaySound, success and "LEVELUP" or "igQuestFailed")
    end
end

-- Arm the outcome flush after a complete record is enqueued (priority lane).
function K.beginOutcomeFlush(chunks, timed)
    local set, n = {}, 0
    for i = 1, #chunks do set[chunks[i]] = true; n = n + 1 end
    K.pendingOutcome = {
        set      = set,
        count    = n,
        timed    = timed,
        deadline = time() + (C.KS_KEEPALIVE_S or 45),
    }

    -- Keep the relay awake past combat-end so an organic failed cast in the
    -- post-key window (mount, ability on cooldown, "can't do that while moving")
    -- can still carry the priority chunk into the log.
    if _G.ALC_Config and ALC_Config.keystone_keepalive ~= false then
        local relay = ALC.Transport.SpellFailedRelay
        if relay.requestKeepalive then relay.requestKeepalive(C.KS_KEEPALIVE_S) end
    end
end

-- Landed-hook callback: fires for every chunk the relay confirms landed.
-- Match against our pending outcome set; toast once all outcome chunks land.
function K.onChunkLanded(chunk)
    local po = K.pendingOutcome
    if not po or not po.set[chunk] then return end
    po.set[chunk] = nil
    po.count = po.count - 1
    if po.count > 0 then return end

    if ALC.Core.Metrics then ALC.Core.Metrics.inc("keystone_outcomes_landed") end
    if _G.ALC_Config and ALC_Config.keystone_toast ~= false then
        if po.timed then
            K.showToast("Mythic+ Key Outcome (Timed) exported to combat log", true)
        else
            K.showToast("Mythic+ Key Outcome (Depleted) exported to combat log", false)
        end
    end
    K.pendingOutcome = nil
end

------------------------------------------------------------------------------
-- Lifecycle events

local function onCountdown(a1)
    K.state.timer_state     = "pending"
    K.state.countdown_at_ms = nowMs()
    K.state.started_at_ms   = nil
    K.state.completed_at_ms = nil
    K.state.completed_timed = nil
    ALC.Core.Logger.debug("KeystoneScan: countdown started (a1=" .. tostring(a1) .. ")")
end

local function onStarted()
    K.state.timer_state   = "running"
    K.state.started_at_ms = nowMs()
    publishEvent("start")
end

local function onComplete(a1)
    -- a1 is the timed boolean: true = timed (success), false = depleted.
    K.state.timer_state     = "complete"
    K.state.completed_at_ms = nowMs()
    K.state.completed_timed = (a1 == true) or (a1 == 1) or false
    publishEvent("complete")
end

function K.start()
    if K.started then return end
    K.started = true

    if not isAvailable() then
        ALC.Core.Logger.debug("KeystoneScan: C_MythicPlus absent (profile="
            .. tostring(ALC.Profile) .. "), module inert")
        return
    end

    -- Wrap each registration so a missing event name on some client variant
    -- can't abort the others.
    local function reg(event, handler)
        pcall(ALC.RegisterEvent, event, handler)
    end
    reg("MYTHIC_PLUS_COUNTDOWN_STARTED", function(_e, a1) onCountdown(a1) end)
    reg("MYTHIC_PLUS_STARTED",           function() onStarted() end)
    reg("MYTHIC_PLUS_COMPLETE",          function(_e, a1) onComplete(a1) end)

    -- Toast fires only on confirmed landing: hook the relay's landed callback.
    local relay = ALC.Transport.SpellFailedRelay
    if relay and relay.addLandedHook then
        relay.addLandedHook(function(chunk) K.onChunkLanded(chunk) end)
    end

    ALC.Core.Logger.debug("KeystoneScan started (Mythic+ lifecycle capture armed)")
end

------------------------------------------------------------------------------
-- Diagnostics (/alc keystone or future probe hook)

function K.probe(logger)
    local log = logger or ALC.Core.Logger.info
    log("KeystoneScan: started=" .. tostring(K.started)
        .. " available=" .. tostring(isAvailable())
        .. " enabled=" .. tostring(_G.ALC_Config and ALC_Config.keystone_enabled)
        .. " is_logger=" .. tostring(_G.ALC_Config and ALC_Config.is_logger))
    log("Latch: state=" .. tostring(K.state.timer_state)
        .. " timed=" .. tostring(K.state.completed_timed)
        .. " started_at=" .. tostring(K.state.started_at_ms)
        .. " completed_at=" .. tostring(K.state.completed_at_ms))
    local ks = K.readActiveKeystone()
    if ks then
        log("Active key: +" .. tostring(ks.level)
            .. " dungeon=" .. tostring(ks.dungeon_id)
            .. " map=" .. tostring(ks.map_id)
            .. " time=" .. tostring(ks.time_remaining_s) .. "/" .. tostring(ks.time_budget_s)
            .. " enc=" .. tostring(ks.encounters_done) .. "/" .. tostring(ks.encounters_required)
            .. " trash=" .. tostring(ks.trash_done) .. "/" .. tostring(ks.trash_required))
    else
        log("Active key: none")
    end

    -- Drain-independent capture log: proves whether events were captured even
    -- when no KS chunk ever landed in the combat log (DC / no organic fail).
    local klog = (_G.ALC_LocalState or {}).keystone_log
    if klog and #klog > 0 then
        log("Captured events (" .. #klog .. " logged, newest last):")
        local from = math.max(1, #klog - 4)
        for i = from, #klog do
            local e = klog[i]
            log("  [" .. i .. "] " .. tostring(e.event)
                .. " +" .. tostring(e.level)
                .. " dungeon=" .. tostring(e.dungeon_id)
                .. " timed=" .. tostring(e.timed)
                .. " chunks=" .. tostring(e.chunk_count)
                .. " sess=" .. tostring(e.session_id))
        end
    else
        log("Captured events: NONE logged yet (no MYTHIC_PLUS_STARTED/COMPLETE has fired)")
    end
end
