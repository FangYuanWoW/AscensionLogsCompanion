-- UI/SettingsFrame.lua
-- Two-tab settings panel: a Settings page (toggles + addon options) and a
-- Monitored Zones page (current zone + zone list + add). Sidebar on the
-- left selects the active tab. Layout:
--
--   +-----------------------------------------------+
--   |              [logo] Ascension Logs Companion  |
--   |                v0.1.x · subtitle              |
--   +-----------+-----------------------------------+
--   |  Settings  |                                   |
--   | -[Zones]-- |   <active tab content>            |
--   |            |                                   |
--   |            |                                   |
--   +-----------+-----------------------------------+
--   |   /alc status footer                          |
--   +-----------------------------------------------+

local ALC = _G.ALC
local UI = {}
ALC.UI.SettingsFrame = UI

local function cfg()
    _G.ALC_Config = _G.ALC_Config or {}
    ALC_Config.monitored_zones = ALC_Config.monitored_zones or {}
    return ALC_Config
end

-- Registry of all checkboxes + their getters, used by refreshCheckboxes()
-- to re-sync state when the panel reopens or when an external action
-- (popup, slash command, wardrobe button) flips the underlying value.
UI.checkboxRefs = UI.checkboxRefs or {}

local function makeCheckbox(parent, label, x, y, getFn, setFn)
    local cb = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
    cb:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
    cb:SetSize(24, 24)
    local text = cb:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    text:SetPoint("LEFT", cb, "RIGHT", 5, 0)
    text:SetText(label)
    cb:SetChecked(getFn())
    cb:SetScript("OnClick", function(self)
        setFn(self:GetChecked() and true or false)
    end)
    -- Expose the label so callers can grey it out when the box is disabled.
    cb.label = text
    -- Register so external state-change paths can re-sync.
    table.insert(UI.checkboxRefs, { cb = cb, getFn = getFn })
    return cb
end

-- Re-read every registered checkbox's current state from its getter and
-- update the displayed checked/unchecked. Call this whenever the
-- underlying state may have changed outside the UI - e.g. after a popup
-- button toggles a setting, or when the panel reopens.
function UI.refreshCheckboxes()
    for _, e in ipairs(UI.checkboxRefs or {}) do
        if e.cb and e.getFn then
            e.cb:SetChecked(e.getFn() and true or false)
        end
    end
end

-- Toggle a checkbox between active and disabled-looking states. Used to
-- grey out dependent toggles (e.g. silent auto-logging when auto-/combatlog
-- is off) so it's visually obvious that they have no effect.
local function setCheckboxEnabled(cb, helpText, enabled)
    if enabled then
        cb:Enable()
        cb.label:SetTextColor(1, 0.82, 0)  -- normal yellow
        if helpText then helpText:SetTextColor(0.55, 0.55, 0.55) end
    else
        cb:Disable()
        cb.label:SetTextColor(0.5, 0.42, 0.18)  -- dimmed
        if helpText then helpText:SetTextColor(0.35, 0.35, 0.35) end
    end
end

local function currentZoneName()
    local instanceName = GetInstanceInfo()
    if instanceName and instanceName ~= "" then return instanceName end
    return GetZoneText() or "Unknown"
end

