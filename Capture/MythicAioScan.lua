-- Capture/MythicAioScan.lua
-- Mythic+ keystone source for clients whose M+ system has no Lua API.
--
-- WHY THIS EXISTS
--   KeystoneScan.lua reads C_MythicPlus. Triumvirate has a full Mythic+ system
--   (dungeon, key level, run timer, weekly affixes, Enemy Forces, per-boss
--   checklist, deaths, score, leaderboard, weekly vault) but NO such namespace:
--   the client binaries contain no Mythic/Keystone symbols at all. Its entire
--   M+ UI is a server-pushed Eluna AIO addon delivered at login, so the only
--   observable surface is the AIO wire itself.
--
--   This module reads that wire and presents the result in the exact shape
--   KeystoneScan's readActiveKeystone() returns, then drives KeystoneScan's
--   existing lifecycle. Everything downstream - the durable keystone-run
--   records, roster capture, per-member build/gear enrichment, death tracking,
--   the FIFO cap, the Uploader's disk read - is reused untouched.
--
-- THE WIRE
--   Server -> client is CHAT_MSG_ADDON with prefix "SAIO" (client -> server is
--   "CAIO"; we never send). Framing, from AIO's own source: bytes 1-2 are the
--   message id, and the sentinel "\1\1" marks a short single-part message whose
--   body starts at byte 3. Otherwise the header is three 16-bit big-endian
--   fields (message id, part count, part id) and the body starts at byte 7.
--   A body is Smallfolk-serialised (AIO's C/U lualzw flag applies only to addon
--   CODE transfer, never to regular blocks). It decodes to an array of blocks,
--   each {argCount, handleName, methodName, ...args}, dispatched as
--   unpack(block, 3, block[1] + 2). The M+ addon's handle is "AIO_Mythic".
--
-- TWO HARD RULES. Both are load-bearing; breaking either damages the player's
-- own game, not just our capture.
--   1. NEVER call AIO.AddHandlers("AIO_Mythic", ...). AIO.RegisterEvent asserts
--      that a name is not already registered, so a second registration THROWS
--      and takes down the server's real M+ UI. We listen on CHAT_MSG_ADDON
--      alongside AIO instead, which costs AIO nothing and cannot collide.
--      (Wrapping its handler table is not an option either: the M+ addon keeps
--      it in a local, and the one global name it references is never assigned.)
--   2. NEVER send an AIO_Mythic block. Its client -> server ops include
--      PedestalActivate, PedestalForfeit, MythicRewardChoice, SelectVaultItem
--      and SelectVaultSpec, which start a key, forfeit a live run, or spend a
--      weekly vault pick. This module is strictly read-only.
--
-- SCOPE (first pass): durable run records only. Relay chunk publishing stays
-- off for this source - see shouldPublish() in KeystoneScan.lua - because the
-- server-side KS demuxer is not wired for this tenant yet. Runs still reach the
-- site through the Uploader, which does not read this tenant yet either.

local ALC = _G.ALC
local A = {}
ALC.Capture.MythicAioScan = A

local AIO_SERVER_PREFIX = "SAIO"
local MYTHIC_HANDLE     = "AIO_Mythic"
local SHORT_MSG_TAG     = string.char(1) .. string.char(1)

-- A single AIO message is capped well under this; the guard is against a
-- corrupt part count wedging a growing table.
local MAX_PENDING_MSGS  = 32
local MAX_BEST_MAPS     = 64

A.started = false
A.live    = nil    -- readActive() shape while a key is running, else nil

-- Weekly affixes arrive independently of any run (on a UI request), so they are
-- module state rather than run state and are folded into a run when it opens.
A.weeklyAffixes = nil
A.neutralAffix  = nil
A.season        = nil

local pending = {}      -- [msgId] = { n = parts, [partId] = chunk }
local pendingCount = 0

local function nowMs()
    return time() * 1000
end

local function log(msg)
    ALC.Core.Logger.debug("MythicAioScan: " .. msg)
end

