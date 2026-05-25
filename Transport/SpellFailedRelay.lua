-- Transport/SpellFailedRelay.lua
-- LegacyPlayersV3-style SPELL_FAILED_* localization rewrite that carries
-- snapshot CI chunks through WoWCombatLog.txt on the back of SPELL_CAST_FAILED
-- events.
--
-- Scope-tightened: only active when LoggingCombat + in raid + in combat +
-- user hasn't disabled via config. Originals captured at init and restored
-- on scope exit. UIErrorsFrame hook suppresses sentinel strings from
-- leaking into the red-text overlay.
--
-- Landed-evidence gating (added 0.30.1; family-generalized 0.42.0): the queue
-- head only advances when the next SPELL_CAST_FAILED's failedType arg starts
-- with RELAY_FAMILY_PREFIX (currently "[[ALC_"), which proves the previously-
-- applied chunk was the string the engine read and therefore landed in
-- WoWCombatLog.txt. If failedType is anything else (uncovered Lua global,
-- or a C-side string like "Not enough rage" / "Not enough energy" that
-- bypasses _G entirely), the same chunk stays at the head and gets
-- re-applied on the next event. Matching the family prefix instead of the
-- CI-specific prefix lets the same gating work for CI ([[ALC_CI_v2_...) and
-- PP ([[ALC_PP_v1_...) chunks alike since the transport is family-agnostic.

local ALC = _G.ALC
local H = {}
ALC.Transport.SpellFailedRelay = H

local C = ALC.Core.Constants

-- Source of truth for the rewrite set lives in Core/Constants.lua
-- (C.RELAY_FAIL_GLOBALS). Ordered most-observed first to maximize the
-- chance any given SPELL_CAST_FAILED reads one of our values.
H.GLOBALS = C.RELAY_FAIL_GLOBALS

H.originals = nil   -- captured at init, { [globalName] = originalValue }
H.active = false
H.queue = nil       -- ring buffer of chunks
H.queueIdx = 1
H.pendingChunk = nil  -- chunk currently sitting in the rewritten globals; cleared on landed evidence
H.globalsDirty = false  -- true when applyChunk has overwritten globals; cleared by restoreAll

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
            ALC.Core.Logger.warn("Relay: setglobal failed for " .. g)
        end
    end
    H.globalsDirty = true
end

local function restoreAll()
    if not H.originals then return end
    for g, orig in pairs(H.originals) do
        pcall(function() setglobal(g, orig) end)
    end
    H.globalsDirty = false
end

-- Eager-restore (added 0.30.3): when the queue empties between CI flushes,
-- revert SPELL_FAILED_* globals to originals so chunks don't linger in
-- covered globals between snapshots. Two motivations:
--   1. Lingering chunks were re-read into WoWCombatLog.txt on every
--      subsequent SPELL_CAST_FAILED that hit a covered failedType,
--      duplicating the same chunk content for several seconds after a
--      flush completed (parser PRD §6.3 edge case).
--   2. On Ascension's secure auto-cast / hold-to-cast code path, secure
--      reads of a covered global with our chunk payload propagate taint
--      to the engine's secure execution context. Bear druids mashing
--      Swipe / Mangle / Maul through cooldowns reproduced repeated
--      "tainted the call of the secure function 'UNKNOWN()'" popups
--      until queue drained naturally on combat-end / zone-change.
-- Eager-restore shrinks the taint exposure window from "all-of-combat
-- after the first CI" down to "duration of an in-progress flush".
local function ensureClean()
    if H.globalsDirty then
        restoreAll()
        H.pendingChunk = nil
        ALC.Core.Metrics.inc("eager_restores")
    end
end

function H.enqueue(chunk)
    if not H.queue then
        H.queue = ALC.Core.Queue.newRing(C.RELAY_QUEUE_MAX_CHUNKS)
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
    H.pendingChunk = nil
end

-- Scope check: should the relay be active right now?
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

-- Called on every SPELL_CAST_FAILED sub-event in COMBAT_LOG_EVENT_UNFILTERED.
-- failedType is the localized fail-reason string the engine read for THIS
-- event (CLEU arg at C.RELAY_FAILEDTYPE_ARG_INDEX). If it starts with our
-- sentinel prefix, the previously-applied chunk made it into the log line
-- and the queue head can safely advance. Otherwise the chunk was eaten by
-- an uncovered Lua global or a C-side fail string, so we keep the same
-- head entry and re-apply it on the next event.
function H.onSpellCastFailed(failedType)
    if not H.active then return end
    if not H.queue or H.queue.size == 0 then
        H.pendingChunk = nil
        ensureClean()
        return
    end

    -- Evict stale chunks at the head
    local nowSec = time()
    local ttl = C.RELAY_CHUNK_TTL_S
    while H.queue.size > 0 do
        local head = ALC.Core.Queue.ringPeek(H.queue, 0)
        if head and (nowSec - head.pushed_at) > ttl then
            ALC.Core.Queue.ringAdvance(H.queue)
            ALC.Core.Metrics.inc("chunks_dropped_ttl")
            H.pendingChunk = nil
        else
            break
        end
    end
    if H.queue.size == 0 then
        ensureClean()
        return
    end

    -- Landed-evidence check: did the prior chunk make it into the log?
    -- Match the family prefix so both CI and PP chunks land-detect correctly.
    local prefix = C.RELAY_FAMILY_PREFIX
    local landed = H.pendingChunk
        and type(failedType) == "string"
        and failedType:sub(1, #prefix) == prefix

    if landed then
        ALC.Core.Queue.ringAdvance(H.queue)
        ALC.Core.Metrics.inc("chunks_landed")
        H.pendingChunk = nil
        if H.queue.size == 0 then
            ensureClean()
            return
        end
    elseif H.pendingChunk then
        -- Prior chunk was eaten (uncovered global or C-side fail string).
        -- Leave the head in place so the same chunk gets another shot.
        ALC.Core.Metrics.inc("chunks_re_applied")
    end

    -- Apply the (still-)current head; idempotent re-applies are cheap and
    -- keep the rewritten globals fresh in case anything else touched them.
    local entry = ALC.Core.Queue.ringPeek(H.queue, 0)
    if entry then
        applyChunk(entry.chunk)
        H.pendingChunk = entry.chunk
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
        ALC.Core.Logger.debug("Relay activated")
    elseif not want and H.active then
        restoreAll()
        H.active = false
        H.pendingChunk = nil
        ALC.Core.Metrics.inc("hijack_deactivations")
        ALC.Core.Logger.debug("Relay deactivated")
    end
end

-- UIErrorsFrame hook: silent-drop any message starting with our family prefix
-- (matches CI and PP chunks alike; any future chunk family inherits suppression).
local function installUIErrorSuppressor()
    if UIErrorsFrame and not UIErrorsFrame._alc_hooked then
        local orig = UIErrorsFrame.AddMessage
        UIErrorsFrame.AddMessage = function(self, msg, ...)
            if type(msg) == "string" and msg:sub(1, #C.RELAY_FAMILY_PREFIX) == C.RELAY_FAMILY_PREFIX then
                return
            end
            return orig(self, msg, ...)
        end
        UIErrorsFrame._alc_hooked = true
    end
end

-- Build a filter wrapper around an inner error handler. The wrapper
-- silently drops "AddOn 'AscensionLogsCompanion' tainted the call of the
-- secure function ..." Lua errors and forwards everything else to the
-- inner handler. Used by installTaintErrorSuppressor.
local function buildFilteredHandler(inner)
    return function(msg)
        if type(msg) == "string"
           and msg:find("AscensionLogsCompanion", 1, true)
           and msg:find("tainted the call", 1, true) then
            ALC.Core.Metrics.inc("taint_errors_suppressed")
            return
        end
        if inner then return inner(msg) end
    end
end

-- Taint error suppressor (added 0.40.0, hardened 0.41.1). Drops the
-- "AddOn 'AscensionLogsCompanion' tainted the call of the secure function
-- ..." Lua errors that fire when a hold-to-cast user (e.g. bear druids
-- hammering Maul/Swipe through cooldowns via button-held key repeat)
-- reads a chunk-loaded SPELL_FAILED_* global through the secure cast
-- path. The taint is inherent to the CLEU-hijack transport and eager-
-- restore already shrinks the exposure window to the in-progress flush
-- duration; this hook just hides the cosmetic surface. Chunks still
-- land in WoWCombatLog.txt and reassemble server-side - suppression
-- happens strictly downstream of CLEU emission.
--
-- 0.40.0 wrapped geterrorhandler() once at relay-start. That worked on
-- vanilla setups but lost the wrapper as soon as a later-loading error
-- handler addon (BugSack, !BugGrabber, ErrorHandler) called
-- seterrorhandler(itsHandler) - the engine kept their handler and
-- dropped our wrapper, so the taint error landed in their UI without
-- our filter. 0.41.1: hook seterrorhandler itself so any future caller
-- ends up with our filter wrapping their handler regardless of load
-- order.
local function installTaintErrorSuppressor()
    if H._taintErrorHandlerInstalled then return end
    H._taintErrorHandlerInstalled = true

    -- Wrap whichever handler is active right now.
    seterrorhandler(buildFilteredHandler(geterrorhandler()))

    -- Replace seterrorhandler so any later caller implicitly chains our
    -- filter on top of their handler. Stays idempotent across repeated
    -- calls (each rebuild keeps our filter on the outside).
    local origSetErrorHandler = seterrorhandler
    seterrorhandler = function(newHandler)
        return origSetErrorHandler(buildFilteredHandler(newHandler))
    end
end

-- True when the popup is the ALC-attributed taint dialog. 3.3.5's
-- ADDON_ACTION_BLOCKED is triggered as StaticPopup_Show(which, addonName)
-- where addonName lands in text_arg1, NOT the `data` arg, so checking
-- only `data` (as 0.40.0 did) misses every engine-triggered taint popup.
-- The rendered text always contains the addon name regardless of which
-- slot the caller used, so match against that as well.
local function alcMatchesPopup(self, data)
    if data == "AscensionLogsCompanion" then return true end
    if self and self.text and self.text.GetText then
        local txt = self.text:GetText()
        if txt and txt:find("AscensionLogsCompanion", 1, true) then
            return true
        end
    end
    return false
end

-- Taint popup suppressor (added 0.40.0, hardened 0.41.1). Companion to
-- the error-handler hook above. If cumulative taint promotes to the
-- modal ADDON_ACTION_FORBIDDEN / ADDON_ACTION_BLOCKED dialog rather
-- than the inline ScriptErrorsFrame variant, this catches it.
--
-- 0.41.1 changes:
--   1. OnShow override now also matches the popup's rendered text
--      (alcMatchesPopup) so engine-triggered taint popups - which carry
--      the addon name in text_arg1 rather than `data` - are caught.
--   2. Belt-and-suspenders hooksecurefunc on StaticPopup_Show calls
--      StaticPopup_Hide immediately when which is ADDON_ACTION_FORBIDDEN
--      or ADDON_ACTION_BLOCKED and text_arg1 is ours. This survives any
--      later override of the OnShow handler on the dialog template.
local function installTaintPopupSuppressor()
    if not _G.StaticPopupDialogs then return end
    for _, dlgKey in ipairs({"ADDON_ACTION_FORBIDDEN", "ADDON_ACTION_BLOCKED"}) do
        local t = StaticPopupDialogs[dlgKey]
        if t and not t._alc_hooked then
            local origOnShow = t.OnShow
            t.OnShow = function(self, data)
                if alcMatchesPopup(self, data) then
                    self:Hide()
                    ALC.Core.Metrics.inc("taint_popups_suppressed")
                    return
                end
                if origOnShow then return origOnShow(self, data) end
            end
            t._alc_hooked = true
        end
    end

    -- Fallback that survives any later override of t.OnShow on the
    -- templates above. Fires after the engine's StaticPopup_Show, so
    -- the dialog briefly appears and is then auto-hidden on the same
    -- frame. Counter is not incremented here to avoid double-counting
    -- with the OnShow path; if our OnShow override is bypassed and only
    -- this fallback hides the popup, the taint_popups_suppressed metric
    -- will under-count slightly. Acceptable trade for a diagnostic.
    if not H._taintPopupShowHooked and type(_G.StaticPopup_Show) == "function" then
        hooksecurefunc("StaticPopup_Show", function(which, text_arg1)
            if (which == "ADDON_ACTION_FORBIDDEN" or which == "ADDON_ACTION_BLOCKED")
               and text_arg1 == "AscensionLogsCompanion" then
                StaticPopup_Hide(which)
            end
        end)
        H._taintPopupShowHooked = true
    end
end

function H.start()
    installUIErrorSuppressor()
    installTaintErrorSuppressor()
    installTaintPopupSuppressor()

    ALC.RegisterEvent("PLAYER_REGEN_DISABLED", H.reevaluate)
    ALC.RegisterEvent("PLAYER_REGEN_ENABLED", function()
        H.reevaluate()
        -- Do NOT clear the queue here. Short pulls (5-10s of trash) routinely
        -- end with undrained chunks; clearing would drop them. Instead let
        -- undrained chunks roll into the next combat, where TTL eviction
        -- (RELAY_CHUNK_TTL_S) lazily evicts stale entries at the head and
        -- the 400-chunk ring cap bounds growth. lastPeerEnqueued dedup
        -- prevents re-enqueueing the same capture.
    end)
    ALC.RegisterEvent("ZONE_CHANGED_NEW_AREA", H.reevaluate)
    ALC.RegisterEvent("PLAYER_ENTERING_WORLD", H.reevaluate)
    ALC.RegisterEvent("PLAYER_LOGOUT", function() restoreAll() end)

    -- Hook into combat log event for SPELL_CAST_FAILED triggering. Pull
    -- failedType from the documented CLEU arg index so the gating check
    -- can compare it against RELAY_FAMILY_PREFIX.
    ALC.RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED", function(event, ...)
        local _, subEvent = ...
        if subEvent == "SPELL_CAST_FAILED" then
            local failedType = select(C.RELAY_FAILEDTYPE_ARG_INDEX, ...)
            H.onSpellCastFailed(failedType)
        end
    end)
end

-- User kill switch. Note: the SavedVariable key stays `hijack_enabled` to
-- preserve user configs across the rename; only the module surface was
-- renamed to "Relay" in 0.30.1.
function H.disable()
    _G.ALC_Config.hijack_enabled = false
    H.reevaluate()
end
