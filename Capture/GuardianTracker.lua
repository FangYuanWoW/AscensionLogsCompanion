-- Capture/GuardianTracker.lua
-- Resolves slot-less player-controlled guardians to their owners via unit
-- tooltip scan and feeds the {owner, pet} pairs into PetPipeline - the same
-- PP record lane PetTracker uses.
--
-- PetTracker covers the controlled-pet UNIT SLOTS (UnitGUID("raidNpet")).
-- Proc-summoned guardians never occupy a slot, and many of them (Primalist
-- "Spirit of Life" being the canonical case: one fresh GUID per melee crit)
-- also emit no SPELL_SUMMON, so neither the slot sweep nor the server's
-- summon inference can ever bind them. The client itself still knows the
-- owner: rendering the unit tooltip by GUID yields an "<Owner>'s Minion"
-- line even for units that have no unit token. This is the same technique
-- the bundled Details port uses (its DetailsPetOwnerFinder tooltip scan);
-- 3.3.5-era meters (Skada) use it as well.
--
-- Trigger: CLEU source or dest flags carrying TYPE_PET or TYPE_GUARDIAN
-- plus CONTROL_PLAYER plus REACTION_FRIENDLY. A successful scan is final;
-- a failed one is retried on a later CLEU row from the same GUID with
-- exponential backoff (2s doubling to a 30s cap, 12 attempts max). The
-- first row a guardian ever logs is usually its spawn instant (raid buffs
-- blanket it the same millisecond it appears), and a tooltip render at
-- that moment can miss: the object may not be queryable client-side yet,
-- or it spawned out of render range. A long-lived guardian keeps logging
-- rows for the whole fight, so a later attempt lands once the unit is
-- rendered - the Details port survives the same race by clearing its
-- failed-scan list every segment. A scan is one hidden-tooltip render (a
-- few hundredths of a ms); the backoff bounds a never-resolvable GUID
-- (e.g. a despawned one-proc guardian) to 12 renders total.
--
-- Scope notes:
--   * Slot pets (0xF140 space) get re-resolved here too when they act in
--     the combat log before/without a UNIT_PET slot observation. The server
--     dedups pairs, and the tooltip answer agrees with the slot answer, so
--     the redundancy is harmless and buys coverage for out-of-range owners.
--   * Owner names from the tooltip are validated against the client's unit
--     resolver (UnitGUID/UnitIsPlayer by name works for the player and any
--     group member on 3.3.5) before a pair is trusted. A tooltip line that
--     happens to pattern-match but names no group member is dropped.
--   * A guardian that despawns before its first combat-log row resolves to
--     an empty tooltip and is marked failed; its GUID never recurs (fresh
--     GUID per spawn), so there is no retry ladder.

local ALC = _G.ALC
local T = {}
ALC.Capture.GuardianTracker = T

-- Same defensive band() as Telemetry: the bit library is client-provided
-- and not guaranteed on every flavor.
local function band(v, mask)
    if not v or not mask then return 0 end
    if _G.bit and bit.band then return bit.band(v, mask) end
    if _G.bit32 and bit32.band then return bit32.band(v, mask) end
    return 0
end

-- CLEU unitFlags bits (3.3.5 COMBATLOG_OBJECT_* values).
local TYPE_PET_OR_GUARDIAN = 0x00003000 -- TYPE_PET 0x1000 | TYPE_GUARDIAN 0x2000
local CONTROL_PLAYER       = 0x00000100
local REACTION_FRIENDLY    = 0x00000010

-- [petGuid] = true once final (resolved, or retries exhausted); a pending
-- retry holds { attempts, nextAt } instead.
T.seenGuids = {}
T.stats = { seen = 0, resolved = 0, failed = 0, no_roster = 0, retries = 0, rescued = 0 }

local RETRY_BASE_DELAY   = 2   -- seconds; doubles per failed attempt
local RETRY_MAX_DELAY    = 30
local RETRY_MAX_ATTEMPTS = 12

