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
-- Ascension-only: the whole C_MythicPlus namespace is absent on the epoch-
-- family profiles (Epoch + Triumvirate) and vanilla, so isAvailable() short-
-- circuits and the module is inert there. No serverType gate beyond the
-- API-presence check is needed (the API IS the gate), but we also bail on the
-- epoch-family profiles for clarity.
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
    if ALC.Core.Profile.isEpochFamily() then return false end
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
-- Durable per-run records (ALC_KeystoneRuns, SavedVariablesPerCharacter).
--
-- The KS chunks below serve LIVE logging: they ride the combat log and only
-- exist while a logger is present. These records serve the UPLOADER: a plain
-- per-character list of every run this character participates in, written the
-- moment the run starts (a crash mid-run still leaves the attempt on disk),
-- closed on MYTHIC_PLUS_COMPLETE, and re-attached after a disconnect
-- (PLAYER_ENTERING_WORLD polls the live keystone state). The desktop app
-- reads the SavedVariables file from disk and posts new records; dedup is
-- server-side, so records are append-only here and pruned only by the FIFO
-- cap (the open run is never evicted).
--
-- NOT logger-gated: every party member with the addon records their own copy
-- of the run - any one of the five can upload it.

local function shouldRecordRuns()
    if not isAvailable() then return false end
    if _G.ALC_Config and ALC_Config.keystone_enabled == false then return false end
    return true
end

local function runStore()
    local s = _G.ALC_KeystoneRuns
    if type(s) ~= "table" or type(s.runs) ~= "table" then
        s = { schema = C.KS_RUNS_SCHEMA, runs = {} }
        _G.ALC_KeystoneRuns = s
    end
    s.schema = C.KS_RUNS_SCHEMA
    return s
end

-- Newest open run (search from the end; there is at most one by construction).
local function findOpenRun(store)
    for i = #store.runs, 1, -1 do
        if store.runs[i].open then return i, store.runs[i] end
    end
    return nil, nil
end

local function enforceCap(store)
    local cap = C.KS_RUNS_CAP or 200
    while #store.runs > cap do
        local removed = false
        for i = 1, #store.runs do
            if not store.runs[i].open then
                table.remove(store.runs, i)
                removed = true
                break
            end
        end
        if not removed then break end
    end
end

local function rosterUnit(unit)
    if not UnitExists(unit) then return nil end
    local name, realm = UnitName(unit)
    if not name then return nil end
    local _, classToken = UnitClass(unit)
    local _, raceToken = UnitRace(unit)
    return {
        name  = name,
        realm = (realm and realm ~= "" and realm) or nil,
        guid  = UnitGUID(unit),
        class = classToken,
        race  = raceToken,
        level = UnitLevel(unit),
    }
end

