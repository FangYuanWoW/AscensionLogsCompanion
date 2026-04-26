-- Transport/SpellFailedHijack.lua
-- LegacyPlayersV3-style SPELL_FAILED_* localization override for injecting
-- CI chunks into WoWCombatLog.txt.
--
-- Scope-tightened: only active when LoggingCombat + in raid + in combat +
-- user hasn't disabled via config. Originals captured at init and restored
-- on scope exit. UIErrorsFrame hook suppresses sentinel strings from
-- leaking into the red-text overlay.

local ALC = _G.ALC
local H = {}
ALC.Transport.SpellFailedHijack = H

local C = ALC.Core.Constants

-- Starter global list for Phase 1. Full ~170 list arrives in Phase 2.
-- Ordered with the most-observed fail reasons first (measured from real
-- Ascension raid logs in ascensionLogs/data/downloads: SPELL_FAILED_NOT_READY
-- dominates because of cooldown spam, followed by interrupt/range/LoS).
H.GLOBALS = {
    "SPELL_FAILED_NOT_READY",           -- "Not yet recovered" - most common
    "SPELL_FAILED_INTERRUPTED",
    "SPELL_FAILED_OUT_OF_RANGE",
    "SPELL_FAILED_LINE_OF_SIGHT",
    "SPELL_FAILED_INVALID_TARGET",
    "SPELL_FAILED_BAD_TARGETS",
    "SPELL_FAILED_NO_TARGETS",
    "SPELL_FAILED_TARGETS_DEAD",
    "SPELL_FAILED_CASTER_DEAD",
    "SPELL_FAILED_UNIT_NOT_INFRONT",
    "SPELL_FAILED_NOT_INFRONT",
    "SPELL_FAILED_NOT_BEHIND",
    "SPELL_FAILED_TOO_CLOSE",
    "SPELL_FAILED_AURA_BOUNCED",
    "SPELL_FAILED_AFFECTING_COMBAT",
    "SPELL_FAILED_ALREADY_AT_FULL_HEALTH",
    "SPELL_FAILED_ALREADY_AT_FULL_POWER",
    "SPELL_FAILED_CASTER_AURASTATE",
    "SPELL_FAILED_STUNNED",
    "SPELL_FAILED_CHARMED",
    "SPELL_FAILED_CONFUSED",
    "SPELL_FAILED_FLEEING",
    "SPELL_FAILED_PACIFIED",
    "SPELL_FAILED_SILENCED",
    "SPELL_FAILED_SPELL_IN_PROGRESS",
    "SPELL_FAILED_IMMUNE",
    "SPELL_FAILED_NO_COMBO_POINTS",
    "SPELL_FAILED_BAD_IMPLICIT_TARGETS",
    "SPELL_FAILED_CANT_BE_CHARMED",
    "SPELL_FAILED_CANT_BE_DISENCHANTED",
    "SPELL_FAILED_CANT_BE_MILLED",
    "SPELL_FAILED_CANT_BE_PROSPECTED",
    "SPELL_FAILED_CANT_CAST_ON_TAPPED",
    "SPELL_FAILED_LOW_CASTLEVEL",
    "SPELL_FAILED_ITEM_NOT_READY",      -- "Item is not ready yet"
    "SPELL_FAILED_TOO_MANY_OF_ITEM",    -- "You have too many of that item already"
    "SPELL_FAILED_MOREPOWERFULSPELLACTIVE",  -- "A more powerful spell is already active"
}

H.originals = nil   -- captured at init, { [globalName] = originalValue }
H.active = false
H.queue = nil       -- ring buffer of chunks
H.queueIdx = 1

local function ensureOriginalsCaptured()
    if H.originals then return end
    H.originals = {}
    for _, g in ipairs(H.GLOBALS) do
        H.originals[g] = _G[g]
    end
end

local function applyChunk(chunk)
    for _, g in ipairs(H.GLOBALS) do
        local ok = pcall(function() setglobal(g, chunk) end)
        if not ok then
            ALC.Core.Logger.warn("Hijack: setglobal failed for " .. g)
        end
    end
end

local function restoreAll()
    if not H.originals then return end
    for g, orig in pairs(H.originals) do
        pcall(function() setglobal(g, orig) end)
    end
end