-- Build a sidebar tab button. Sets active visual when selected, calls onClick.
-- Width 148 to span from sidebar's left edge all the way up to the
-- vertical divider that separates sidebar from content (sidebar is 140
-- wide; divider sits 8px past sidebar's right edge). This makes the
-- active-state highlight read as filling the full "table of contents"
-- panel, with comfortable padding around the label text.
local function makeTab(parent, label, x, y, onClick)
    local btn = CreateFrame("Button", nil, parent)
    btn:SetSize(148, 28)
    btn:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
    btn:EnableMouse(true)

    -- Explicit anchors instead of SetAllPoints - the implicit form
    -- occasionally renders narrower than the button on 3.3.5. Two-corner
    -- anchoring forces the texture to span the full button rect.
    local bg = btn:CreateTexture(nil, "BACKGROUND")
    bg:SetPoint("TOPLEFT", btn, "TOPLEFT", 0, 0)
    bg:SetPoint("BOTTOMRIGHT", btn, "BOTTOMRIGHT", 0, 0)
    bg:SetTexture(0, 0, 0, 0)  -- transparent default
    btn.bg = bg

    local accent = btn:CreateTexture(nil, "OVERLAY")
    accent:SetSize(3, 22)
    accent:SetPoint("LEFT", btn, "LEFT", 0, 0)
    accent:SetTexture(0.31, 0.76, 1.0, 0)  -- alpha 0 by default; turns on when active
    btn.accent = accent

    local text = btn:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    text:SetPoint("LEFT", btn, "LEFT", 12, 0)
    text:SetText(label)
    btn.text = text

    btn:SetScript("OnEnter", function(self)
        if not self.isActive then
            self.bg:SetTexture(1, 1, 1, 0.05)
        end
    end)
    btn:SetScript("OnLeave", function(self)
        if not self.isActive then
            self.bg:SetTexture(0, 0, 0, 0)
        end
    end)
    btn:SetScript("OnClick", onClick)
    return btn
end

-- Activate a tab visually. Pass the active button + the list of all tab buttons
-- so we can dim the others.
local function activateTab(active, allTabs)
    for _, t in ipairs(allTabs) do
        if t == active then
            t.isActive = true
            t.bg:SetTexture(0.31, 0.76, 1.0, 0.12)   -- subtle blue wash
            t.accent:SetTexture(0.31, 0.76, 1.0, 1)  -- bright accent bar
            t.text:SetTextColor(1, 1, 1, 1)
        else
            t.isActive = false
            t.bg:SetTexture(0, 0, 0, 0)
            t.accent:SetTexture(0.31, 0.76, 1.0, 0)
            t.text:SetTextColor(0.65, 0.65, 0.65, 1)
        end
    end
end

function UI.create()
    if UI.frame then return UI.frame end
    local f = CreateFrame("Frame", "ALC_SettingsFrame", UIParent)
    f:SetSize(580, 580)
    f:SetPoint("CENTER")
    f:SetBackdrop({
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile = true, tileSize = 32, edgeSize = 32,
        insets = { left = 8, right = 8, top = 8, bottom = 8 },
    })
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)
    f:SetClampedToScreen(true)
    f:SetFrameStrata("DIALOG")
    f:Hide()

    -- ---------- Header ----------
    local logo = f:CreateTexture(nil, "OVERLAY")
    logo:SetTexture("Interface\\AddOns\\AscensionLogsCompanion\\Media\\logo-128.tga")
    logo:SetSize(48, 48)
    logo:SetPoint("TOPLEFT", f, "TOPLEFT", 18, -14)

    local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("LEFT", logo, "RIGHT", 10, 6)
    title:SetText("|cff4ec3ffAscension Logs|r |cffe8e8e8Companion|r")

    local subtitle = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    subtitle:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -2)
    subtitle:SetText("|cff888888v" .. ALC.Core.Constants.VERSION .. "  ·  Extending 3.3.5 combat logs with Combatant Information|r")

    local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", f, "TOPRIGHT", -5, -5)

    -- Divider line under header
    local divider = f:CreateTexture(nil, "OVERLAY")
    divider:SetSize(540, 1)
    divider:SetPoint("TOP", f, "TOP", 0, -76)
    divider:SetTexture(0.4, 0.4, 0.4, 0.5)

    -- ---------- Sidebar (tab list) ----------
    -- Anchored below the header divider, on the left side. 140 wide gives
    -- comfortable padding around tab labels.
    local sidebar = CreateFrame("Frame", nil, f)
    sidebar:SetSize(140, 460)
    sidebar:SetPoint("TOPLEFT", f, "TOPLEFT", 14, -86)

    -- Vertical divider between sidebar and content
    local vDivider = f:CreateTexture(nil, "OVERLAY")
    vDivider:SetSize(1, 440)
    vDivider:SetPoint("TOPLEFT", sidebar, "TOPRIGHT", 8, 0)
    vDivider:SetTexture(0.4, 0.4, 0.4, 0.5)

    -- ---------- Settings page ----------
    local settingsPage = CreateFrame("Frame", nil, f)
    settingsPage:SetSize(388, 460)
    settingsPage:SetPoint("TOPLEFT", sidebar, "TOPRIGHT", 16, 0)
    UI.settingsPage = settingsPage

    -- Helper: a small section header. Yellow-orange caps text with a thin
    -- divider underneath. Returns the divider so subsequent items can
    -- anchor below it.
    local function sectionHeader(text, y)
        local h = settingsPage:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        h:SetPoint("TOPLEFT", settingsPage, "TOPLEFT", 4, y)
        h:SetText("|cffffd200" .. text .. "|r")
        local underline = settingsPage:CreateTexture(nil, "OVERLAY")
        underline:SetSize(360, 1)
        underline:SetPoint("TOPLEFT", h, "BOTTOMLEFT", 0, -3)
        underline:SetTexture(0.4, 0.4, 0.4, 0.4)
        return h
    end

    -- Forward refs for dependent-toggle wiring (see refreshDependents).
    local autoCb, silentCb, silentHelp, dungeonsCb, dungeonsHelp
    local refreshDependents

    -- ============== LOGGING ==============
    sectionHeader("LOGGING", -4)

    autoCb = makeCheckbox(settingsPage, "Auto /combatlog on raid/dungeon zone entry", 4, -28,
        function() return cfg().auto_combatlog_on_raid end,
        function(v)
            cfg().auto_combatlog_on_raid = v
            if refreshDependents then refreshDependents() end
        end)
    local autoHelp = settingsPage:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    autoHelp:SetPoint("TOPLEFT", autoCb, "BOTTOMLEFT", 29, -2)
    autoHelp:SetWidth(340)
    autoHelp:SetJustifyH("LEFT")
    autoHelp:SetText("|cff888888On zone entry, /combatlog auto-starts and a popup asks if you want to log. On exit, a popup asks if you want to stop.|r")

    silentCb = makeCheckbox(settingsPage, "Silent auto-logging (skip start/stop prompts)", 4, -82,
        function() return cfg().silent_auto_logging end,
        function(v) cfg().silent_auto_logging = v end)
    silentHelp = settingsPage:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    silentHelp:SetPoint("TOPLEFT", silentCb, "BOTTOMLEFT", 29, -2)
    silentHelp:SetWidth(340)
    silentHelp:SetJustifyH("LEFT")
    silentHelp:SetText("|cff888888Starts /combatlog silently on zone entry. Never auto-stops. Manually toggle /combatlog to stop.|r")

    dungeonsCb = makeCheckbox(settingsPage, "Log 5-man dungeons", 4, -126,
        function() return cfg().log_dungeons ~= false end,
        function(v) cfg().log_dungeons = v end)
    dungeonsHelp = settingsPage:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    dungeonsHelp:SetPoint("TOPLEFT", dungeonsCb, "BOTTOMLEFT", 29, -2)
    dungeonsHelp:SetWidth(340)
    dungeonsHelp:SetJustifyH("LEFT")
    dungeonsHelp:SetText("|cff888888When off, auto-/combatlog only fires for raids. 5-man dungeons are skipped.|r")

    -- ============== CAPTURE QUALITY ==============
    sectionHeader("CAPTURE QUALITY", -180)

    if _G.C_Appearance and type(_G.C_Appearance.CanSeeAppearances) == "function"
       and type(_G.C_Appearance.SetCanSeeAppearances) == "function" then
        local hideTmogCb = makeCheckbox(settingsPage, "Hide other players' transmog (cleaner captures)", 4, -204,
            function()
                local ok, transmog = pcall(_G.C_Appearance.CanSeeAppearances)
                return ok and not transmog
            end,
            function(v)
                local ok, _, spellVisuals = pcall(_G.C_Appearance.CanSeeAppearances)
                if ok then
                    pcall(_G.C_Appearance.SetCanSeeAppearances, not v, spellVisuals)
                end
            end)
        local hideHelp = settingsPage:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        hideHelp:SetPoint("TOPLEFT", hideTmogCb, "BOTTOMLEFT", 29, -2)
        hideHelp:SetWidth(340)
        hideHelp:SetJustifyH("LEFT")
        hideHelp:SetText(
            "|cff888888"
            .. "• ALC's inspect routine may return the transmog item id instead of the real gear.\n"
            .. "• ALC does its best to detect and capture both, but the Ascension inspect API may not always expose the underlying real item.\n"
            .. "• As a result, reports may show vanity items in place of the underlying item.\n"
            .. "• Disabling transmog is the sure-fire way to capture the actual gear.\n"
            .. "• Trade-off: you won't see other players' transmog on your screen."
            .. "|r")
    end

    -- ============== INTERFACE ==============
    -- Pushed below the 5-bullet transmog help block (~5 lines × ~14px)
    -- so the section header doesn't overlap the last bullet.
    sectionHeader("INTERFACE", -348)

    makeCheckbox(settingsPage, "Show minimap icon", 4, -372,
        function()
            return not (_G.ALC_Config and ALC_Config.minimap_button
                        and ALC_Config.minimap_button.hide)
        end,
        function(v)
            if v then
                if ALC.UI.MinimapButton and ALC.UI.MinimapButton.show then
                    ALC.UI.MinimapButton.show()
                end
            else
                if ALC.UI.MinimapButton and ALC.UI.MinimapButton.hide then
                    ALC.UI.MinimapButton.hide()
                end
            end
        end)

    makeCheckbox(settingsPage, "Debug mode (verbose chat logging)", 4, -400,
        function() return cfg().debug end,
        function(v) cfg().debug = v end)

    -- Wire dependents. silent + log-dungeons are no-ops when auto is off,
    -- so grey them out + force-uncheck so the UI doesn't lie about state.
    refreshDependents = function()
        local autoOn = cfg().auto_combatlog_on_raid and true or false
        setCheckboxEnabled(silentCb, silentHelp, autoOn)
        setCheckboxEnabled(dungeonsCb, dungeonsHelp, autoOn)
        if not autoOn then
            silentCb:SetChecked(false)
        end
    end
    refreshDependents()

    -- ---------- Monitored Zones page ----------
    local zonesPage = CreateFrame("Frame", nil, f)
    zonesPage:SetSize(388, 460)
    zonesPage:SetPoint("TOPLEFT", sidebar, "TOPRIGHT", 16, 0)
    UI.zonesPage = zonesPage

    local zoneRow = zonesPage:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    zoneRow:SetPoint("TOPLEFT", zonesPage, "TOPLEFT", 4, -8)
    zoneRow:SetText("Current zone:")

    local zoneText = zonesPage:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    zoneText:SetPoint("LEFT", zoneRow, "RIGHT", 6, 0)
    zoneText:SetText(currentZoneName())
    UI.zoneText = zoneText

    local addCurrent = CreateFrame("Button", nil, zonesPage, "UIPanelButtonTemplate")
    addCurrent:SetSize(110, 22)
    addCurrent:SetPoint("TOPRIGHT", zonesPage, "TOPRIGHT", -4, -4)
    addCurrent:SetText("Add Current")
    addCurrent:SetScript("OnClick", function()
        local zone = currentZoneName()
        if zone and zone ~= "" and zone ~= "Unknown" then
            cfg().monitored_zones[zone] = true
            UI.refreshZones()
            ALC.Core.Logger.info("Monitoring zone: " .. zone)
        end
    end)

    local zonesHelp = zonesPage:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    zonesHelp:SetPoint("TOPLEFT", zoneRow, "BOTTOMLEFT", 0, -8)
    zonesHelp:SetWidth(380)
    zonesHelp:SetJustifyH("LEFT")
    zonesHelp:SetText("|cff888888Entering one of these auto-starts /combatlog (when 'Auto /combatlog' is on).|r")

    -- ScrollFrame is 340 wide so the UIPanelScrollFrameTemplate's 22px
    -- scrollbar (auto-mounted on the right) fits inside the 388-wide
    -- content pane without overflowing into the panel border.
    local scrollFrame = CreateFrame("ScrollFrame", "ALC_ZoneScrollFrame", zonesPage, "UIPanelScrollFrameTemplate")
    scrollFrame:SetPoint("TOPLEFT", zonesHelp, "BOTTOMLEFT", 0, -6)
    scrollFrame:SetSize(340, 340)
    UI.scrollFrame = scrollFrame

    local content = CreateFrame("Frame", nil, scrollFrame)
    content:SetSize(340, 340)
    scrollFrame:SetScrollChild(content)
    UI.zoneListContent = content

    local addLabel = zonesPage:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    addLabel:SetPoint("TOPLEFT", scrollFrame, "BOTTOMLEFT", 0, -10)
    addLabel:SetText("Add zone:")

    local addEdit = CreateFrame("EditBox", "ALC_AddZoneEditBox", zonesPage, "InputBoxTemplate")
    addEdit:SetPoint("LEFT", addLabel, "RIGHT", 12, 0)
    addEdit:SetSize(180, 20)
    addEdit:SetAutoFocus(false)
    local function commit()
        local v = addEdit:GetText()
        if v and v ~= "" then
            cfg().monitored_zones[v] = true
            addEdit:SetText("")
            UI.refreshZones()
            ALC.Core.Logger.info("Monitoring zone: " .. v)
        end
        addEdit:ClearFocus()
    end
    addEdit:SetScript("OnEnterPressed", commit)
    addEdit:SetScript("OnEscapePressed", function() addEdit:ClearFocus() end)

    local addBtn = CreateFrame("Button", nil, zonesPage, "UIPanelButtonTemplate")
    addBtn:SetSize(60, 22)
    addBtn:SetPoint("LEFT", addEdit, "RIGHT", 6, 0)
    addBtn:SetText("Add")
    addBtn:SetScript("OnClick", commit)

    -- ---------- Tab buttons (created last so we can wire selection) ----------
    -- Monitored Zones first (default active) since users open the panel
    -- to manage zones more often than to flip core settings.
    local tabSettings, tabZones
    local allTabs = {}

    tabZones = makeTab(sidebar, "Monitored Zones", 0, -4, function()
        activateTab(tabZones, allTabs)
        zonesPage:Show()
        settingsPage:Hide()
    end)

    tabSettings = makeTab(sidebar, "Settings", 0, -36, function()
        activateTab(tabSettings, allTabs)
        settingsPage:Show()
        zonesPage:Hide()
    end)

    allTabs = { tabZones, tabSettings }
    UI.tabs = allTabs
    UI.tabZones = tabZones
    UI.tabSettings = tabSettings

    -- Public tab-switch helper for slash commands and other external
    -- callers. Pass "settings" or "zones".
    function UI.openTab(name)
        if not UI.frame then UI.create() end
        if name == "settings" then
            activateTab(tabSettings, allTabs)
            settingsPage:Show()
            zonesPage:Hide()
        else
            activateTab(tabZones, allTabs)
            zonesPage:Show()
            settingsPage:Hide()
        end
    end

    -- Default to Monitored Zones tab
    activateTab(tabZones, allTabs)
    zonesPage:Show()
    settingsPage:Hide()

    -- ---------- Footer ----------
    local status = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    status:SetPoint("BOTTOM", f, "BOTTOM", 0, 14)
    status:SetText("|cffaaaaaaType|r /alc status |cffaaaaaain chat for inspect counts and combatant info delivery stats|r")

    UI.frame = f
    UI.zoneRows = {}
    return f
