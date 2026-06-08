-- Zone/ZoneMonitor.lua
-- Auto-toggles /combatlog on zone transitions.
--
-- 0.2.3: only main-zone changes (ZONE_CHANGED_NEW_AREA + PLAYER_ENTERING_WORLD)
-- drive auto-logging. Sub-zone events (ZONE_CHANGED, ZONE_CHANGED_INDOORS) are
-- not registered. Tradeoff: outdoor world-boss subzones (Lord Kazzak in
-- Tainted Scar, Scarab Wall, Doomwalker in Snowblind Hills, etc.) no longer
-- auto-trigger logging on entry - they need a manual /combatlog. We accept
-- this to keep behavior predictable inside indoor instances, where sub-zone
-- noise was causing surprise re-starts (see e_shikari report on v0.2.0/0.2.1).
--
-- Coexistence: checks LoggingCombat() before calling /combatlog, so if
-- another addon (FangYuanWoW/CombatLogs) has already enabled logging, we
-- no-op rather than toggling it off.

local ALC = _G.ALC
local Z = {}
ALC.Zone.ZoneMonitor = Z

Z.lastLoggedZone = nil
Z.startedByUs = false
Z.popupShownForZone = nil  -- track which zone we popped for, to avoid re-spam within the same visit

-- Popup shown when leaving a monitored zone where ALC started logging.
-- Asks before stopping rather than auto-stopping, since players often
-- want to keep logging through trash/town/etc. before re-engaging.
StaticPopupDialogs["ALC_COMBATLOG_STOP_PROMPT"] = {
    text = "",  -- set dynamically per zone
    button1 = "Stop logging",
    button2 = "Keep logging",
    OnAccept = function()
        if LoggingCombat() then
            SlashCmdList["COMBATLOG"]("")
            if ALC.Core.Logger then
                ALC.Core.Logger.info("Combat logging stopped.")
            end
        end
        Z.startedByUs = false
        Z.lastLoggedZone = nil
        Z.popupShownForZone = nil
    end,
    OnCancel = function()
        -- User wants to keep logging through this zone. Clear the zone tag
        -- so the next non-monitored zone change doesn't immediately re-fire
        -- the stop popup, but KEEP startedByUs = true so we re-engage the
        -- prompt the next time they leave a monitored zone (re-entering one
        -- via the silent "claim state" branch keeps our ownership intact).
        Z.lastLoggedZone = nil
        Z.popupShownForZone = nil
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
}

-- Popup shown when ALC starts /combatlog on entering a monitored zone.
-- Buttons: OK (keep logging), Do Not Log (stop), and conditionally
-- Hide Transmog (opt-in cleaner-captures action when transmog viewing
-- is currently on). The third button + warning text is added at show
-- time only when C_Appearance.CanSeeAppearances() is true; otherwise
-- the popup stays compact.
StaticPopupDialogs["ALC_COMBATLOG_STARTED"] = {
    text = "",  -- set dynamically per zone
    button1 = "OK",
    button2 = "Do Not Log",
    button3 = nil,  -- set dynamically when transmog viewing is on
    OnAccept = function()
        -- User wants to keep logging; nothing to do, addon already started it
    end,
    OnCancel = function()
        -- User declined for this entry. Stop logging, fully reset state so
        -- the next zone-in to a monitored zone shows a fresh popup. We do
        -- NOT remember the decline across zone-out + zone-back-in - the
        -- intent is "ask me every time I come back," not "never log this
        -- zone for the rest of the session." (v0.2.3's main-zone-only
        -- registration ensures sub-zone walks within the same visit don't
        -- re-fire the popup, so per-entry semantics are safe.)
        if LoggingCombat() then
            SlashCmdList["COMBATLOG"]("")
            if ALC.Core.Logger then
                ALC.Core.Logger.info("Logging stopped at user request.")
            end
        end
        Z.startedByUs = false
        Z.lastLoggedZone = nil
        Z.popupShownForZone = nil  -- so re-entry to a monitored zone re-prompts
    end,
    OnAlt = function()
        -- Third button: hide transmog (preserves spell-visuals state) and
        -- keep logging. Captures from this point onward are clean.
        if _G.C_Appearance and type(C_Appearance.CanSeeAppearances) == "function"
           and type(C_Appearance.SetCanSeeAppearances) == "function" then
            local ok, _, spellVisuals = pcall(C_Appearance.CanSeeAppearances)
            if ok then
                pcall(C_Appearance.SetCanSeeAppearances, false, spellVisuals)
                if ALC.Core.Logger then
                    ALC.Core.Logger.info("Transmog viewing disabled. Captures will use real gear.")
                end
                -- Defer the panel refresh - CanSeeAppearances reads the
                -- live setting state, which doesn't update synchronously
                -- after SetCanSeeAppearances. A 0.1s delay is enough for
                -- the next frame's read to return the new value.
                local doRefresh = function()
                    if ALC.UI and ALC.UI.SettingsFrame and ALC.UI.SettingsFrame.refreshCheckboxes then
                        ALC.UI.SettingsFrame.refreshCheckboxes()
                    end
                end
                if _G.C_Timer and C_Timer.After then
                    C_Timer.After(0.1, doRefresh)
                else
                    -- Fallback: OnUpdate one-shot
                    local f = CreateFrame("Frame")
                    local started = GetTime()
                    f:SetScript("OnUpdate", function(self, el)
                        if GetTime() - started >= 0.1 then
                            self:SetScript("OnUpdate", nil)
                            doRefresh()
                        end
                    end)
                end
            end
        end
        -- Logging continues - we don't stop it, popup just closes.
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
}