function H.enqueue(chunk)
    if not H.queue then
        H.queue = ALC.Core.Queue.newRing(C.HIJACK_QUEUE_MAX_CHUNKS)
    end
    local sizeBefore = H.queue.size
    ALC.Core.Queue.ringPush(H.queue, { chunk = chunk, pushed_at = time() })
    ALC.Core.Metrics.inc("chunks_queued")
    ALC.Core.Metrics.observe_payload_len(#chunk)
    if sizeBefore == H.queue.capacity then
        -- Push evicted oldest entry
        ALC.Core.Metrics.inc("chunks_dropped_overflow")
    end
end

function H.clearQueue()
    if H.queue then ALC.Core.Queue.ringClear(H.queue) end
end

-- Scope check: should hijack be active right now?
local function shouldBeActive()
    if not _G.ALC_Config or not ALC_Config.hijack_enabled then return false end
    if not LoggingCombat or not LoggingCombat() then return false end
    if not UnitAffectingCombat("player") then return false end
    local _, instType = IsInInstance()
    -- raid = 25-raid, party = 5-man dungeons. Allow both so dungeon
    -- testing produces CI lines too.
    if instType ~= "raid" and instType ~= "party" then return false end
    return true
end

-- Called on every SPELL_CAST_FAILED sub-event in COMBAT_LOG_EVENT_UNFILTERED
function H.onSpellCastFailed()
    if not H.active then return end
    if not H.queue or H.queue.size == 0 then return end

    -- Evict stale chunks
    local nowSec = time()
    local ttl = C.HIJACK_CHUNK_TTL_S
    while H.queue.size > 0 do
        local head = ALC.Core.Queue.ringPeek(H.queue, 0)
        if head and (nowSec - head.pushed_at) > ttl then
            ALC.Core.Queue.ringAdvance(H.queue)
            ALC.Core.Metrics.inc("chunks_dropped_ttl")
        else
            break
        end
    end
    if H.queue.size == 0 then return end

    -- Apply next chunk; the one we just applied for this event already hit the log
    local entry = ALC.Core.Queue.ringPeek(H.queue, 0)
    if entry then
        applyChunk(entry.chunk)
        -- Rotate: advance head so next SPELL_CAST_FAILED uses the next chunk
        ALC.Core.Queue.ringAdvance(H.queue)
        ALC.Core.Metrics.mark_flush()
    end
end

-- Activate / deactivate based on scope changes
function H.reevaluate()
    local want = shouldBeActive()
    if want and not H.active then
        ensureOriginalsCaptured()
        H.active = true
        ALC.Core.Metrics.inc("hijack_activations")
        ALC.Core.Logger.debug("Hijack activated")
    elseif not want and H.active then
        restoreAll()
        H.active = false
        ALC.Core.Metrics.inc("hijack_deactivations")
        ALC.Core.Logger.debug("Hijack deactivated")
    end
end

-- UIErrorsFrame hook: silent-drop any message starting with our sentinel
local function installUIErrorSuppressor()
    if UIErrorsFrame and not UIErrorsFrame._alc_hooked then
        local orig = UIErrorsFrame.AddMessage
        UIErrorsFrame.AddMessage = function(self, msg, ...)
            if type(msg) == "string" and msg:sub(1, #C.CI_SENTINEL_PREFIX) == C.CI_SENTINEL_PREFIX then
                return
            end
            return orig(self, msg, ...)
        end
        UIErrorsFrame._alc_hooked = true
    end
end

function H.start()
    installUIErrorSuppressor()

    ALC.RegisterEvent("PLAYER_REGEN_DISABLED", H.reevaluate)
    ALC.RegisterEvent("PLAYER_REGEN_ENABLED", function()
        H.reevaluate()
        -- Do NOT clear the queue here. Short pulls (5-10s of trash) routinely
        -- end with undrained chunks; clearing would drop them. Instead let
        -- undrained chunks roll into the next combat, where TTL eviction
        -- (HIJACK_CHUNK_TTL_S) lazily evicts stale entries at the head and
        -- the 200-chunk ring cap bounds growth. lastPeerEnqueued dedup
        -- prevents re-enqueueing the same capture.
    end)
    ALC.RegisterEvent("ZONE_CHANGED_NEW_AREA", H.reevaluate)
    ALC.RegisterEvent("PLAYER_ENTERING_WORLD", H.reevaluate)
    ALC.RegisterEvent("PLAYER_LOGOUT", function() restoreAll() end)

    -- Hook into combat log event for SPELL_CAST_FAILED triggering
    ALC.RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED", function(event, ...)
        local _, subEvent = ...
        if subEvent == "SPELL_CAST_FAILED" then
            H.onSpellCastFailed()
        end
    end)
end

-- User kill switch
function H.disable()
    _G.ALC_Config.hijack_enabled = false
    H.reevaluate()
end
