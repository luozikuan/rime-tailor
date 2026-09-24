-- Bounded FIFO memoization. Cached false/zero are values, never misses.
-- Callers own cache lifetime; scoring caches must belong to a model/score epoch.
local M = {}
function M.new(limit)
    assert(type(limit) == "number" and limit >= 1 and limit % 1 == 0, "invalid cache limit")
    return {values={}, keys={}, next=1, limit=limit}
end
function M.put(cache, key, value)
    if cache.values[key] ~= nil then
        cache.values[key] = value
        return value
    end
    local old = cache.keys[cache.next]
    if old ~= nil then cache.values[old] = nil end
    cache.values[key] = value
    cache.keys[cache.next] = key
    cache.next = cache.next % cache.limit + 1
    return value
end
-- Fixed-width records stored by column: no separate Lua table per entry.
-- values maps a key to its FIFO slot; false/zero columns remain real values.
function M.new_columns(limit, width)
    local cache = M.new(limit)
    cache.columns = {}
    for i = 1, width do cache.columns[i] = {} end
    return cache
end
function M.put_columns(cache, key, ...)
    local slot = cache.values[key]
    if not slot then
        slot = cache.next
        local old = cache.keys[slot]
        if old ~= nil then cache.values[old] = nil end
        cache.keys[slot], cache.values[key] = key, slot
        cache.next = slot % cache.limit + 1
    end
    for i = 1, #cache.columns do cache.columns[i][slot] = select(i, ...) end
    return slot
end
return M