local function currentZone()
    local zoneName = GetZoneText()
    local instanceName = GetInstanceInfo()
    return (instanceName and instanceName ~= "" and instanceName) or zoneName
end

local function zoneIsMonitored(name)
    if not name or not _G.ALC_Config or not ALC_Config.monitored_zones then
        return false
    end
    local lower = name:lower()
    for zone, enabled in pairs(ALC_Config.monitored_zones) do
        if enabled and zone:lower() == lower then return true end
    end
    return false
end

-- CoA Manastorm awareness. Inside a Manastorm the per-level instance name is the
-- recycled boss's HOME dungeon (RFK / Scarlet Monastery / Deadmines / ...), so it
-- thrashes across level transitions and may not be in monitored_zones at all -
-- the normal name match misses the run. Returns false off CoA (C_Manastorm
-- absent -> ManastormScan.isInManastorm() is false), so this is inert elsewhere.
local function inManastorm()
    local MS = ALC.Capture.ManastormScan
    return (MS and MS.isInManastorm and MS.isInManastorm()) or false
end

local function startLogging(zoneName, showPopup)
    if LoggingCombat() then
        -- Someone else already started it (or user kept it on across zones).
        -- Claim state without toggling so we still track this as ours, and
        -- tell the user explicitly so they know nothing was changed.
        local wasOurs = Z.startedByUs
        Z.lastLoggedZone = zoneName
        if wasOurs then
            ALC.Core.Logger.info("Combat log already active for: " .. zoneName)
        else
            ALC.Core.Logger.info("Combat log already on (started elsewhere) for: " .. zoneName)
        end
        return
    end
    if not ALC_Config.auto_combatlog_on_raid then return end

    -- Dungeon gate: when log_dungeons is off, only raid instances trigger
    -- auto-logging. 5-man dungeons (instanceType="party") are skipped.
    -- World-boss subzones aren't instanced (IsInInstance returns "none")
    -- so they continue to trigger as long as the zone is in the list.
    local _, instanceType = IsInInstance()
    if instanceType == "party" and not ALC_Config.log_dungeons and not inManastorm() then
        ALC.Core.Logger.debug("Skipping auto-/combatlog: " .. zoneName .. " is a 5-man and 'Log dungeons' is off")
        return
    end

    -- Activate /combatlog
    SlashCmdList["COMBATLOG"]("")
    Z.lastLoggedZone = zoneName
    Z.startedByUs = true
    ALC.Core.Logger.info("Combat logging started for: " .. zoneName)

    -- Show popup ONLY on main zone change (showPopup=true), and ONLY once
    -- per zone entry (don't re-spam if user crosses subzones inside).
    if showPopup and Z.popupShownForZone ~= zoneName then
        Z.popupShownForZone = zoneName
        local popup = StaticPopupDialogs["ALC_COMBATLOG_STARTED"]

        -- Detect whether the user currently has other-player transmog
        -- visible. If on, surface a warning + opt-in third button so
        -- they can hide transmog right here for cleaner captures
        -- without having to open /alc settings mid-pull.
        local transmogOn = false
        if _G.C_Appearance and type(C_Appearance.CanSeeAppearances) == "function" then
            local ok, t = pcall(C_Appearance.CanSeeAppearances)
            transmogOn = ok and t and true or false
        end

        local baseText =
            "|TInterface\\AddOns\\AscensionLogsCompanion\\Media\\logo-128.tga:32:32:0:0|t  |cff4ec3ffAscension Logs|r |cffe8e8e8Companion|r\n" ..
            "|cff555555------------------------------|r\n" ..
            "Starting |cffffd200/combatlog|r for:\n" ..
            "|cff00ffff" .. zoneName .. "|r\n\n" ..
            "Output: |cffaaaaaaLogs\\WoWCombatLog.txt|r"

        if transmogOn then
            popup.text = baseText
                .. "\n\n|cffff8800Transmog viewing is ON.|r Captured gear may show vanity items in place of real gear. ALC retries to detect the real items, but it isn't always accurate.\n\n"
                .. "|cffaaaaaaClick |r|cffffd200Hide Transmog|r|cffaaaaaa to disable for cleaner captures. Re-enable any time via |r|cffffd200/alc|r|cffaaaaaa settings or the wardrobe pane's Disable/Enable Transmog button.|r"
            popup.button3 = "Hide Transmog"
        else
            popup.text = baseText
            popup.button3 = nil
        end

        StaticPopup_Show("ALC_COMBATLOG_STARTED")
    end
end

local function stopLoggingIfWeStarted()
    if Z.startedByUs and LoggingCombat() then
        SlashCmdList["COMBATLOG"]("")
        ALC.Core.Logger.info("Combat logging stopped.")
    end
    Z.startedByUs = false
    Z.lastLoggedZone = nil
    -- Reset popup tracking so re-entering the zone shows the popup again
    Z.popupShownForZone = nil
end

function Z.check(isMainZoneChange)
    local zone = currentZone()
    -- Collapse a Manastorm to one stable monitored zone so we prompt once on
    -- entry and never fire the "left monitored zone" stop prompt as you warp
    -- between levels (each level reports its boss's home-dungeon name).
    if inManastorm() then zone = "The Manastorm" end
    local monitored = zoneIsMonitored(zone) or inManastorm()
    local silent = _G.ALC_Config and ALC_Config.silent_auto_logging

    if monitored and Z.lastLoggedZone ~= zone then
        -- In silent mode, suppress the start popup. Logging still starts.
        startLogging(zone, isMainZoneChange and not silent)
    elseif not monitored and Z.lastLoggedZone and Z.startedByUs and isMainZoneChange and not silent then
        -- Left a monitored area where WE started logging. Prompt rather than
        -- auto-stop: players often want to keep logging through town/world
        -- between dungeons or for the inn buff phase before re-pulling.
        -- Silent mode skips this entirely - logging just stays on.
        local leftZone = Z.lastLoggedZone
        StaticPopupDialogs["ALC_COMBATLOG_STOP_PROMPT"].text =
            "|TInterface\\AddOns\\AscensionLogsCompanion\\Media\\logo-128.tga:32:32:0:0|t  |cff4ec3ffAscension Logs|r |cffe8e8e8Companion|r\n" ..
            "|cff555555------------------------------|r\n" ..
            "Left monitored zone:\n" ..
            "|cff00ffff" .. leftZone .. "|r\n\n" ..
            "Stop |cffffd200/combatlog|r?"
        StaticPopup_Show("ALC_COMBATLOG_STOP_PROMPT")
    end
end

function Z.start()
    _G.ALC_Config = _G.ALC_Config or {}
    ALC_Config.monitored_zones = ALC_Config.monitored_zones or {}
    -- Seed defaults for any zone not already explicitly configured
    for zone, v in pairs(ALC.Zone.DefaultZones.DEFAULTS) do
        if ALC_Config.monitored_zones[zone] == nil then
            ALC_Config.monitored_zones[zone] = v
        end
    end

    -- Main-zone-only registration. ZONE_CHANGED + ZONE_CHANGED_INDOORS
    -- intentionally not registered (see file header for rationale).
    ALC.RegisterEvent("ZONE_CHANGED_NEW_AREA", function() Z.check(true) end)
    ALC.RegisterEvent("PLAYER_ENTERING_WORLD", function() Z.check(true) end)

    -- CoA Manastorm entry: the scenario teleport may not raise a clean
    -- ZONE_CHANGED_NEW_AREA we recognize, so also drive the check off the
    -- Manastorm signals (entry + each level transition). Z.check is idempotent
    -- (lastLoggedZone collapses to "The Manastorm") so repeats don't re-prompt.
    -- TryRegisterEvent: these events are absent off CoA, so this is inert there.
    ALC.TryRegisterEvent("ENTER_MANASTORM_RESULT",  function() Z.check(true) end)
    ALC.TryRegisterEvent("ACTIVE_MANASTORM_UPDATED", function() Z.check(true) end)
end