-- Owner-title patterns ("%s's Pet" -> "(.+)'s Pet"), built from the client's
-- localized UNITNAME_TITLE_* globals on first use. Guarded per-global: not
-- every client flavor defines all of them.
local titlePatterns
local function getTitlePatterns()
    if titlePatterns then return titlePatterns end
    titlePatterns = {}
    local globals = {
        "UNITNAME_TITLE_PET",
        "UNITNAME_TITLE_GUARDIAN",
        "UNITNAME_TITLE_MINION",
        "UNITNAME_TITLE_CHARM",
        "UNITNAME_TITLE_COMPANION",
        "UNITNAME_TITLE_CREATION",
    }
    for i = 1, #globals do
        local s = _G[globals[i]]
        if type(s) == "string" then
            titlePatterns[#titlePatterns + 1] = s:gsub("%%s", "(.+)")
        end
    end
    return titlePatterns
end

-- Hidden tooltip used to render arbitrary units by GUID. Created on first
-- scan so the module costs nothing until a guardian actually shows up.
local scanTip
local function getScanTip()
    if scanTip then return scanTip end
    scanTip = CreateFrame("GameTooltip", "ALCGuardianOwnerTooltip", nil, "GameTooltipTemplate")
    return scanTip
end

local function shouldTrack()
    if not _G.ALC_Config then return false end
    if ALC_Config.pet_tracking_enabled == false then return false end
    -- PetPipeline drops non-logger emissions anyway; gating here too skips
    -- the tooltip renders entirely for non-loggers (PetTracker's UnitGUID
    -- reads are free, these are not).
    if not ALC_Config.is_logger then return false end
    return true
end

-- Render the unit tooltip for petGuid and extract the owner's name from the
-- "<Owner>'s Minion/Guardian/Pet/..." title line. Returns the owner's GUID
-- when the named owner resolves to a player in our group (or ourselves).
local function scanOwnerGuid(petGuid)
    local tip = getScanTip()
    tip:SetOwner(WorldFrame, "ANCHOR_NONE")
    local ok = pcall(tip.SetHyperlink, tip, "unit:" .. petGuid)
    if not ok then return nil, "failed" end

    local patterns = getTitlePatterns()
    -- The title line is TextLeft2 normally, TextLeft3 with colorblind mode
    -- adding a faction line; scanning the first few lines covers both
    -- without CVar bookkeeping. Roster validation below kills any stray
    -- line that pattern-matches by accident.
    for lineIdx = 1, 4 do
        local line = _G["ALCGuardianOwnerTooltipTextLeft" .. lineIdx]
        local text = line and line:GetText()
        if text and text ~= "" then
            for p = 1, #patterns do
                local ownerName = text:match(patterns[p])
                if ownerName then
                    -- Names are valid unit ids for the player and group
                    -- members on 3.3.5; anyone else resolves to nil.
                    if UnitIsPlayer(ownerName) then
                        local ownerGuid = UnitGUID(ownerName)
                        if ownerGuid and ownerGuid ~= petGuid then
                            return ownerGuid, "resolved"
                        end
                    end
                    return nil, "no_roster"
                end
            end
        end
    end
    return nil, "failed"
end

local function maybeResolve(guid, flags)
    if not guid or not flags or guid == "" then return end
    local state = T.seenGuids[guid]
    if state == true then return end
    if band(flags, TYPE_PET_OR_GUARDIAN) == 0 then return end
    if band(flags, CONTROL_PLAYER) == 0 then return end
    if band(flags, REACTION_FRIENDLY) == 0 then return end

    local now = GetTime()
    if state then
        if now < state.nextAt then return end
        T.stats.retries = T.stats.retries + 1
    else
        T.stats.seen = T.stats.seen + 1
    end

    local ownerGuid, outcome = scanOwnerGuid(guid)

    if ownerGuid then
        T.seenGuids[guid] = true
        T.stats.resolved = T.stats.resolved + 1
        if state then T.stats.rescued = T.stats.rescued + 1 end
        local pipeline = ALC.Capture.PetPipeline
        if pipeline and pipeline.publishPairs then
            pipeline.publishPairs({ { owner = ownerGuid, pet = guid } })
        end
        return
    end

    local attempts = (state and state.attempts or 0) + 1
    if attempts >= RETRY_MAX_ATTEMPTS then
        T.seenGuids[guid] = true
        T.stats[outcome] = (T.stats[outcome] or 0) + 1
        return
    end
    local delay = RETRY_BASE_DELAY * 2 ^ (attempts - 1)
    if delay > RETRY_MAX_DELAY then delay = RETRY_MAX_DELAY end
    T.seenGuids[guid] = { attempts = attempts, nextAt = now + delay }
end

local function onCombatLogEvent(event, ...)
    if not shouldTrack() then return end
    -- 3.3.5 combat log signature:
    -- (timestamp, subEvent, sourceGUID, sourceName, sourceFlags,
    --  destGUID, destName, destFlags, ...)
    local _, _, sourceGUID, _, sourceFlags, destGUID, _, destFlags = ...
    maybeResolve(sourceGUID, sourceFlags)
    maybeResolve(destGUID, destFlags)
end

-- /alc guardians output. failed/no-roster count GUIDs whose retries are
-- exhausted; rescued = resolved on a retry rather than the first scan.
function T.probe(printer)
    printer = printer or ALC.Core.Logger.info
    printer("GuardianTracker: seen |cffe8e8e8" .. T.stats.seen .. "|r"
        .. "  resolved |cff00ff00" .. T.stats.resolved .. "|r"
        .. " (rescued " .. (T.stats.rescued or 0) .. ")"
        .. "  retries |cffe8e8e8" .. (T.stats.retries or 0) .. "|r"
        .. "  no-roster |cffaaaaaa" .. (T.stats.no_roster or 0) .. "|r"
        .. "  failed |cffff7777" .. T.stats.failed .. "|r")
end

function T.start()
    ALC.RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED", onCombatLogEvent)
    ALC.Core.Logger.debug("GuardianTracker.start() registered events")
end