-- Player + party1-4 (M+ is 5-man; inside the run the party units are the
-- authoritative roster).
local function captureRoster()
    local out = {}
    local units = { "player", "party1", "party2", "party3", "party4" }
    for i = 1, #units do
        local m = rosterUnit(units[i])
        if m then out[#out + 1] = m end
    end
    return out
end

-- Compact CI subset embedded per roster member: build + gear identity only
-- (drops the pet/instance/arena metadata a run record doesn't need).
local function compactCI(ci)
    if type(ci) ~= "table" then return nil end
    if not (ci.gear or ci.specialization or ci.talents or ci.mystic_enchants) then
        return nil
    end
    return {
        gear            = ci.gear,            -- per-slot item/enchant/gems/suffix
        mystic_enchants = ci.mystic_enchants, -- Ascension: applied + per_slot
        specialization  = ci.specialization,  -- CAO build state
        talents         = ci.talents,         -- epoch-family talent shape
        primary_stat    = ci.primary_stat,    -- classless realms
        game_mode       = ci.game_mode,
    }
end

-- Attach build/gear to roster members: own CI straight from LocalScan, peers
-- from the inspect cache as InspectLoop's rotation lands them. First copy
-- wins (the earliest snapshot is closest to what they ran with); later
-- passes (resume, close) only fill members still missing.
local function enrichRosterCI(run)
    if not run or not run.roster then return end
    local ownGuid = UnitGUID("player")
    for i = 1, #run.roster do
        local m = run.roster[i]
        if not m.ci and m.guid then
            local ci
            if m.guid == ownGuid and ALC.Capture.LocalScan
                    and ALC.Capture.LocalScan.buildLocalCI then
                local ok, own = pcall(ALC.Capture.LocalScan.buildLocalCI,
                    (_G.ALC_LocalState or {}).session_id or "runrec")
                if ok then ci = own end
            else
                local IC = ALC.Capture.InspectCache
                local entry = IC and IC.get and IC.get(m.guid)
                ci = entry and entry.ci
            end
            m.ci = compactCI(ci)
            if m.ci then m.ci_at = nowMs() end
        end
    end
end

-- Death tracking: while a run is open, count UNIT_DIED for roster members.
-- The CLEU handler is registered once and no-ops when no watch is armed.
K.deathWatch = nil   -- { guids = {guid=name}, names = {name=true} }
local cleuRegistered = false

-- Boss kill times: a non-roster UNIT_DIED whose name resolves in the zone
-- BossRegistry is a boss going down in this key. One entry per boss name (a
-- boss dies once per run; a re-match is registry aliasing, not a new kill).
-- at_ms rides the same time()-based clock as started_at_ms, so elapsed math
-- downstream is timezone-proof. enc_done is the client's encounter counter
-- read at the moment of death - it can lag one beat behind the kill (the
-- getter may update after UNIT_DIED); informational only, name + time are
-- the payload.
local function recordBossKill(destName)
    if not destName then return end
    local BR = ALC.Zone and ALC.Zone.BossRegistry
    local boss = BR and BR.match and BR.match(destName)
    if not boss then return end
    local _, run = findOpenRun(runStore())
    if not run then return end
    local kills = run.boss_kills
    if kills then
        for i = 1, #kills do
            if kills[i].name == boss then return end
        end
    else
        kills = {}
        run.boss_kills = kills
    end
    local entry = { at_ms = nowMs(), name = boss }
    local enc = callCMP("GetActiveKeystoneEncounters")
    if type(enc) == "table" and enc.encountersCompleted ~= nil then
        entry.enc_done = enc.encountersCompleted
    end
    kills[#kills + 1] = entry
    ALC.Core.Logger.debug("KeystoneScan boss kill: " .. boss)
end

local function ensureCleu()
    if cleuRegistered then return end
    cleuRegistered = true
    ALC.RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED", function(_e, ...)
        local w = K.deathWatch
        if not w then return end
        -- 3.3.5 signature: (timestamp, subEvent, srcGUID, srcName, srcFlags,
        --                   destGUID, destName, destFlags, ...)
        local _, subEvent, _, _, _, destGUID, destName = ...
        if subEvent ~= "UNIT_DIED" then return end
        local who = destGUID and w.guids[destGUID]
        if not who and destName and w.names[destName] then who = destName end
        if who then
            local _, run = findOpenRun(runStore())
            if not run then return end
            run.deaths = (run.deaths or 0) + 1
            run.deaths_by = run.deaths_by or {}
            run.deaths_by[who] = (run.deaths_by[who] or 0) + 1
            return
        end
        recordBossKill(destName)
    end)
end

local function armDeathWatch(run)
    local w = { guids = {}, names = {} }
    local roster = run.roster or {}
    for i = 1, #roster do
        local m = roster[i]
        if m.guid then w.guids[m.guid] = m.name end
        if m.name then w.names[m.name] = true end
    end
    K.deathWatch = w
    ensureCleu()
end

-- outcome: "timed" | "depleted" | "abandoned". live may be nil (abandoned).
local function closeRunRecord(run, outcome, timed, live)
    -- Last chance to fill builds for members whose inspect landed mid-run.
    pcall(enrichRosterCI, run)
    run.open = nil
    run.outcome = outcome
    run.timed = timed
    run.closed_at_ms = nowMs()
    if outcome == "timed" or outcome == "depleted" then
        run.completed_at_ms = K.state.completed_at_ms or run.closed_at_ms
    end
    if live then
        run.time_remaining_s = live.time_remaining_s
        if run.time_budget_s and live.time_remaining_s then
            run.time_taken_s = run.time_budget_s - live.time_remaining_s
        end
        run.progress = {
            enc_done   = live.encounters_done,
            enc_req    = live.encounters_required,
            trash_done = live.trash_done,
            trash_req  = live.trash_required,
            champ_done = live.champions_done,
            champ_req  = live.champions_required,
        }
    end
    K.deathWatch = nil
    ALC.Core.Logger.debug(string.format(
        "KeystoneScan run closed: %s +%s dungeon=%s deaths=%s",
        outcome, tostring(run.key_level), tostring(run.dungeon_id),
        tostring(run.deaths)))
end

-- Open a new run record from the live keystone read. `resumed` marks records
-- created without having seen MYTHIC_PLUS_STARTED this login (DC recovery /
-- addon enabled mid-run); their started_at is estimated from the timer.
local function openRun(resumed, live)
    if not shouldRecordRuns() then return nil end
    live = live or K.readActiveKeystone()
    local store = runStore()

    -- A new run supersedes any record that was never closed (abandoned key
    -- we never got a poll for).
    local _, stale = findOpenRun(store)
    if stale then closeRunRecord(stale, "abandoned") end

    local now = nowMs()
    local startedAt, estimated = now, nil
    if resumed and live and live.time_budget_s and live.time_remaining_s then
        local elapsed = live.time_budget_s - live.time_remaining_s
        if elapsed > 0 then
            startedAt = now - elapsed * 1000
            estimated = true
        end
    end

    local mapName
    if type(_G.GetInstanceInfo) == "function" then
        mapName = GetInstanceInfo()
    end

    local run = {
        v             = C.KS_RUNS_SCHEMA,
        addon_version = C.VERSION,
        rid           = toBase36(math.floor(startedAt)) .. "-"
                        .. tostring(live and live.dungeon_id or 0),
        server        = ALC.Profile or "unknown",
        realm         = (type(_G.GetRealmName) == "function" and GetRealmName()) or nil,
        char          = rosterUnit("player"),

        dungeon_id        = live and live.dungeon_id,
        map_id            = live and live.map_id,
        map_name          = mapName,
        key_level         = live and live.level,
        affixes           = live and live.active_affix_ids,
        weekly_pool       = live and live.weekly_affix_pool,
        reward_multiplier = live and live.reward_multiplier,
        time_budget_s     = live and live.time_budget_s,

        countdown_at_ms      = (not resumed) and K.state.countdown_at_ms or nil,
        started_at_ms        = math.floor(startedAt),
        started_at_estimated = estimated,
        resumed              = resumed or nil,
        resume_count         = 0,

        roster    = captureRoster(),
        roster_at = now,
        deaths    = 0,
        deaths_by = {},
        open      = true,
    }
    store.runs[#store.runs + 1] = run
    enforceCap(store)
    armDeathWatch(run)
    pcall(enrichRosterCI, run)
    ALC.Core.Logger.debug(string.format(
        "KeystoneScan run opened: +%s dungeon=%s roster=%d resumed=%s",
        tostring(run.key_level), tostring(run.dungeon_id),
        #run.roster, tostring(resumed or false)))
    return run
end

------------------------------------------------------------------------------
-- Best-run history harvest. The client's own M+ UI keeps BEST runs (one per
-- dungeon + one per weekly affix set, per character) client-side: FrameXML's
-- C_Keystones persists a KeystoneBests table via WriteCustomWTF("Keystones"),
-- keyed "Name - Realm" so it covers EVERY character on this install - and the
-- run tables carry Date (unix epoch), Time (s), Overtime, Level, Affixes and
-- the class-tagged roster. Harvesting it gives retroactive history from
-- before the addon shipped. Only bests exist (the client discards non-best
-- runs), and dungeon ids here are LFGDungeons ids - a DIFFERENT id space from
-- GetActiveKeystoneInfo().dungeonID; the backend resolves both.
--
-- Records land in ALC_KeystoneRuns.bests, keyed so re-harvests are no-ops;
-- an improved best has a new Date and lands as a new record.

local BESTS_SOFT_CAP = 800   -- guard against a pathological store; realistic counts are far lower

local function addBest(bests, kind, saveKey, id, run, expansion)
    if type(run) ~= "table" or not run.Date then return 0 end
    local key = kind .. "|" .. tostring(id) .. "|" .. tostring(saveKey)
        .. "|" .. tostring(run.Date)
    if bests[key] then return 0 end
    local n = 0
    for _ in pairs(bests) do n = n + 1; if n >= BESTS_SOFT_CAP then return 0 end end
    local players = {}
    if type(run.Players) == "table" then
        for i = 1, #run.Players do
            local p = run.Players[i]
            if type(p) == "table" then
                players[#players + 1] = { name = p[1], class = p[2] }
            end
        end
    end
    bests[key] = {
        kind         = kind,               -- "dungeon_best" | "set_best"
        save_key     = saveKey,            -- "Name - Realm"
        dungeon_id   = (kind == "dungeon_best") and id or nil,  -- LFGDungeons id
        affix_set    = (kind == "set_best") and tostring(id) or nil,
        expansion    = expansion,
        level        = run.Level,
        time_s       = run.Time,
        overtime     = run.Overtime and true or false,
        date         = run.Date,
        affixes      = copyList(run.Affixes),
        players      = players,
        harvested_at = nowMs(),
    }
    return 1
end

function K.harvestBests()
    if not shouldRecordRuns() then return 0 end
    local store = runStore()
    store.bests = store.bests or {}
    local bests, added = store.bests, 0

    -- Preferred: decode the client's whole KeystoneBests store (covers every
    -- character on this install). Reads are not secure-gated; writes are.
    local decoded
    if type(_G.ReadCustomWTF) == "function" and type(_G.C_Serialize) == "table" then
        local okR, raw = pcall(_G.ReadCustomWTF, "Keystones")
        if okR and type(raw) == "string" and raw ~= "" then
            local okD, data = pcall(function()
                return _G.C_Serialize:DeserializeDecompressFromPrint(raw)
            end)
            if okD and type(data) == "table" then decoded = data end
        end
    end

    if decoded then
        for outerKey, inner in pairs(decoded) do
            if type(inner) == "table" then
                if type(outerKey) == "number" and outerKey >= 100 then
                    -- KeystoneBests[dungeonID][saveKey] = run. (Expansion
                    -- enums are 0/1/2; LFGDungeons ids are large numbers.)
                    for saveKey, run in pairs(inner) do
                        added = added + addBest(bests, "dungeon_best", saveKey, outerKey, run)
                    end
                else
                    -- KeystoneBests[expansion][affixSetString][saveKey] = run
                    for setStr, bySave in pairs(inner) do
                        if type(bySave) == "table" then
                            for saveKey, run in pairs(bySave) do
                                added = added + addBest(bests, "set_best", saveKey, setStr, run, outerKey)
                            end
                        end
                    end
                end
            end
        end
    else
        -- Fallback: the public getters, current character only.
        local CK = _G.C_Keystones
        if type(CK) == "table" and type(CK.GetTimedDungeonsForExpansion) == "function"
                and type(CK.GetDungeonBest) == "function" then
            local okKey, saveKey = pcall(CK.GetPlayerSaveKey)
            if not okKey or not saveKey then saveKey = "player" end
            for exp = 0, 2 do
                local okL, list = pcall(CK.GetTimedDungeonsForExpansion, exp)
                if okL and type(list) == "table" then
                    for i = 1, #list do
                        local okB, best = pcall(CK.GetDungeonBest, list[i])
                        if okB then
                            added = added + addBest(bests, "dungeon_best", saveKey, list[i], best, exp)
                        end
                    end
                end
            end
        end
    end

    if added > 0 then
        ALC.Core.Logger.debug("KeystoneScan: harvested " .. added .. " new best-run records")
    end
    return added
end

local harvestFrame
function K.scheduleHarvest(delay)
    if not isAvailable() then return end
    if not harvestFrame then harvestFrame = CreateFrame("Frame") end
    local elapsed, wait = 0, delay or 8
    harvestFrame:SetScript("OnUpdate", function(self, dt)
        elapsed = elapsed + dt
        if elapsed < wait then return end
        self:SetScript("OnUpdate", nil)
        pcall(K.harvestBests)
    end)
end

------------------------------------------------------------------------------
-- Resume-after-login. PLAYER_ENTERING_WORLD fires on login, /reload and every
-- loading screen; the C_MythicPlus getters can populate late, so poll a few
-- times instead of reading once. Outcomes per poll:
--   * live key matches the open record        -> reattach (rearm death watch)
--   * live key, no matching record            -> open a resumed record
--   * live state is 100% complete             -> post-COMPLETE residue, ignore
--     (the library keeps getters populated after MYTHIC_PLUS_COMPLETE)
--   * final poll, no live key, record open    -> close it "abandoned"

local RESUME_POLL_AT = { 5, 15, 30 }   -- seconds after PLAYER_ENTERING_WORLD
local resumeFrame

-- Returns true when the poll sequence is resolved and can stop early.
local function onResumePoll(isFinal)
    if not shouldRecordRuns() then return true end
    local live = K.readActiveKeystone()
    local store = runStore()
    local _, open = findOpenRun(store)

    if live and live.dungeon_id then
        local finished =
            live.encounters_done and live.encounters_required
            and live.encounters_done >= live.encounters_required
            and live.trash_done and live.trash_required
            and live.trash_done >= live.trash_required
        -- An open record with nil dungeon_id was created while the getters
        -- were still lagging - treat it as ours and backfill from the live
        -- read rather than abandoning it.
        if open and (open.dungeon_id == nil
                or (open.dungeon_id == live.dungeon_id
                    and open.key_level == live.level)) then
            if open.dungeon_id == nil then
                open.dungeon_id    = live.dungeon_id
                open.map_id        = live.map_id
                open.key_level     = live.level
                open.affixes       = live.active_affix_ids
                open.weekly_pool   = live.weekly_affix_pool
                open.time_budget_s = live.time_budget_s
                if type(_G.GetInstanceInfo) == "function" then
                    open.map_name = GetInstanceInfo()
                end
            end
            open.resume_count = (open.resume_count or 0) + 1
            open.last_resume_at_ms = nowMs()
            if not open.roster or #open.roster == 0 then
                open.roster = captureRoster()
                open.roster_at = nowMs()
            end
            armDeathWatch(open)
            pcall(enrichRosterCI, open)
            ALC.Core.Logger.debug("KeystoneScan: reattached to open run after loading screen")
            return true
        end
        if finished then return true end
        openRun(true, live)
        return true
    end

    if isFinal and open then
        closeRunRecord(open, "abandoned")
    end
    return isFinal
end

function K.scheduleResumePolls()
    if not isAvailable() then return end
    local pending = {}
    for i = 1, #RESUME_POLL_AT do pending[i] = RESUME_POLL_AT[i] end
    if not resumeFrame then
        resumeFrame = CreateFrame("Frame")
    end
    local elapsed = 0
    resumeFrame:SetScript("OnUpdate", function(self, dt)
        elapsed = elapsed + dt
        if elapsed < pending[1] then return end
        table.remove(pending, 1)
        local isFinal = (#pending == 0)
        local ok, resolved = pcall(onResumePoll, isFinal)
        if isFinal or (ok and resolved) then
            self:SetScript("OnUpdate", nil)
        end
    end)
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

    -- Durable record. If an open record already matches the live key this is
    -- a duplicate STARTED (reload race) - keep the record, just rearm the
    -- death watch; openRun() would wrongly close it as abandoned.
    if shouldRecordRuns() then
        local live = K.readActiveKeystone()
        local _, open = findOpenRun(runStore())
        if open and live and open.dungeon_id == live.dungeon_id
                and open.key_level == live.level then
            armDeathWatch(open)
        else
            openRun(false, live)
        end
    end
end

local function onComplete(a1)
    -- a1 is the timed boolean: true = timed (success), false = depleted.
    K.state.timer_state     = "complete"
    K.state.completed_at_ms = nowMs()
    K.state.completed_timed = (a1 == true) or (a1 == 1) or false
    publishEvent("complete")

    -- Close the durable record. The getters stay populated through COMPLETE,
    -- so a live read here still yields final time/progress.
    if shouldRecordRuns() then
        local live = K.readActiveKeystone()
        local outcome = K.state.completed_timed and "timed" or "depleted"
        local _, open = findOpenRun(runStore())
        if not open then
            -- COMPLETE with no open record: the start was missed (addon
            -- enabled mid-run and no resume poll fired). Synthesize from the
            -- live read so the run is not lost.
            open = openRun(true, live)
        end
        if open then
            closeRunRecord(open, outcome, K.state.completed_timed, live)
        end
        -- The client writes its own best-run record in ITS complete handler
        -- (ordering vs ours is undefined) - harvest shortly after.
        K.scheduleHarvest(5)
    end
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
    -- Resume/abandon detection for the durable run records: fires on login,
    -- /reload and every loading screen (the polls sort out which it was).
    -- The best-run harvest rides the same trigger (once, 8s after loading).
    reg("PLAYER_ENTERING_WORLD",         function()
        K.scheduleResumePolls()
        K.scheduleHarvest(8)
    end)

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

    -- Durable run records (what the Uploader reads from SavedVariables).
    local store = _G.ALC_KeystoneRuns
    local runs = store and store.runs
    if runs and #runs > 0 then
        log("Run records: " .. #runs .. " stored (newest last):")
        local from = math.max(1, #runs - 2)
        for i = from, #runs do
            local r = runs[i]
            log("  [" .. i .. "] +" .. tostring(r.key_level)
                .. " " .. tostring(r.map_name or r.dungeon_id)
                .. " outcome=" .. tostring(r.open and "OPEN" or r.outcome)
                .. " deaths=" .. tostring(r.deaths)
                .. " roster=" .. tostring(r.roster and #r.roster)
                .. (r.resumed and " resumed" or ""))
        end
    else
        log("Run records: none stored yet")
    end
    local bests = store and store.bests
    if bests then
        local n = 0
        for _ in pairs(bests) do n = n + 1 end
        log("Best-run history: " .. n .. " harvested records")
    else
        log("Best-run history: not harvested yet")
    end
end
