-- UI/KeystoneDrain.lua
-- On-demand drain prompt for the Mythic+ outcome record.
--
-- THE PROBLEM. The keystone "complete" chunk can only reach WoWCombatLog.txt by
-- riding an organic SPELL_CAST_FAILED: the addon rewrites the SPELL_FAILED_*
-- global error strings and the engine writes whichever one it needs into CLEU
-- arg 12. But a key ends with everyone standing still in a cleared dungeon and
-- nobody casting, and the logger frequently hearths out seconds later. Roughly
-- 40% of runs lost their outcome record this way, which is why so many reports
-- render "Completed" with no timer and no timed/depleted verdict.
--
-- WHY A BUTTON WORKS. Programmatic casting is dead on Ascension: every
-- cast-initiating function is protected and taints from insecure code, even out
-- of combat (see the note in KeystoneScan's outcome-flush section). What is NOT
-- blocked is a hardware click on a SecureActionButtonTemplate - the engine runs
-- that through its own secure path, so the click casts for real. Measured
-- 2026-08-09: 90 clicks produced 90 cast failures, and once the right global was
-- hijacked every log-visible failure carried a chunk (7/7 on disk, against 0/13
-- before the fix).
--
-- WHY FISHING. `/cast Fishing` with no pole throws "Must have a %s equipped."
-- instantly, with no target, no cooldown to wait on, and no class dependency -
-- which matters on classless, where "press something you have on cooldown" is
-- not a portable instruction. Its global is SPELL_FAILED_EQUIPPED_ITEM_CLASS.
-- With a pole equipped but no water it fails via SPELL_FAILED_NOT_HERE instead;
-- both are in the relay's hijack list, so either way the click carries a chunk.
--
-- COMBAT LOCK. Secure ATTRIBUTES cannot be set in combat, so the button is
-- built lazily on the first prompt rather than kept around for the whole run -
-- combat drops the moment a key completes, so by the +1s prompt we are reliably
-- out of it. If that ever does not hold, show() declines to open a button it
-- could not arm and waits for PLAYER_REGEN_ENABLED instead of presenting a
-- button that silently cannot cast. Nothing is created until a key finishes.
--
-- PROGRESS IS LANDED-EVIDENCE, NEVER CLICKS. Clicks and carriers are not 1:1 -
-- every click fails, but only a fraction become log-visible events (7 carriers
-- from one clicking burst; gaps 0.15s to 8.7s, so lossy rather than throttled).
-- The relay already re-applies a chunk until CLEU arg 12 proves it landed and
-- only then advances, so a click that produces no carrier costs nothing and the
-- next one retries the same chunk. Counting clicks would show fake progress;
-- KeystoneScan.pendingOutcome is the truth.

local ALC = _G.ALC
local C = ALC.Core.Constants

local D = {}
ALC.UI = ALC.UI or {}
ALC.UI.KeystoneDrain = D

D.SPELL = "Fishing"
D.frame = nil
D.total = 0
-- Length of the button's pacing swipe. Not a real cooldown, just the rhythm we
-- want people clicking at; see the note where the Cooldown frame is built.
D.CLICK_PACE_S = 1.0

local TITLE_DONE = "Keystone saved"
local TITLE_WAIT = "One step left"

------------------------------------------------------------------------------
-- Construction (out of combat only)

--- Build + configure the secure button. Safe to call repeatedly; the expensive
--- and combat-locked parts run once. Returns false if it could not arm.
function D.prearm()
    if InCombatLockdown and InCombatLockdown() then return false end
    if D.frame then
        -- Re-assert the attributes in case another addon or a spec swap
        -- disturbed them; still cheap, and still out of combat here.
        D.frame.action:SetAttribute("type", "spell")
        D.frame.action:SetAttribute("spell", D.SPELL)
        return true
    end

    local f = CreateFrame("Frame", "ALC_KeystoneDrainFrame", UIParent)
    f:SetWidth(420); f:SetHeight(166)   -- 166 fits the third body line
    f:SetPoint("TOP", UIParent, "TOP", 0, -160)
    -- Top-most: this is a one-shot prompt that is worthless if it opens behind
    -- the loot frame or a boss-kill splash.
    f:SetFrameStrata("FULLSCREEN_DIALOG")
    f:SetToplevel(true)
    f:EnableMouse(true)
    f:SetMovable(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", function(self) self:StartMoving() end)
    f:SetScript("OnDragStop", function(self) self:StopMovingOrSizing() end)

    local bg = f:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints(f)
    bg:SetTexture(0, 0, 0, 0.85)

    -- Brand line. Resolved through Core/Branding rather than hardcoded: the
    -- addon is white-labelled per tenant (0.64.0), so a literal "Ascension
    -- Logs" would render wrong on the Triumvirate build.
    local brand = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    brand:SetPoint("TOP", f, "TOP", 0, -8)
    brand:SetText(ALC.Core.Branding.titleRich())
    f.brand = brand

    local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOP", brand, "BOTTOM", 0, -6)
    f.title = title

    local body = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    body:SetPoint("TOP", title, "BOTTOM", 0, -8)
    body:SetWidth(380)
    body:SetJustifyH("CENTER")
    f.body = body

    -- The secure button itself. Attributes are set here, out of combat.
    local action = CreateFrame("Button", "ALC_KeystoneDrainButton", f,
                               "SecureActionButtonTemplate,UIPanelButtonTemplate")
    action:SetWidth(260); action:SetHeight(30)
    action:SetPoint("BOTTOM", f, "BOTTOM", 0, 40)
    -- Deliberately NOT branded ("Send to <brand>"): the click writes to the
    -- local combat log, it does not upload anything. Naming the site here
    -- implies a network action and would read as a lie to anyone who clicks it
    -- offline. The brand line at the top of the frame carries the identity.
    action:SetText("Send to Combat Log")
    action:RegisterForClicks("AnyUp")
    action:SetAttribute("type", "spell")
    action:SetAttribute("spell", D.SPELL)
    f.action = action

    -- Self-pacing swipe. Measured: hammering the button converts far WORSE than
    -- clicking steadily (43 clicks at ~4.9/sec produced a single usable
    -- combat-log event, 2.3%), because only log events advance the relay and
    -- the client emits them far more slowly than it fails the cast. Copy alone
    -- does not stop people spamming a button that looks unresponsive, so give
    -- them a visible rhythm to click to.
    --
    -- Purely cosmetic: a Cooldown sweep plus a PostClick, both insecure and
    -- both legal on a secure button. The button is deliberately NOT disabled -
    -- Enable/Disable around a protected frame in combat is a risk that buys
    -- nothing, and an extra click during the sweep is merely wasted, not
    -- harmful.
    local cd = CreateFrame("Cooldown", nil, action, "CooldownFrameTemplate")
    cd:SetAllPoints(action)
    f.cooldown = cd
    action:SetScript("PostClick", function()
        if CooldownFrame_SetTimer then
            CooldownFrame_SetTimer(cd, GetTime(), D.CLICK_PACE_S, 1)
        end
    end)

    local progress = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    progress:SetPoint("BOTTOM", f, "BOTTOM", 0, 18)
    f.progress = progress

    local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", f, "TOPRIGHT", -2, -2)
    close:SetScript("OnClick", function() D.hide() end)

    -- Landings drive the counter, but the BLOCKED state is ambient: zoning out
    -- of the dungeon or toggling /combatlog fires no chunk event, so without a
    -- poll the prompt would keep saying "click below" while every click was a
    -- no-op. Half a second is far below the cost of anything else on screen.
    local since = 0
    f:SetScript("OnUpdate", function(self, dt)
        since = since + dt
        if since < 0.5 then return end
        since = 0
        D.refresh()
    end)

    f:Hide()
    D.frame = f
    return true
end

-- Deliberately NO ambient arming here. An earlier revision pre-armed on
-- PLAYER_REGEN_ENABLED / PLAYER_ENTERING_WORLD, which built the frame on the
-- first combat drop for every player on every character, including the vast
-- majority who never run a key. Arming is now driven solely by show(), so
-- nothing exists until a keystone actually completes.

------------------------------------------------------------------------------
-- Presentation

local function pendingCount()
    local K = ALC.Capture and ALC.Capture.KeystoneScan
    local po = K and K.pendingOutcome
    return po and po.count or 0
end

--- Hold the relay's keepalive window open for as long as this prompt is up with
--- work left to do. beginOutcomeFlush already requests one at key-end, but it is
--- bounded (KS_KEEPALIVE_S, 45s) and a player who reads the prompt, finds the
--- button, and clicks a few times can easily outlast it - at which point the
--- relay sleeps mid-drain and clicks silently stop working. Re-asking each
--- refresh keeps the window tied to visible user intent: close the prompt and it
--- lapses on its own within 45s.
local function holdRelayAwake()
    local relay = ALC.Transport and ALC.Transport.SpellFailedRelay
    if relay and relay.requestKeepalive then
        relay.requestKeepalive(C.KS_KEEPALIVE_S or 45)
    end
end

--- Why the relay cannot carry a chunk right now, or nil if it can.
--- Deliberately does NOT check the instance gate: as of 0.67.1 an active
--- keepalive outranks it, and holdRelayAwake keeps one live for the whole time
--- this prompt is open. That is the entire point - the common loss case is
--- hearthing out the second the key ends, so the drain has to keep working
--- outside the dungeon. Only the two gates a keepalive cannot override remain.
local function relayBlockedReason()
    if not (_G.ALC_Config and ALC_Config.hijack_enabled) then return "hijack" end
    if not (LoggingCombat and LoggingCombat()) then return "logging" end
    return nil
end

local BLOCKED_TEXT = {
    logging = "Combat logging is off. Turn it on with /combatlog,\nthen click below.",
    hijack  = "Log relay is disabled in the addon settings.\nRe-enable it, then click below.",
}

function D.refresh()
    local f = D.frame
    if not f or not f:IsShown() then return end
    local left = pendingCount()
    if left <= 0 then
        f.title:SetText(TITLE_DONE)
        f.title:SetTextColor(0.2, 1.0, 0.3)
        f.body:SetText("Your keystone result is in the combat log.\n"
            .. "Upload it to " .. ALC.Core.Branding.domain() .. " as normal.")
        f.progress:SetText(string.format("%d of %d sent", D.total, D.total))
        f.progress:SetTextColor(0.2, 1.0, 0.3)
        f.action:Disable()
        return
    end
    -- Work still outstanding and the prompt is up: keep the relay awake so the
    -- drain survives leaving the dungeon and taking a while to click.
    holdRelayAwake()

    local blocked = relayBlockedReason()
    if blocked then
        f.title:SetText("Can't send yet")
        f.title:SetTextColor(1.0, 0.4, 0.4)
        f.body:SetText(BLOCKED_TEXT[blocked] or "The log relay is not running.")
        f.progress:SetText(string.format("%d of %d sent", math.max(0, D.total - left), D.total))
        f.progress:SetTextColor(1.0, 0.4, 0.4)
        -- Left enabled on purpose: the cast still fires, it just cannot carry a
        -- chunk. Disabling would make a recoverable state look terminal, and the
        -- moment they step back inside the next click works.
        f.action:Enable()
        return
    end

    f.title:SetText(TITLE_WAIT)
    f.title:SetTextColor(1.0, 0.82, 0.0)
    -- "Steadily, about once a second" rather than "a few times", and explicitly
    -- NOT "spam". Each chunk needs its own combat-log SPELL_CAST_FAILED event to
    -- ride, and the client emits those far less often than it fails the cast -
    -- measured ~7 log events against ~90 click-level failures. Rapid clicking
    -- therefore converts no faster than paced clicking, it just looks broken
    -- while nothing happens. Telling people to spam sets them up to conclude the
    -- button is dead.
    -- The instant-spell line is not filler. A chunk rides a combat-log
    -- SPELL_CAST_FAILED, and repeated identical Fishing failures appear to get
    -- deduped by the client, so the button alone can stall. Casting anything
    -- else in between breaks that pattern and reliably shakes one loose - it
    -- was the difference between stalling and finishing in testing.
    f.body:SetText("Your Mythic+ result has not reached the combat log yet.\n"
        .. "Click below each time the swipe clears, until it says " .. TITLE_DONE .. ".\n"
        .. "|cffaaaaaaCasting any instant spell in between helps it along.|r")
    f.progress:SetText(string.format("%d of %d sent", math.max(0, D.total - left), D.total))
    f.progress:SetTextColor(1.0, 0.82, 0.0)
    f.action:Enable()
end

function D.show()
    if not D.prearm() then
        -- Could not arm (in combat and never armed earlier). Retry when combat
        -- drops rather than showing a button that cannot cast.
        local retry = CreateFrame("Frame")
        retry:RegisterEvent("PLAYER_REGEN_ENABLED")
        retry:SetScript("OnEvent", function(self)
            self:UnregisterAllEvents()
            self:SetScript("OnEvent", nil)
            D.show()
        end)
        return
    end
    local left = pendingCount()
    if left <= 0 then return end   -- already landed organically; stay quiet
    D.total = left
    D.frame:Show()
    D.refresh()
    if type(_G.PlaySound) == "function" then pcall(PlaySound, "igQuestListOpen") end
end

function D.hide()
    if D.frame then D.frame:Hide() end
end

--- Called from KeystoneScan.onChunkLanded for every confirmed chunk.
function D.onLanded()
    D.refresh()
end

return D
