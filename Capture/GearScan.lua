-- Capture/GearScan.lua
-- Reads equipped gear for a unit. Works for "player" and inspected units.
-- Post-inspect 200ms gear populate delay is handled by the caller (InspectLoop).

local ALC = _G.ALC
local G = {}
ALC.Capture.GearScan = G

-- Slot 1..19 covers head, neck, shoulder, shirt, chest, waist, legs, feet,
-- wrist, hands, finger1, finger2, trinket1, trinket2, back, mainhand,
-- offhand, ranged, tabard. 3.3.5 slot IDs.
G.SLOTS = {
    1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19
}

-- Parse a WoW itemstring of form "item:id:enchant:g1:g2:g3:g4:suffix:unique:..."
-- Returns a table with named fields for the parts we care about.
function G.parseItemString(link)
    if type(link) ~= "string" then return nil end
    local _, _, itemStr = link:find("|Hitem:([%-%d:]+)|h")
    if not itemStr then
        -- Already a bare itemstring
        if link:sub(1, 5) ~= "item:" then return nil end
        itemStr = link:sub(6)
    end

    local parts = {}
    for part in itemStr:gmatch("([%-%d]*):?") do
        parts[#parts + 1] = tonumber(part) or 0
    end

    return {
        raw       = itemStr,
        item_id   = parts[1] or 0,
        enchant   = parts[2] or 0,
        gem_1     = parts[3] or 0,
        gem_2     = parts[4] or 0,
        gem_3     = parts[5] or 0,
        gem_4     = parts[6] or 0,
        suffix    = parts[7] or 0,
        unique    = parts[8] or 0,
    }
end

function G.readGear(unit)
    local gear = {}
    for _, slot in ipairs(G.SLOTS) do
        local link = GetInventoryItemLink(unit, slot)
        if link then
            local parsed = G.parseItemString(link)
            if parsed then
                gear[#gear + 1] = {
                    slot = slot,
                    item_id = parsed.item_id,
                    enchant = parsed.enchant,
                    gems = { parsed.gem_1, parsed.gem_2, parsed.gem_3, parsed.gem_4 },
                    suffix = parsed.suffix,
                    unique = parsed.unique,
                    raw = parsed.raw,
                }
            end
        end
    end
    return gear
end

-- Count populated slots. Used by the inspect post-read poll to decide
-- whether to retry after 200ms.
function G.populatedSlotCount(unit)
    local n = 0
    for _, slot in ipairs(G.SLOTS) do
        if GetInventoryItemLink(unit, slot) then n = n + 1 end
    end
    return n
end
