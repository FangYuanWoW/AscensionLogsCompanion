-- Core/Queue.lua
-- Simple ring buffer + priority queue. Used by the hijack rotation and the
-- inspect scheduler. Constant-time push/pop/advance only.

local ALC = _G.ALC
local Q = {}
ALC.Core.Queue = Q

--------------------------------------------------------------------------------
-- Ring buffer (hijack chunk rotation)
--------------------------------------------------------------------------------
function Q.newRing(capacity)
    return {
        capacity = capacity,
        items = {},
        head = 1,
        tail = 1,
        size = 0,
    }
end

function Q.ringPush(r, item)
    if r.size < r.capacity then
        r.items[r.tail] = item
        r.tail = (r.tail % r.capacity) + 1
        r.size = r.size + 1
    else
        -- Overflow: drop oldest
        r.items[r.tail] = item
        r.tail = (r.tail % r.capacity) + 1
        r.head = (r.head % r.capacity) + 1
    end
end

function Q.ringAdvance(r)
    if r.size == 0 then return nil end
    local item = r.items[r.head]
    r.head = (r.head % r.capacity) + 1
    r.size = r.size - 1
    return item
end

function Q.ringPeek(r, offset)
    offset = offset or 0
    if r.size <= offset then return nil end
    local idx = ((r.head - 1 + offset) % r.capacity) + 1
    return r.items[idx]
end

function Q.ringClear(r)
    r.items = {}
    r.head, r.tail, r.size = 1, 1, 0
end

--------------------------------------------------------------------------------
-- Priority queue (inspect scheduler)
-- Not a proper heap; small roster (<= 40) means linear scan is fast enough.
--------------------------------------------------------------------------------
function Q.newPQ()
    return { items = {} }  -- { {key=..., value=...}, ... }
end

function Q.pqPush(pq, key, value)
    table.insert(pq.items, { key = key, value = value })
end

function Q.pqPopMin(pq)
    if #pq.items == 0 then return nil end
    local bestIdx, bestKey = 1, pq.items[1].key
    for i = 2, #pq.items do
        if pq.items[i].key < bestKey then
            bestIdx, bestKey = i, pq.items[i].key
        end
    end
    local entry = table.remove(pq.items, bestIdx)
    return entry.value, entry.key
end

function Q.pqPeekMin(pq)
    if #pq.items == 0 then return nil end
    local bestIdx, bestKey = 1, pq.items[1].key
    for i = 2, #pq.items do
        if pq.items[i].key < bestKey then
            bestIdx, bestKey = i, pq.items[i].key
        end
    end
    return pq.items[bestIdx].value, bestKey
end

function Q.pqRemove(pq, pred)
    for i = #pq.items, 1, -1 do
        if pred(pq.items[i].value) then
            table.remove(pq.items, i)
        end
    end
end

function Q.pqSize(pq)
    return #pq.items
end