------------------------------------------------------------------------------
-- Availability

-- Gate on the PROFILE plus AIO's actual presence, never on the profile alone:
-- the M+ addon is server-pushed, so a client that has not received it yet has
-- no M+ at all and must not look like it does.
function A.isAvailable()
    if not (ALC.Core.Profile and ALC.Core.Profile.isTriumvirate
            and ALC.Core.Profile.isTriumvirate()) then
        return false
    end
    return type(_G.Smallfolk) == "table" and type(_G.Smallfolk.loads) == "function"
end

------------------------------------------------------------------------------
-- Frame decoding

local function to16(s)
    local a, b = s:byte(1, 2)
    return (a or 0) * 256 + (b or 0)
end

local function decodeBody(body)
    local ok, data = pcall(_G.Smallfolk.loads, body, #body)
    if not ok or type(data) ~= "table" then return nil end
    return data
end

-- Returns the decoded block array once a complete message has assembled, or nil
-- while parts are still outstanding.
local function assemble(message)
    if message:sub(1, 2) == SHORT_MSG_TAG then
        return decodeBody(message:sub(3))
    end
    if #message < 6 then return nil end

    local msgId  = to16(message:sub(1, 2))
    local parts  = to16(message:sub(3, 4))
    local partId = to16(message:sub(5, 6))
    if parts <= 0 or partId <= 0 or partId > parts then return nil end

    local store = pending[msgId]
    if not store or store.n ~= parts then
        if not store then
            if pendingCount >= MAX_PENDING_MSGS then
                pending = {}
                pendingCount = 0
            end
            pendingCount = pendingCount + 1
        end
        store = { n = parts }
        pending[msgId] = store
    end
    store[partId] = message:sub(7)

    for i = 1, parts do
        if not store[i] then return nil end
    end

    local chunks = {}
    for i = 1, parts do chunks[i] = store[i] end
    pending[msgId] = nil
    pendingCount = pendingCount - 1
    return decodeBody(table.concat(chunks))
end

------------------------------------------------------------------------------
-- Live keystone state, in readActiveKeystone()'s shape

-- Triumvirate has ONE id space: the M+ addon keys everything off the client
-- map id, and there is no separate LFGDungeons-style dungeon id the way there
-- is on Ascension. dungeon_id and map_id are therefore deliberately the same
-- value here rather than one being left nil.
local function newLive(mapId, level, budget, bossNames, forcesRequired)
    local bosses = {}
    if type(bossNames) == "table" then
        for i = 1, #bossNames do bosses[i] = bossNames[i] end
    end
    return {
        is_active           = true,
        level               = tonumber(level),
        dungeon_id          = tonumber(mapId),
        map_id              = tonumber(mapId),
        time_budget_s       = tonumber(budget),
        time_remaining_s    = tonumber(budget),
        encounters_done     = 0,
        encounters_required = #bosses,
        trash_done          = 0,
        trash_required      = tonumber(forcesRequired) or 0,
        -- Affix NAMES, not ids. This client's wire never carries an affix id,
        -- so there is nothing to resolve to; the backend keys these by name.
        active_affix_ids    = A.weeklyAffixes,
        weekly_affix_pool   = A.weeklyAffixes,
        neutral_affix       = A.neutralAffix,
        season              = A.season,
        boss_names          = bosses,
        killed_bosses       = {},
        deaths_server       = 0,
        penalty_s           = 0,
    }
end

-- Remaining time is derived from the run frame's own clock while it is up, so
-- a resumed or long run does not drift against our start timestamp.
function A.readActive()
    local live = A.live
    if not live then return nil end
    local ui = _G.MythicBossTimerUI
    if type(ui) == "table" and tonumber(ui.duration) then
        local remaining = tonumber(ui.duration) - (tonumber(ui.elapsed) or 0)
        if remaining < 0 then remaining = 0 end
        live.time_remaining_s = remaining
    end
    return live
end

------------------------------------------------------------------------------
-- Mirror the live wire state onto the open run record.
--
-- WHY CONTINUOUSLY AND NOT AT CLOSE: closeRunRecord() only stamps progress and
-- timing when it is handed a live read, and the two paths that close a run as
-- "abandoned" (a new run superseding a stale record, and the final resume poll
-- finding no live key) have none by definition - the key is already gone. Those
-- records landed with no progress, no time taken and no time remaining, so a
-- key someone bailed on was indistinguishable from one whose finish we simply
-- missed. Mirroring as the run moves means the last known state is already ON
-- the record whenever it closes, however it closes.
--
-- closeRunRecord overwrites these only when it has a live read, so a normal
-- completion still wins over the mirror.
local function mirrorProgress()
    local live = A.readActive()
    if not live then return end
    local open = ALC.Capture.KeystoneScan.getOpenRun()
    if not open then return end
    open.progress = {
        enc_done   = live.encounters_done,
        enc_req    = live.encounters_required,
        trash_done = live.trash_done,
        trash_req  = live.trash_required,
    }
    if live.time_remaining_s then
        open.time_remaining_s = live.time_remaining_s
        if open.time_budget_s then
            open.time_taken_s = open.time_budget_s - live.time_remaining_s
        end
    end
    -- How stale the numbers above are if the run ends up closing as abandoned.
    open.last_progress_at_ms = nowMs()
end

------------------------------------------------------------------------------
-- Handlers. Names and argument order are as observed on the wire; anything not
-- understood is ignored rather than guessed at.

local H = {}

function H.StartCountdown(sec)
    ALC.Capture.KeystoneScan.externalCountdown(tonumber(sec))
end

function H.StartMythicTimerGUI(mapId, level, budget, bossNames, _unknown, forcesRequired)
    A.live = newLive(mapId, level, budget, bossNames, forcesRequired)
    ALC.Capture.KeystoneScan.externalStarted()
    log(string.format("run started +%s map=%s budget=%ss bosses=%d forces=%s",
        tostring(A.live.level), tostring(A.live.map_id),
        tostring(A.live.time_budget_s), A.live.encounters_required,
        tostring(A.live.trash_required)))
end

function H.UpdateEnemyForces(current, required, _pct, completed)
    local live = A.live
    if not live then return end
    live.trash_done     = tonumber(current) or live.trash_done
    live.trash_required = tonumber(required) or live.trash_required
    live.trash_complete = (completed == true)
    mirrorProgress()
end

-- Index into the run's own boss list, not a creature id.
function H.MarkBossKilled(_mapId, index)
    local live = A.live
    if not live then return end
    index = tonumber(index)
    if not index or live.killed_bosses[index] then return end
    live.killed_bosses[index] = true
    live.encounters_done = (live.encounters_done or 0) + 1
    -- This frame is the ONLY witness to a kill on this client. The combat-log
    -- path in KeystoneScan credits a death only if the name resolves in the
    -- raid BossRegistry, and no 5-man dungeon boss is in it, so without this
    -- call boss_kills stays empty for every key on this tenant. The wire is
    -- also better than a name match: it carries the boss index directly.
    ALC.Capture.KeystoneScan.externalBossKill(
        live.boss_names and live.boss_names[index],
        live.encounters_done,
        index)
    mirrorProgress()
end

-- The server's own death tally. Authoritative, and kept alongside (not instead
-- of) KeystoneScan's CLEU count, which only sees deaths it witnessed.
function H.UpdateMythicScore(_score, deaths)
    local live = A.live
    if not live then return end
    live.deaths_server = tonumber(deaths) or live.deaths_server
    local open = ALC.Capture.KeystoneScan.getOpenRun()
    if open then open.deaths_server = live.deaths_server end
    mirrorProgress()