end

-- Rebuild the scrollable zone list from ALC_Config.monitored_zones.
function UI.refreshZones()
    if not UI.zoneListContent then return end
    for _, row in ipairs(UI.zoneRows or {}) do
        row:Hide()
        row:SetParent(nil)
    end
    UI.zoneRows = {}

    local zones = {}
    for z, on in pairs(cfg().monitored_zones) do
        if on then zones[#zones + 1] = z end
    end
    table.sort(zones)

    local y = -2
    for _, zone in ipairs(zones) do
        local row = CreateFrame("Frame", nil, UI.zoneListContent)
        row:SetSize(340, 20)
        row:SetPoint("TOPLEFT", UI.zoneListContent, "TOPLEFT", 4, y)

        local txt = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        txt:SetPoint("LEFT", row, "LEFT", 4, 0)
        txt:SetText(zone)
        txt:SetJustifyH("LEFT")
        txt:SetWidth(290)

        local rm = CreateFrame("Button", nil, row, "UIPanelCloseButton")
        rm:SetSize(22, 22)
        rm:SetPoint("RIGHT", row, "RIGHT", -2, 0)
        local zoneCaptured = zone
        rm:SetScript("OnClick", function()
            cfg().monitored_zones[zoneCaptured] = nil
            UI.refreshZones()
            ALC.Core.Logger.info("Stopped monitoring zone: " .. zoneCaptured)
        end)

        UI.zoneRows[#UI.zoneRows + 1] = row
        y = y - 22
    end

    local h = math.max(340, math.abs(y) + 4)
    UI.zoneListContent:SetHeight(h)
end

local function refreshCurrentZone()
    if UI.zoneText then UI.zoneText:SetText(currentZoneName()) end
end

function UI.toggle()
    local f = UI.create()
    if f:IsShown() then
        f:Hide()
    else
        refreshCurrentZone()
        UI.refreshZones()
        UI.refreshCheckboxes()
        f:Show()
    end
end
