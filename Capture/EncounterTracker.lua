-- Capture/EncounterTracker.lua
-- Detects which boss the raid is currently engaged with and triggers
-- fresh inspect cycles on boss transitions.
--
-- Why this matters: people swap trinkets, talents, mystic enchants,
-- or specs between bosses. The passive 5-min inspect refresh doesn't
-- catch this because combat rarely drops for long enough. Relying on
-- UNIT_INVENTORY_CHANGED alone fails too because that event only fires
-- for units whose frames you have loaded.
--
-- Detection strategy (stock 3.3.5, cheap):
--   - PLAYER_TARGET_CHANGED: check if target is a registered boss
--   - UPDATE_MOUSEOVER_UNIT: same for mouseover
--   - PLAYER_REGEN_ENABLED + 30s quiet window: boss considered over
--
-- We intentionally do NOT scrape COMBAT_LOG_EVENT_UNFILTERED for boss
-- names on every event. That would process thousands of events/sec in
-- raid combat for what is already adequately covered by target/mouseover
-- detection. Tanks always target bosses; that's enough.

local ALC = _G.ALC
local E = {}
ALC.Capture.EncounterTracker = E

E.currentBoss = nil        -- canonical boss name, nil between pulls
E.currentBossGuid = nil    -- GUID of the currently pinned boss; populated by checkUnit when a unit GUID is available, used by UNIT_DIED to clear deterministically
E.bossStartedAt = nil      -- time() when current boss detected
E.lastActivityAt = nil     -- time() of last SPELL_DAMAGE involving boss
E.pendingClearTimer = nil
E.pullId = 0               -- bumps every PLAYER_REGEN_DISABLED (combat enter); paired with currentBoss to give per-pull cache invalidation

local SETTLE_AFTER_COMBAT_S = 30  -- after combat drops, wait this long before clearing current boss

-- Reset inspect schedule for all raiders who haven't been captured for
-- the new boss yet. Sets next_scan_at=0 so the existing 2s-throttled
-- scheduler picks them up immediately.
local function invalidateCacheForNewBoss(newBossName)
    local cache = ALC.Capture.InspectCache.snapshot()
    local now = time()
    local moved = 0
    for guid, entry in pairs(cache) do
        -- Skip if entry has already been captured for this boss
        if entry.captured_for_boss ~= newBossName then
            entry.next_scan_at = now  -- front of queue
            entry.backoff_until = 0
            entry.inspect_unavailable = false  -- retry even if previously gave up
            ALC.Capture.InspectCache.set(guid, entry)
            moved = moved + 1
        end
    end
    ALC.Core.Logger.debug("Boss change to " .. newBossName .. "; re-queued " .. moved .. " raiders for inspect")
end

local function setCurrentBoss(name)
    if name == E.currentBoss then return end
    ALC.Core.Logger.debug("Boss detected: " .. name)
    E.currentBoss = name
    E.currentBossGuid = nil  -- repopulated by checkUnit on the next target/mouseover pass
    E.bossStartedAt = time()
    invalidateCacheForNewBoss(name)
    if ALC.Core.Metrics then
        ALC.Core.Metrics.inc("boss_transitions")
    end
    -- Republish own CI tagged with the new boss. The hash dedup includes
    -- captured_for_boss now, so this only fires the chunk pipeline if the
    -- own CI actually changed (i.e. fresh boss tag).
    if ALC.Capture.SnapshotPipeline and ALC.Capture.SnapshotPipeline.publishOwnIfChanged then
        ALC.Capture.SnapshotPipeline.publishOwnIfChanged()
    end
end

local function checkUnit(unit)
    if not unit or not UnitExists(unit) then return end
    local name = UnitName(unit)
    local boss = ALC.Zone.BossRegistry.match(name)
    if boss then
        setCurrentBoss(boss)
        E.currentBossGuid = UnitGUID(unit)
        E.lastActivityAt = time()
    end
end

-- Deterministic boss clear on death. The 30s settle window is too coarse:
-- trash pulled within seconds of a kill stays tagged with the dead boss,
-- which contaminates captured_for_boss on any inspect CIs published in that
-- gap. UNIT_DIED on the matching destGUID is the unambiguous signal.
local function onUnitDied(destGuid)
    if E.currentBossGuid and destGuid == E.currentBossGuid then
        ALC.Core.Logger.debug("Boss " .. tostring(E.currentBoss) .. " died - clearing")
        E.currentBoss = nil
        E.currentBossGuid = nil
        E.bossStartedAt = nil
        E.pendingClearTimer = nil
    end
end

local function onTargetChanged()
    checkUnit("target")
end

local function onMouseover()
    checkUnit("mouseover")
end

-- When combat drops, schedule clearing current_boss. If combat re-starts
-- within the window (trash pull, re-pull), cancel the clear.
local function onRegenEnabled()
    if not E.currentBoss then return end
    local clearAt = time() + SETTLE_AFTER_COMBAT_S
    E.pendingClearTimer = clearAt
end

local function onRegenDisabled()
    -- Cancel pending clear if combat resumed
    E.pendingClearTimer = nil
    -- New combat = new pull. Bump pull id so any peer captured against this
    -- (boss, pullId) tuple gets re-inspected, even if the boss is the same.
    -- Catches gear/spec/mystic swaps between wipe-retry pulls.
    E.pullId = (E.pullId or 0) + 1
end

-- Called periodically (hooked off the inspect loop's 2s tick); actually
-- advances pending clears. No new timer needed.
local function tick()
    if E.pendingClearTimer and time() >= E.pendingClearTimer then
        ALC.Core.Logger.debug("Boss cleared (settle window elapsed)")
        E.currentBoss = nil
        E.currentBossGuid = nil
        E.bossStartedAt = nil
        E.pendingClearTimer = nil
    end
end

function E.start()
    ALC.RegisterEvent("PLAYER_TARGET_CHANGED", onTargetChanged)
    ALC.RegisterEvent("UPDATE_MOUSEOVER_UNIT", onMouseover)
    ALC.RegisterEvent("PLAYER_REGEN_ENABLED", onRegenEnabled)
    ALC.RegisterEvent("PLAYER_REGEN_DISABLED", onRegenDisabled)
    ALC.RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED", function(event, ...)
        local _, subEvent, _, _, _, destGUID = ...
        if subEvent == "UNIT_DIED" then
            onUnitDied(destGUID)
        end
    end)

    -- Piggyback on the inspect loop's OnUpdate for periodic tick
    if ALC.frame then
        local accum = 0
        ALC.frame:HookScript("OnUpdate", function(self, elapsed)
            accum = accum + elapsed
            if accum >= 2.0 then
                accum = 0
                tick()
            end
        end)
    end
end

-- Read-only accessor for InspectLoop
function E.getCurrentBoss()
    return E.currentBoss
end

-- Per-pull invalidation key. Paired with currentBoss in Rule 2 so each new
-- combat enter forces a re-inspect, even on wipe-retry of the same boss.
function E.getCurrentPullId()
    return E.pullId or 0
end

-- Manual override for testing / trash-only zones
function E.setBoss(name)
    setCurrentBoss(name or "manual-test")
end

function E.clearBoss()
    E.currentBoss = nil
    E.currentBossGuid = nil
    E.bossStartedAt = nil
    E.pendingClearTimer = nil
end