end

function H.FinalizeMythicScore(_a, deaths)
    H.UpdateMythicScore(nil, deaths)
end

-- Each death burns run time on this server. Recorded so a run's wall clock and
-- its timer can be reconciled after the fact.
function H.ReduceMythicTimer(seconds)
    local live = A.live
    if not live then return end
    seconds = tonumber(seconds) or 0
    if seconds <= 0 then return end
    live.penalty_s = (live.penalty_s or 0) + seconds
end

function H.StartOvertimeMode()
    local live = A.live
    if not live then return end
    live.overtime = true
end

-- Arrives with the seconds REMAINING on the clock, so a positive value is a
-- timed key and zero (or an overtime latch) is a depletion.
function H.StopMythicTimerGUI(remaining)
    local live = A.live
    if not live then return end
    remaining = tonumber(remaining)
    if remaining then
        live.time_remaining_s = remaining
        if live.time_budget_s then
            live.time_taken_s = live.time_budget_s - remaining
        end
    end
    local timed = (not live.overtime) and (remaining == nil or remaining > 0)
    ALC.Capture.KeystoneScan.externalComplete(timed)
    -- Refresh our own bests off the back of the run, so they stay current
    -- without the player ever opening the Score tab.
    A.scheduleBestsRequest()
    log(string.format("run complete timed=%s remaining=%s",
        tostring(timed), tostring(remaining)))
