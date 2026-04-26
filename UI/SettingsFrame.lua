-- UI/SettingsFrame.lua
-- Settings frame for /alc. Ports the zone management UI from
-- FangYuanWoW/CombatLogs (DialogBox backdrop, scrollable zone list with
-- inline remove buttons, "Add Current" shortcut, add-zone input) into the
-- ALC settings panel, layered on top of the existing checkbox toggles.

local ALC = _G.ALC
local UI = {}
ALC.UI.SettingsFrame = UI

local function cfg()
    _G.ALC_Config = _G.ALC_Config or {}
    ALC_Config.monitored_zones = ALC_Config.monitored_zones or {}
    return ALC_Config
end

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
    return cb
end

local function currentZoneName()
    local instanceName = GetInstanceInfo()
    if instanceName and instanceName ~= "" then return instanceName end
    return GetZoneText() or "Unknown"
end

function UI.create()
    if UI.frame then return UI.frame end
    local f = CreateFrame("Frame", "ALC_SettingsFrame", UIParent)
    f:SetSize(440, 528)
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

    -- Centered logo + title stack. Brand mark on top, name underneath.
    local logo = f:CreateTexture(nil, "OVERLAY")
    logo:SetTexture("Interface\\AddOns\\AscensionLogsCompanion\\Media\\logo-128.tga")
    logo:SetSize(56, 56)
    logo:SetPoint("TOP", f, "TOP", 0, -14)

    local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOP", logo, "BOTTOM", 0, -4)
    title:SetText("|cff4ec3ffAscension Logs|r |cffe8e8e8Companion|r")

    local subtitle = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    subtitle:SetPoint("TOP", title, "BOTTOM", 0, -2)
    subtitle:SetText("|cff888888v" .. ALC.Core.Constants.VERSION .. "  ·  Extending 3.3.5 combat logs with Combatant Information|r")

    local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", f, "TOPRIGHT", -5, -5)

    -- Section header helper
    local function sectionHeader(text, anchor, yOffset)
        local h = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        h:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, yOffset or -14)
        h:SetText("|cffffd200" .. text .. "|r")
        return h
    end

    -- ---------- Toggles section ----------
    -- is_logger and hijack_enabled are essential for the addon to do anything
    -- useful and default to true — exposing them in the UI just risks users
    -- accidentally disabling the addon's core function. Kept slash-command
    -- accessible via /alc hijack off for emergency disable.
    local togglesHeader = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    togglesHeader:SetPoint("TOPLEFT", f, "TOPLEFT", 18, -110)
    togglesHeader:SetText("|cffffd200Settings|r")

    makeCheckbox(f, "Auto /combatlog on raid/dungeon zone entry", 18, -130,
        function() return cfg().auto_combatlog_on_raid end,
        function(v) cfg().auto_combatlog_on_raid = v end)

    local silentCb = makeCheckbox(f, "Silent auto-logging (skip start/stop prompts)", 18, -155,
        function() return cfg().silent_auto_logging end,
        function(v) cfg().silent_auto_logging = v end)

    local silentHelp = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    -- Anchor 29px right of the checkbox BOTTOMLEFT so the help text starts
    -- exactly under the label text (24px checkbox + 5px Blizzard label inset).
    silentHelp:SetPoint("TOPLEFT", silentCb, "BOTTOMLEFT", 29, -2)
    silentHelp:SetWidth(370)
    silentHelp:SetJustifyH("LEFT")
    silentHelp:SetText("|cff888888Starts /combatlog silently on zone entry. Never auto-stops. Manually toggle /combatlog to stop.|r")

    makeCheckbox(f, "Debug mode (verbose chat logging)", 18, -205,
        function() return cfg().debug end,
        function(v) cfg().debug = v end)

    -- ---------- Current zone section ----------
    local zoneRow = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    zoneRow:SetPoint("TOPLEFT", f, "TOPLEFT", 18, -245)
    zoneRow:SetText("Current zone:")

    local zoneText = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    zoneText:SetPoint("LEFT", zoneRow, "RIGHT", 6, 0)
    zoneText:SetText(currentZoneName())

    local addCurrent = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    addCurrent:SetSize(110, 22)
    addCurrent:SetPoint("TOPRIGHT", f, "TOPRIGHT", -18, -242)
    addCurrent:SetText("Add Current")
    addCurrent:SetScript("OnClick", function()
        local zone = currentZoneName()
        if zone and zone ~= "" and zone ~= "Unknown" then
            cfg().monitored_zones[zone] = true
            UI.refreshZones()
            ALC.Core.Logger.info("Monitoring zone: " .. zone)
        end
    end)

    -- ---------- Monitored zones list ----------
    local zonesHeader = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    zonesHeader:SetPoint("TOPLEFT", f, "TOPLEFT", 18, -273)
    zonesHeader:SetText("|cffffd200Monitored zones|r")

    local zonesHelp = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    zonesHelp:SetPoint("TOPLEFT", zonesHeader, "BOTTOMLEFT", 0, -2)
    zonesHelp:SetText("|cff888888Entering one of these auto-starts /combatlog (when the toggle above is on).|r")

    local scrollFrame = CreateFrame("ScrollFrame", "ALC_ZoneScrollFrame", f, "UIPanelScrollFrameTemplate")
    scrollFrame:SetPoint("TOPLEFT", zonesHelp, "BOTTOMLEFT", 0, -4)
    scrollFrame:SetSize(380, 130)
    UI.scrollFrame = scrollFrame

    local content = CreateFrame("Frame", nil, scrollFrame)
    content:SetSize(380, 130)
    scrollFrame:SetScrollChild(content)
    UI.zoneListContent = content

    -- Add-zone input
    local addLabel = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    addLabel:SetPoint("TOPLEFT", scrollFrame, "BOTTOMLEFT", 0, -12)
    addLabel:SetText("Add zone:")

    local addEdit = CreateFrame("EditBox", "ALC_AddZoneEditBox", f, "InputBoxTemplate")
    addEdit:SetPoint("LEFT", addLabel, "RIGHT", 12, 0)
    addEdit:SetSize(200, 20)
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

    local addBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    addBtn:SetSize(60, 22)
    addBtn:SetPoint("LEFT", addEdit, "RIGHT", 6, 0)
    addBtn:SetText("Add")
    addBtn:SetScript("OnClick", commit)

    -- ---------- Footer ----------
    local status = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    status:SetPoint("BOTTOM", f, "BOTTOM", 0, 14)
    status:SetText("|cffaaaaaaType|r /alc status |cffaaaaaain chat for inspect counts and combatant info delivery stats|r")

    UI.frame = f
    UI.zoneRows = {}
    UI.zoneText = zoneText
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

    -- Sorted zone list for stable display
    local zones = {}
    for z, on in pairs(cfg().monitored_zones) do
        if on then zones[#zones + 1] = z end
    end
    table.sort(zones)

    local y = -2
    for _, zone in ipairs(zones) do
        local row = CreateFrame("Frame", nil, UI.zoneListContent)
        row:SetSize(360, 20)
        row:SetPoint("TOPLEFT", UI.zoneListContent, "TOPLEFT", 4, y)

        local txt = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        txt:SetPoint("LEFT", row, "LEFT", 4, 0)
        txt:SetText(zone)
        txt:SetJustifyH("LEFT")
        txt:SetWidth(300)

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

    -- Resize scroll child so the scrollbar tracks correctly
    local h = math.max(130, math.abs(y) + 4)
    UI.zoneListContent:SetHeight(h)
end

-- Update the visible "current zone" string when the panel opens.
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
        f:Show()
    end
end
