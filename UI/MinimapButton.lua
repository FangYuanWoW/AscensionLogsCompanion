-- UI/MinimapButton.lua
-- Draggable minimap button. Left-click toggles the settings frame, right-click
-- shows a quick-action menu, drag (with cursor) repositions around the minimap
-- edge. Position persists in ALC_Config.minimap_button.angle.
--
-- Self-contained — no LibDBIcon dependency. Same pattern most legacy 3.3.5
-- addons use: a Frame with circular textures anchored to Minimap, position
-- computed from a polar angle.

local ALC = _G.ALC
local M = {}
ALC.UI.MinimapButton = M

local function cfg()
    _G.ALC_Config = _G.ALC_Config or {}
    ALC_Config.minimap_button = ALC_Config.minimap_button or { angle = 200, hidden = false }
    return ALC_Config.minimap_button
end

-- Compute (x, y) on the minimap edge for a given polar angle in degrees.
-- 0° = east, 90° = north, etc. Radius ≈ 80 (Minimap default size in 3.3.5).
local function positionFor(angle)
    local rad = math.rad(angle)
    local r = 80
    return r * math.cos(rad), r * math.sin(rad)
end

-- While dragging, snap the button to the angle pointing from the minimap
-- center toward the cursor.
local function onUpdateDrag(self)
    local mx, my = Minimap:GetCenter()
    local px, py = GetCursorPosition()
    local scale = Minimap:GetEffectiveScale()
    px, py = px / scale, py / scale
    local dx, dy = px - mx, py - my
    local angle = math.deg(math.atan2(dy, dx))
    cfg().angle = angle
    local x, y = positionFor(angle)
    self:ClearAllPoints()
    self:SetPoint("CENTER", Minimap, "CENTER", x, y)
end

local function buildTooltip(self)
    local metrics = ALC.Core.Metrics and ALC.Core.Metrics.counters or {}
    local cache = _G.ALC_InspectCache or {}
    local nCache = 0
    for _ in pairs(cache) do nCache = nCache + 1 end
    GameTooltip:SetOwner(self, "ANCHOR_LEFT")
    GameTooltip:AddLine("|cff00ff00Ascension Logs Companion|r")
    GameTooltip:AddLine("v" .. ALC.Core.Constants.VERSION, 0.7, 0.7, 0.7)
    GameTooltip:AddLine(" ")
    GameTooltip:AddDoubleLine("Players inspected", tostring(metrics.inspect_success or 0), 1, 1, 1, 0.4, 1, 0.4)
    GameTooltip:AddDoubleLine("Players cached",    tostring(nCache),                       1, 1, 1, 1, 1, 1)
    GameTooltip:AddDoubleLine("Combatant info delivered", tostring(metrics.chunks_flushed or 0), 1, 1, 1, 0.4, 1, 0.4)
    if (metrics.chunks_queued or 0) > 0 then
        GameTooltip:AddDoubleLine("Pending delivery", tostring(metrics.chunks_queued or 0), 1, 1, 1, 1, 1, 0.4)
    end
    GameTooltip:AddLine(" ")
    GameTooltip:AddLine("|cffaaaaaaClick:|r open settings")
    GameTooltip:AddLine("|cffaaaaaaShift+drag:|r reposition")
    GameTooltip:Show()
end

function M.create()
    if M.frame then return M.frame end

    local btn = CreateFrame("Button", "ALC_MinimapButton", Minimap)
    btn:SetFrameStrata("MEDIUM")
    btn:SetFrameLevel(8)
    btn:SetSize(31, 31)
    btn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    btn:RegisterForDrag("LeftButton")
    btn:SetMovable(true)
    btn:SetClampedToScreen(true)

    -- Icon — ascensionlogs.gg blue flame favicon, converted PNG → 32x32 TGA
    -- so the addon's brand mark surfaces directly on the minimap.
    local icon = btn:CreateTexture(nil, "BACKGROUND")
    icon:SetTexture("Interface\\AddOns\\AscensionLogsCompanion\\Media\\flame-32.tga")
    icon:SetSize(22, 22)
    icon:SetPoint("CENTER", btn, "CENTER", 0, 0)

    -- Round border ring (Blizzard's tracking icon ring). The texture has
    -- internal padding so its visible-ring center sits ~11px down-right of
    -- the texture's TOPLEFT — anchor by CENTER with the canonical offset
    -- so the ring lines up with the icon's center.
    local border = btn:CreateTexture(nil, "OVERLAY")
    border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
    border:SetSize(54, 54)
    border:SetPoint("CENTER", btn, "CENTER", 11, -12)

    -- Position from saved angle
    local x, y = positionFor(cfg().angle or 200)
    btn:SetPoint("CENTER", Minimap, "CENTER", x, y)

    btn:SetScript("OnEnter", function(self)
        buildTooltip(self)
    end)
    btn:SetScript("OnLeave", function() GameTooltip:Hide() end)

    btn:SetScript("OnDragStart", function(self)
        if IsShiftKeyDown() then
            self:SetScript("OnUpdate", onUpdateDrag)
        end
    end)
    btn:SetScript("OnDragStop", function(self)
        self:SetScript("OnUpdate", nil)
    end)

    btn:SetScript("OnClick", function(self, button)
        -- Both buttons toggle the settings panel. Right-click previously
        -- opened a UIDropDownMenu but the Blizzard 3.3.5 dropdown API was
        -- unreliable from a non-secure execution path; the panel covers
        -- everything the menu offered (zone management, status, hide).
        if ALC.UI.SettingsFrame then ALC.UI.SettingsFrame.toggle() end
    end)

    M.frame = btn
    if cfg().hidden then btn:Hide() end
    return btn
end

function M.hide()
    if M.frame then M.frame:Hide() end
    cfg().hidden = true
    ALC.Core.Logger.info("Minimap button hidden. /alc minimap show to restore.")
end

function M.show()
    if not M.frame then M.create() end
    M.frame:Show()
    cfg().hidden = false
end

function M.start()
    M.create()
end