end

-- Sent on reconnect or relog mid-run; the only thing that ever populates the
-- server addon's own saved run state.
function H.RestoreRunState(state)
    if type(state) ~= "table" or not state.active then return end
    A.live = newLive(state.mapId, state.tier, state.duration,
                     state.bossNames, nil)
    local ef = state.enemyForces
    if type(ef) == "table" then
        A.live.trash_done     = tonumber(ef.current) or 0
        A.live.trash_required = tonumber(ef.required) or 0
    end
    A.live.deaths_server = tonumber(state.deaths) or 0
    if type(state.killedBosses) == "table" then
        local n = 0
        for k in pairs(state.killedBosses) do
            A.live.killed_bosses[k] = true
            n = n + 1
        end
        A.live.encounters_done = n
    end
    ALC.Capture.KeystoneScan.externalStarted(true)
    log("run restored from server state")
end

local function clearRun()
    A.live = nil
end
H.ClearRunState      = clearRun
H.ClearSavedRunState = clearRun

function H.ReceiveSeason(season)
    A.season = tonumber(season) or season
end

-- Three negative affixes plus a neutral one. Names only.
function H.ReceiveWeeklyAffixes(a1, a2, a3, _count, neutral)
    local list = {}
    for _, v in ipairs({ a1, a2, a3 }) do
        if type(v) == "string" and v ~= "" and v ~= "-" then
            list[#list + 1] = v
        end
    end
    A.weeklyAffixes = (#list > 0) and list or nil
    if type(neutral) == "string" and neutral ~= "" and neutral ~= "-" then
        A.neutralAffix = neutral
    end
    if A.live then
        A.live.active_affix_ids  = A.weeklyAffixes
        A.live.weekly_affix_pool = A.weeklyAffixes
        A.live.neutral_affix     = A.neutralAffix
    end
end

-- The player's own per-dungeon bests, including the full party of each. This is
-- retroactive server history - the same role the client-side KeystoneBests
-- harvest plays on Ascension - so it lands as "dungeon_best" records.
-- arg 4 is the player's CLASS ID, not a season or a rank: the server addon uses
-- it to index a stock-WotLK class-colour table when it paints the score label
-- (6 = Death Knight, 3 = Hunter, and so on). Recorded so a best carries the
-- class that earned it.
function H.ReceiveTotalPoints(total, scores, playerName, classId, perMap)
    if type(perMap) ~= "table" then return end
    local K = ALC.Capture.KeystoneScan
    local n = 0
    for mapId, info in pairs(perMap) do
        n = n + 1
        if n > MAX_BEST_MAPS then break end
        local level = type(info) == "table" and tonumber(info.highestKey) or nil
        -- highestKey 0 means the dungeon was never completed; not a best.
        if level and level > 0 then
            local players = {}
            if type(info.keyHolderNames) == "table" then
                for i = 1, #info.keyHolderNames do
                    players[i] = { name = info.keyHolderNames[i] }
                end
            end
            local affixes
            if type(info.highestKeyAffixes) == "table" then
                affixes = {}
                for i = 1, #info.highestKeyAffixes do
                    affixes[i] = info.highestKeyAffixes[i]
                end
            end
            K.addExternalBest({
                kind        = "dungeon_best",
                save_key    = playerName,
                class_id    = tonumber(classId),
                dungeon_id  = tonumber(mapId),
                map_id      = tonumber(mapId),
                level       = level,
                score       = type(scores) == "table" and scores[mapId] or nil,
                total_score = tonumber(total),
                season      = A.season,
                affixes     = affixes,
                players     = players,
            })
        end
    end
end

------------------------------------------------------------------------------
-- Wire tap

local function dispatch(blocks)
    for i = 1, #blocks do
        local b = blocks[i]
        if type(b) == "table" and b[2] == MYTHIC_HANDLE then
            local handler = H[b[3]]
            if handler then
                local argc = tonumber(b[1]) or 0
                -- Args run b[4] .. b[argCount + 2]; argCount counts the method
                -- name too. unpack is used rather than #b so an embedded nil
                -- cannot truncate the argument list.
                pcall(handler, unpack(b, 4, argc + 2))
            end
        end
    end
end

function A.onAddonMessage(prefix, message)
    if prefix ~= AIO_SERVER_PREFIX or type(message) ~= "string" then return end
    local blocks = assemble(message)
    if blocks then dispatch(blocks) end
end

------------------------------------------------------------------------------

------------------------------------------------------------------------------
-- Character-level state that belongs to no single run.

-- Park a snapshot under a named key in the durable store. Snapshots overwrite
-- rather than accumulate: these are "what is true now" readings, and a history
-- of them would grow without bound for no benefit.
local function putSnapshot(key, value)
    local K = ALC.Capture.KeystoneScan
    local store = K.getStore and K.getStore()
    if not store then return end
    value.at_ms = nowMs()
    store[key] = value
end

-- Server-wide standings. The ONLY cross-player M+ data this client can see -
-- every Request* op is scoped to the asking character, so an arbitrary player
-- cannot be looked up. Arrives only when the leaderboard tab is opened, so a
-- missing snapshot means "never viewed", not "empty".
function H.ReceiveLeaderboard(top, perMap, neutralAffix)
    local snap = { neutral_affix = neutralAffix, season = A.season, top = {}, per_map = {} }
    if type(top) == "table" then
        for rank, row in pairs(top) do
            if type(row) == "table" then
                snap.top[#snap.top + 1] = {
                    rank   = tonumber(rank),
                    name   = row.name,
                    points = tonumber(row.points),
                }
            end
        end
    end
    if type(perMap) == "table" then
        local n = 0
        for mapId, info in pairs(perMap) do
            n = n + 1
            if n > MAX_BEST_MAPS then break end
            if type(info) == "table" then
                local holders
                if type(info.keyHolderNames) == "table" then
                    holders = {}
                    for i = 1, #info.keyHolderNames do holders[i] = info.keyHolderNames[i] end
                end
                snap.per_map[tostring(mapId)] = {
                    highest_key      = tonumber(info.highestKey),
                    highest_key_time = tonumber(info.highestKeyDuration),
                    holders          = holders,
                    top_name         = info.name,
                    top_score        = tonumber(info.score),
                }
            end
        end
    end
    putSnapshot("leaderboard", snap)
    log("leaderboard snapshot stored")
end

-- End-of-run loot offer. Useful beyond the items: the message carries the
-- server's own "completed in MM:SS", an INDEPENDENT reading of the run time
-- from a different code path than StopMythicTimerGUI's remaining-time
-- arithmetic. It arrives while the run record is still open.
function H.ShowRewardChoice(item1, item2, keyLevel, message, _a, _timeout)
    local open = ALC.Capture.KeystoneScan.getOpenRun()
    if not open then return end
    local reward = {
        item1     = tonumber(item1),
        item2     = tonumber(item2),
        key_level = tonumber(keyLevel),
        message   = type(message) == "string" and message or nil,
    }
    if reward.message then
        local mm, ss = reward.message:match("(%d+):(%d+)")
        if mm and ss then
            reward.completed_in_s = tonumber(mm) * 60 + tonumber(ss)
        end
    end
    open.reward = reward
    log("reward choice recorded: " .. tostring(reward.item1) .. " / "
        .. tostring(reward.item2))
end

-- Weekly vault. Its payload shape has never been observed (it needs a pending
-- vault to fire), so this records the arguments AS GIVEN rather than mapping
-- them onto a schema invented from guesswork. Once a real frame lands, read it
-- back and give the fields proper names.
local function rawArgs(...)
    local out, n = {}, select("#", ...)
    for i = 1, n do
        local v = select(i, ...)
        local t = type(v)
        if t == "table" then
            local inner = {}
            for k, vv in pairs(v) do
                if type(vv) ~= "table" and type(vv) ~= "function" then
                    inner[tostring(k)] = tostring(vv)
                end
            end
            out[i] = inner
        elseif t ~= "function" then
            out[i] = tostring(v)
        end
    end
    out.n = n
    return out
end

function H.ShowVaultGUI(...)
    putSnapshot("vault", { source = "ShowVaultGUI", args = rawArgs(...) })
    log("vault snapshot stored (ShowVaultGUI)")
end

function H.UpdateVaultStatus(...)
    putSnapshot("vault", { source = "UpdateVaultStatus", args = rawArgs(...) })
    log("vault snapshot stored (UpdateVaultStatus)")
end

------------------------------------------------------------------------------
-- Asking the server for our own standings.
--
-- The server's UI fires this with NO arguments when its Score tab is shown, so
-- until now a player's bests were harvested only if they happened to open that
-- tab. Sending it ourselves after a run keeps them current with no UI at all.
--
-- SCOPE, and why this does not reopen the "never send" rule: that rule exists
-- for PedestalActivate, PedestalForfeit, MythicRewardChoice, SelectVaultItem
-- and SelectVaultSpec, which START a key, FORFEIT a live run or SPEND a vault
-- pick. This is a zero-argument read of our OWN character - verified 2026-09-05
-- by firing it on two characters in one session and getting each one's own data
-- back. It cannot read another player and it cannot change anything.
local REQUEST_BESTS_DELAY_S = 5
local bestsTimer

function A.requestBests()
    local AIO = _G.AIO
    if type(AIO) ~= "table" or type(AIO.Handle) ~= "function" then return end
    -- Literal op name, never interpolated, so this call site can only ever be
    -- the read it says it is.
    pcall(AIO.Handle, "AIO_Mythic", "RequestTotalPoints")
    log("requested own total points")
end

-- The server writes its own best record in its complete handler and the
-- ordering against ours is undefined, so ask a beat later rather than race it.
function A.scheduleBestsRequest()
    if not A.isAvailable() then return end
    if not bestsTimer then bestsTimer = CreateFrame("Frame") end
    local elapsed = 0
    bestsTimer:SetScript("OnUpdate", function(self, dt)
        elapsed = elapsed + dt
        if elapsed < REQUEST_BESTS_DELAY_S then return end
        self:SetScript("OnUpdate", nil)
        A.requestBests()
    end)
end

function A.start()
    if A.started then return end
    A.started = true

    if not A.isAvailable() then
        log("not a Triumvirate client with AIO present, module inert")
        return
    end

    -- Attach BEFORE KeystoneScan.start() runs (Init boots this module first) so
    -- its availability check sees a working source instead of a missing
    -- C_MythicPlus and going inert.
    ALC.Capture.KeystoneScan.externalSource = A

    ALC.RegisterEvent("CHAT_MSG_ADDON", function(_e, prefix, message)
        A.onAddonMessage(prefix, message)
    end)

    log("armed (AIO wire tap on " .. AIO_SERVER_PREFIX .. ")")
end
