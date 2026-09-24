-- Tab correction learning. Rime owns the LevelDb lock and durable records;
-- decoding uses only immutable in-memory indexes. No Windows receipt is implied.
local M = {}
local memo = require("tiger_sentence_cache")
local MATERIALIZED_CODE_LIMIT = 256
local function chars(text)
    local result = {}
    for c in text:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
        local a, b = c:byte(1, 2)
        local length = a < 128 and 1 or a < 224 and 2 or a < 240 and 3 or 4
        if #c ~= length or (a == 224 and b < 160) or (a == 237 and b >= 160) or
            (a == 240 and b < 144) or (a == 244 and b >= 144) then return {} end
        result[#result + 1] = c
    end
    if table.concat(result) ~= text then return {} end
    return result
end
local function static(text)
    local n = #chars(text)
    return n > 0 and n <= 16 and not text:find("[%z\1-\31\127{}]") and
        not text:find("\238[\128-\191][\128-\191]") and not text:find("\239[\128-\163][\128-\191]")
end
local function context(text)
    local c = chars(text)
    return table.concat(c, "", math.max(1, #c - 1))
end
local function key(...)
    local values = {...}
    for i, value in ipairs(values) do values[i] = #value .. ":" .. value end
    return table.concat(values)
end
local function frame(values) return key((table.unpack or unpack)(values)) end
local function unframe(value)
    local result, pos = {}, 1
    while pos <= #value do
        local a, b, n = value:find("^(%d+):", pos)
        if not a then return nil end
        n = tonumber(n)
        if not n or n > 8192 or b + n > #value then return nil end
        result[#result + 1] = value:sub(b + 1, b + n)
        pos = b + n + 1
    end
    return result
end
function M.hash(text)
    local a, b = 2166136261, 5381
    -- Read four bytes per C call, retaining the exact historical arithmetic
    -- (including LuaJIT's double representation) and database namespace.
    local byte = string.byte
    for i = 1, #text, 4 do
        local x, y, z, w = byte(text, i, i + 3)
        a, b = (a * 65599 + x) % 4294967296, (b * 33 + x) % 4294967296
        if y then a, b = (a * 65599 + y) % 4294967296, (b * 33 + y) % 4294967296 end
        if z then a, b = (a * 65599 + z) % 4294967296, (b * 33 + z) % 4294967296 end
        if w then a, b = (a * 65599 + w) % 4294967296, (b * 33 + w) % 4294967296 end
    end
    return string.format("%08x%08x", a, b)
end
local MAX_LEVEL = 10
local function correction_level(weight)
    return math.max(0, math.min(MAX_LEVEL, math.floor((weight or 0) + 1e-12)))
end
local function general_score(weight)
    local level = correction_level(weight)
    return level > 0 and (4 + 2 * level) or 0 -- L1=6 ... L10=24.
end
local function exact_score(weight)
    local level = correction_level(weight)
    return level > 0 and (7 + 2 * level) or 0 -- Same-context L1=9 ... L10=27.
end

function M.build(events, now)
    -- Timestamps remain persisted metadata only. Learning never decays by time.
    local groups = {}
    for _, e in ipairs(events) do
        if e.mode and #e.mode > 0 and #e.mode <= 512 and e.code and #e.code > 0 and #e.code <= 128 and
            e.text and static(e.text) and e.context and (e.context == "" or #chars(e.context) > 0) and #chars(e.context) <= 2 and
            type(e.time) == "number" and e.time >= 0 then
            local k = key(e.code, e.mode, e.context)
            local group = groups[k] or {code=e.code, mode=e.mode, context=e.context, choices={}}
            groups[k] = group
            for text, c in pairs(group.choices) do
                if text ~= e.text then c.weight = c.weight * 0.25 end
            end
            local c = group.choices[e.text] or {weight=0}
            c.weight = math.min(MAX_LEVEL, c.weight + 1)
            group.choices[e.text] = c
        end
    end
    local summaries = {}
    for _, g in pairs(groups) do
        for text, c in pairs(g.choices) do
            local k = key(g.code, g.mode, text)
            local x = summaries[k] or {code=g.code, mode=g.mode, text=text, exact={}, weight=0}
            summaries[k] = x
            x.exact[g.context] = exact_score(c.weight)
            x.weight = x.weight + c.weight
        end
    end
    local index = {codes={}, exact={}, prefixes={}}
    local seen = {}
    for k, x in pairs(summaries) do
        x.general = general_score(x.weight)
        index.exact[k] = x
        if not seen[x.code] then seen[x.code] = true; index.codes[#index.codes + 1] = x.code end
        local prefix, letters = "", chars(x.text)
        for i = 1, #letters - 1 do
            prefix = prefix .. letters[i]
            local pk = key(x.code, x.mode, prefix)
            local q = index.prefixes[pk] or {general=0, exact={}}
            index.prefixes[pk] = q
            q.general = math.max(q.general, x.general)
            for ctx, value in pairs(x.exact) do q.exact[ctx] = math.max(q.exact[ctx] or 0, value) end
        end
    end
    table.sort(index.codes)
    return index
end
local function score(s, ctx) return s and math.max(s.general, s.exact[ctx] or 0) or 0 end

-- Runtime snapshots keep event aggregates rather than replaying the journal on
-- every correction/minute tick. Only the changed code partition is copied;
-- score materialization is lazy and belongs to one immutable scoring epoch.
-- M.build above deliberately remains the independent full-replay oracle.
local function copy(source)
    local result = {}
    for k, v in pairs(source) do result[k] = v end
    return result
end
local function valid_event(e)
    return type(e.mode) == "string" and #e.mode > 0 and #e.mode <= 512 and
        type(e.code) == "string" and #e.code > 0 and #e.code <= 128 and
        type(e.text) == "string" and static(e.text) and type(e.context) == "string" and
        (e.context == "" or #chars(e.context) > 0) and #chars(e.context) <= 2 and
        type(e.time) == "number" and e.time >= 0
end
local function append_group(partition, e, now)
    local k = key(e.mode, e.context)
    local old = partition[k]
    local g = {mode=e.mode, context=e.context, choices={}}
    partition[k] = g
    for text, c in pairs(old and old.choices or {}) do
        g.choices[text] = {weight=c.weight * (text ~= e.text and 0.25 or 1)}
    end
    local c = g.choices[e.text] or {weight=0}
    c.weight = math.min(MAX_LEVEL, c.weight + 1)
    g.choices[e.text] = c
end
function M.runtime_index(events, now)
    local index = {codes={}, partitions={}, cache={}, now=now or os.time(), future=0}
    for _, e in ipairs(events) do
        if valid_event(e) then
            local p = index.partitions[e.code]
            if not p then p = {}; index.partitions[e.code] = p; index.codes[#index.codes + 1] = e.code end
            append_group(p, e, index.now)
            index.future = math.max(index.future, e.time)
        end
    end
    table.sort(index.codes)
    return index
end
local function materialize(index, code)
    if not index.partitions then return index end
    local result = index.cache[code]
    if result then return result end
    local partition = index.partitions[code]
    if not partition then return nil end -- don't cache arbitrary input misses
    result = {exact={}, prefixes={}}
    for _, g in pairs(partition) do
        for text, c in pairs(g.choices) do
            local k = key(code, g.mode, text)
            local s = result.exact[k] or {mode=g.mode, text=text, exact={}, weight=0}
            result.exact[k] = s
            s.exact[g.context] = exact_score(c.weight)
            s.weight = s.weight + c.weight
        end
    end
    for _, s in pairs(result.exact) do
        local letters = chars(s.text)
        s.general = general_score(s.weight)
        local prefix = ""
        for i = 1, #letters - 1 do
            prefix = prefix .. letters[i]
            local k = key(code, s.mode, prefix)
            local p = result.prefixes[k] or {general=0, exact={}}
            result.prefixes[k] = p
            p.general = math.max(p.general, s.general)
            for ctx, value in pairs(s.exact) do p.exact[ctx] = math.max(p.exact[ctx] or 0, value) end
        end
    end
    -- Only derived scores are evicted; events and immutable aggregates remain.
    -- Otherwise querying many distinct 16-character corrections materializes
    -- every prefix table for the entire journal until the next score epoch.
    if not index._materialized then
        index._materialized = memo.new(MATERIALIZED_CODE_LIMIT)
        index._materialized.values = index.cache
    end
    memo.put(index._materialized, code, result)
    return result
end
local function update_index(index, accepted, events, now)
    if not index.partitions then return M.runtime_index(events, now) end
    local next_index = {codes=index.codes, partitions=copy(index.partitions), cache={}, now=now, future=index.future}
    local changed, new_codes = {}, {}
    for _, e in ipairs(accepted) do
        if valid_event(e) then
            if not changed[e.code] then
                local old = next_index.partitions[e.code]
                next_index.partitions[e.code] = old and copy(old) or {}
                changed[e.code] = true
                if not old then new_codes[#new_codes + 1] = e.code end
            end
            append_group(next_index.partitions[e.code], e, now)
        end
    end
    if #new_codes > 0 then
        next_index.codes = copy(index.codes)
        for _, code in ipairs(new_codes) do
            local lo, hi = 1, #next_index.codes + 1
            while lo < hi do
                local mid = math.floor((lo + hi) / 2)
                if next_index.codes[mid] < code then lo = mid + 1 else hi = mid end
            end
            table.insert(next_index.codes, lo, code)
        end
    end
    return next_index
end
function M.score(index, mode, code, text, ctx)
    local values = materialize(index, code)
    return values and score(values.exact[key(code, mode, text)], ctx) or 0
end
-- Code vectors and scoring snapshots are immutable after publication. Weak
-- owners release unused epochs, while each surviving owner's caches are bounded.
local code_windows = setmetatable({}, {__mode="k"})
local prefix_queries = setmetatable({}, {__mode="k"})
function M.trim_caches(index)
    if not index then return end
    if index.partitions then index.cache, index._materialized = {}, nil end
    prefix_queries[index], code_windows[index.codes] = nil, nil
end
local function code_window(codes, code)
    local cache = code_windows[codes]
    if not cache then cache = memo.new(2048); code_windows[codes] = cache end
    local window = cache.values[code]
    if window then return window[1], window[2] end
    local lo, hi = 1, #codes + 1
    while lo < hi do
        local mid = math.floor((lo + hi) / 2)
        if codes[mid] < code then lo = mid + 1 else hi = mid end
    end
    local last = lo - 1
    -- Preserve the old 64-slot window exactly: an equal code consumes a slot
    -- even though it is not itself a longer-code prefix match.
    for i = lo, math.min(#codes, lo + 63) do
        if codes[i]:sub(1, #code) ~= code then break end
        last = i
    end
    memo.put(cache, code, {lo, last})
    return lo, last
end
function M.prefix_score(index, mode, code, text, ctx)
    if code == "" or text == "" then return 0 end
    local codes = index.codes
    local first, last = code_window(codes, code)
    if first > last then return 0 end
    local cache = prefix_queries[index]
    if not cache then cache = memo.new(4096); prefix_queries[index] = cache end
    local query = key(mode, code, text, ctx)
    local cached = cache.values[query]
    if cached ~= nil then return cached end
    local best = 0
    for i = first, last do
        local value = codes[i]
        if #value > #code then
            local values = materialize(index, value)
            best = math.max(best, score(values.prefixes[key(value, mode, text)], ctx))
        end
    end
    return memo.put(cache, query, best)
end

-- Same UTF-8 acceptance as chars(), including a zero result for malformed input,
-- but count without allocating an array or concatenating all characters again.
local function character_count(text)
    local count, position = 0, 1
    while position <= #text do
        local a, b, c, d = text:byte(position, position + 3)
        local length
        if a < 128 then length = 1
        elseif a >= 194 and a <= 223 and b and b >= 128 and b <= 191 then length = 2
        elseif a >= 224 and a <= 239 and b and b >= 128 and b <= 191 and
            c and c >= 128 and c <= 191 and (a ~= 224 or b >= 160) and
            (a ~= 237 or b < 160) then length = 3
        elseif a >= 240 and a <= 244 and b and b >= 128 and b <= 191 and
            c and c >= 128 and c <= 191 and d and d >= 128 and d <= 191 and
            (a ~= 240 or b >= 144) and (a ~= 244 or b < 144) then length = 4
        else return 0 end
        position, count = position + length, count + 1
    end
    return count
end
local function path_context(start, text, length)
    local prefix = text:sub(1, length)
    if not start or start.text ~= prefix or start.text_length ~= length then
        return context(prefix) -- compatibility calls without full path metadata
    end
    if start._learning_context_source ~= prefix then
        -- Use the original validator, not BOS sentinels or unchecked prev1/prev2.
        -- This preserves malformed UTF-8 and actual control-character behavior.
        start._learning_context = context(prefix)
        start._learning_context_source = prefix
    end
    return start._learning_context
end
function M.early_commit_maturity(score)
    if not score then return 0 end
    return math.max(0, math.min(1, (score - 9) / 4))
end

function M.early_commit_contribution(score)
    return math.min(0.75, math.max(0, score or 0) * M.early_commit_maturity(score) * 0.075)
end

function M.fusion_mode(mode)
    return mode == "" and "" or ("fusion-v1|" .. mode)
end

function M.fusion_pair_code(raw, direct, composed)
    return "~f" .. M.hash((raw or "") .. "\0D\0" .. (direct or "") .. "\0C\0" .. (composed or ""))
end

function M.fusion_score(index, mode, raw, direct, composed)
    if not index or mode == "" then return 0 end
    local fusion = M.fusion_mode(mode)
    local code = M.fusion_pair_code(raw, direct, composed)
    return M.score(index, fusion, code, "D", "") - M.score(index, fusion, code, "C", "")
end

function M.fusion_event(mode, raw, direct, composed, direct_wins, raw_end)
    if mode == "" then return nil end
    return {
        time=os.time(), mode=M.fusion_mode(mode),
        code=M.fusion_pair_code(raw, direct, composed),
        text=direct_wins and "D" or "C", context="",
        raw_start=0, raw_end=math.max(0, raw_end or #raw),
        text_start=0, text_end=1
    }
end

function M.reward(index, mode, raw, text, finish, previous)
    local best, potential, start = previous.learning_score or 0, 0, previous
    local early_bonus = previous.learning_early_commit_bonus or 0
    if not index or #index.codes == 0 or mode == "" then return best, potential, early_bonus end
    while true do
        local t, r = start and start.text_length or 0, start and start.raw_length or 0
        local fragment = text:sub(t + 1)
        if character_count(fragment) > 16 then break end
        local code, ctx = raw:sub(r + 1, finish), path_context(start, text, t)
        local reward = M.score(index, mode, code, fragment, ctx)
        local candidate = (start and start.learning_score or 0) + reward
        local candidate_bonus = math.max(previous.learning_early_commit_bonus or 0,
            M.early_commit_contribution(reward))
        if candidate > best or (candidate == best and candidate_bonus > early_bonus) then
            best = candidate
        end
        early_bonus = math.max(early_bonus, candidate_bonus)
        potential = math.max(potential, M.prefix_score(index, mode, code, fragment, ctx))
        if not start or r == 0 then break end
        start = start.previous
    end
    return best, potential, early_bonus
end

function M.diff(raw, before, selected, floor, mode)
    local function boundaries(item)
        local map, ends, node = {[0]=0}, {}, item.path
        while node and (node.raw_length or 0) > 0 do
            map[node.raw_length] = node.text_length
            ends[#ends + 1] = node.raw_length
            node = node.previous
        end
        table.sort(ends)
        local r, t = 0, 0
        for _, last in ipairs(ends) do
            if last <= r or map[last] <= t or map[last] > #item.text then return nil end
            r, t = last, map[last]
        end
        if r ~= #raw or t ~= #item.text then return nil end
        return map, ends
    end
    if not before or not selected or before.text == selected.text then return {} end
    local a, ends = boundaries(before)
    local b = boundaries(selected)
    if not a or not b then return {} end
    local result, first = {}, 0
    for _, last in ipairs(ends) do
        if b[last] then
            local text = selected.text:sub(b[first] + 1, b[last])
            if first >= floor and text ~= before.text:sub(a[first] + 1, a[last]) and static(text) then
                result[#result + 1] = {time=os.time(), mode=mode, code=raw:sub(first + 1, last):lower(), text=text,
                    context=context(selected.text:sub(1, b[first])), raw_start=first, raw_end=last,
                    text_start=b[first], text_end=b[last]}
            end
            first = last
        end
    end
    return result
end

local stores = {}
function M.open(name)
    if stores[name] then return stores[name] end
    local store = {events={}, index=M.runtime_index({}), count=0, sequence=0, bytes=0, scored_at=os.time(), error=nil}
    stores[name] = store
    if type(LevelDb) ~= "function" then store.error = "LevelDb unavailable"; return store end
    local ok, err = pcall(function()
        local db = LevelDb(name)
        if not db or not db:open() then error("learning database is locked or unavailable") end
        store.db = db
        for k, v in db:query("e/"):iter() do
            if k:sub(1, 2) ~= "e/" then break end
            store.count, store.bytes = store.count + 1, store.bytes + #k + #v
            store.sequence = math.max(store.sequence, tonumber(k:sub(3)) or 0)
            if store.count > 10000 or store.bytes > 16 * 1024 * 1024 then error("learning database limit reached") end
            local f = unframe(v)
            if f and #f == 5 then
                store.events[#store.events + 1] = {time=tonumber(f[1]), mode=f[2], code=f[3], text=f[4], context=f[5]}
            end
        end
        store.index = M.runtime_index(store.events)
    end)
    if not ok then
        if store.db then pcall(function() store.db:close() end) end
        store.db, store.error = nil, tostring(err)
    end
    return store
end
function M.confirm(store, events)
    if not store or not store.db or #events == 0 then return false end
    local changed = false
    local accepted_events = {}
    for _, e in ipairs(events) do
        if store.count >= 10000 then break end
        local k = string.format("e/%010d", store.sequence + 1)
        local value = frame({tostring(e.time), e.mode, e.code, e.text, e.context})
        if store.bytes + #k + #value > 16 * 1024 * 1024 then break end
        local ok, accepted = pcall(function() return store.db:update(k, value) end)
        if not ok or not accepted then store.error = "learning database write failed"; break end
        store.count, store.bytes = store.count + 1, store.bytes + #k + #value
        store.sequence = store.sequence + 1
        store.events[#store.events + 1] = e
        accepted_events[#accepted_events + 1] = e
        changed = true
    end
    if changed then
        store.scored_at = os.time()
        store.index = update_index(store.index, accepted_events, store.events, store.scored_at)
    end
    return changed
end
function M.refresh_scores(store)
    -- No time decay: a quiet clock can never alter published learning scores.
    return store and store.index or nil
end
M.context = context
return M
