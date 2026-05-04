-- Capture/GearScan.lua
-- Reads equipped gear for a unit. Works for "player" and inspected units.
-- Post-inspect 200ms gear populate delay is handled by the caller (InspectLoop).
--
-- Overlay capture: both Ascension and Epoch expose transmog through a per-slot
-- divergence between GetInventoryItemLink and GetInventoryItemID. Orientation
-- is consistent across both servers: link = REAL underlying (drives stats,
-- ilvl, armory), id = VISIBLE overlay (or a sentinel marking "hide slot").
--
--   Ascension (verified 2026-04-26 on Barry):
--     link = 216939 "Dragonstalker's Helm"     real item Barry wears
--     id   = 941102 "Jewel of the Firelord"    vanity overlay drawn on him
--
--   Epoch (verified 2026-05-03 on Matchusmashu via /eprobe inspect-gear-deep):
--     Mode A (transmog'd to a different visible item — slot 3 shoulders):
--       link = 90939 "Rival's Plated Spaulders"   real item
--       id   = 62435 "Tralak's Shoulderguard"     visual overlay
--     Mode B (transmog'd to "hide / naked" — slot 5 chest, slot 9 wrists):
--       link = 90940 "Rival's Plated Breast"      real item
--       id   = 1                                  sentinel: hide / show as empty
--
-- We always treat the link side as canonical (entry.item_id) so the armory
-- gets the real underlying gear regardless of what visual the player chose.
-- The id side becomes vanity_item_id when it diverges from the link, except
-- for Epoch's Mode B sentinel (id == 1) which is filtered out — there's no
-- real item there, just a "show as hidden" instruction.
--
-- The 2026-04-28 probe finding ("zero divergence on Epoch") was wrong — that
-- probe ran on un-transmog'd peers. Confirmed via Matchusmashu where 3/19
-- slots diverge.

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
                local entry = {
                    slot = slot,
                    item_id = parsed.item_id,
                    enchant = parsed.enchant,
                    gems = { parsed.gem_1, parsed.gem_2, parsed.gem_3, parsed.gem_4 },
                    suffix = parsed.suffix,
                    unique = parsed.unique,
                    raw = parsed.raw,
                }
                -- Vanity overlay divergence: when GetInventoryItemID differs
                -- from the link's item_id, the player has a transmog applied.
                -- Record the appearance ID so the report can show both sides.
                -- Most slots won't diverge. Runs on both servers (orientation
                -- is consistent: link = real, id = visible overlay).
                --
                -- Epoch sentinel filter (id == 1): Epoch's transmog lets a
                -- player set a slot to "hide / naked", in which case
                -- GetInventoryItemID returns the literal value 1. That's a
                -- "show as empty" instruction, not a real item id, so don't
                -- store it as vanity_item_id. The link side still carries
                -- the real underlying item, captured above as item_id.
                if GetInventoryItemID then
                    local appearanceId = GetInventoryItemID(unit, slot)
                    if appearanceId and appearanceId > 1
                       and appearanceId ~= parsed.item_id then
                        entry.vanity_item_id = appearanceId
                    end
                end

                -- Ascension-only: vanity-detection flag via C_VanityCollection.
                -- Independent of divergence — catches the "fully-poisoned"
                -- peer state where both link and GetInventoryItemID return
                -- the same vanity id, so divergence is invisible. The
                -- C_VanityCollection namespace doesn't exist on Epoch
                -- (probe-confirmed), so the entire block is BB-only.
                if (ALC.Profile == nil or ALC.Profile == "ascension")
                   and _G.C_VanityCollection
                   and type(C_VanityCollection.GetItem) == "function"
                   and parsed.item_id and parsed.item_id > 0 then
                    local ok, rec = pcall(C_VanityCollection.GetItem, parsed.item_id)
                    if ok and rec then
                        entry.is_vanity = true
                    end
                end
                gear[#gear + 1] = entry
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
