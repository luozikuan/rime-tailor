-- Optional same-row substitution channel with bounded module-local caches.
local M = { enabled = false, penalty = 8, search_penalty = 8, margin = 2, cache = {} }
-- A is the production D89 search policy. B/C and reference remain test-only.
-- Gap limits are per-error search cutoffs, not the user strength penalties.
-- Missing gap fields retain the count-only policy for independent comparisons.
M.profiles = {
    A={seeds=8,one=16,two=8,steps=4096,delta_one=8,delta_two=9},
    B={seeds=4,one=8,two=4,steps=2048},
    C={seeds=2,one=4,two=2,steps=1024},
    reference={seeds=math.huge,one=64,two=64,long=24,steps=math.huge}
}
M.profile = "A"
M.epoch = 0
M.diagnostics_enabled = false
M.stats = {searches=0,cache_hits=0,one_steps=0,two_steps=0,exhaustions=0,expansions=0,seconds=0,prefix_reuses=0}
function M.configure(name)
    assert(M.profiles[name], "unknown correction profile")
    M.profile=name; M.cache={}; M.epoch=M.epoch+1
end
function M.begin(exact)
    local p=M.profiles[M.profile]
    local work={exact=exact,used={0,0},limit=p.steps/2,exhausted=false}
    M.searching=work
    if M.diagnostics_enabled then M.stats.searches=M.stats.searches+1 end
    return work
end
function M.reserve(edits,characters,work)
    work=work or M.searching
    if not work then return true end
    if work.used[edits]+characters>work.limit then
        work.exhausted=true
        if work.position and not work.first_incomplete_position then
            work.first_incomplete_position=work.position
        end
        return false
    end
    work.used[edits]=work.used[edits]+characters
    if M.diagnostics_enabled then
        local name=edits==1 and "one_steps" or "two_steps"
        M.stats[name]=M.stats[name]+characters
        M.stats.expansions=M.stats.expansions+1
    end
    return true
end
function M.result(exact,ranked,limit,incomplete,reorder)
    local result=M.merge(exact,ranked,limit,reorder)
    result.correction_incomplete=incomplete or false
    return result
end
-- Each budget is pruned separately. Its constant search offset never changes
-- with calibration, preserving even floating-point tie-breaking of survivors.
M.option = "tiger_sentence_key_correction"
-- User strength changes final per-error cost only. Beam/search cost stays fixed.
M.level = "off"
M.level_penalties = {weak=8, medium=6, strong=4}
M.level_options = {
    tiger_sentence_correction_off="off",
    tiger_sentence_correction_weak="weak",
    tiger_sentence_correction_medium="medium",
    tiger_sentence_correction_strong="strong"
}
function M.option_for_level(level)
    for option, value in pairs(M.level_options) do if value==level then return option end end
    error("unknown correction level: " .. tostring(level))
end
function M.context_level(context)
    local level, count = nil, 0
    for option, value in pairs(M.level_options) do
        if context:get_option(option) then level=value; count=count+1 end
    end
    if count==1 then return level end
    -- Older schemas/test hosts expose only the legacy Boolean flag.
    return context:get_option(M.option) and "medium" or "off"
end
function M.has_two_han(text)
    local count = 0
    for ch in text:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
        local a,b,c,d = ch:byte(1,4)
        local cp = #ch == 3 and ((a-224)*4096+(b-128)*64+c-128) or
            (#ch == 4 and ((a-240)*262144+(b-128)*4096+(c-128)*64+d-128) or 0)
        if (cp>=0x3400 and cp<=0x4dbf) or (cp>=0x4e00 and cp<=0x9fff) or
            (cp>=0xf900 and cp<=0xfaff) or (cp>=0x20000 and cp<=0x323af) then count=count+1 end
        if count>=2 then return true end
    end
    return false
end
function M.affected(item)
    return item and ((item.correction_count or 0) > 0 or item.correction_history or
        (item.path and item.path.correction_history))
end
M.neighbors = {}
for _, row in ipairs({"qwertyuiop", "asdfghjkl", "zxcvbnm"}) do
    for i = 1, #row do
        local values = {}
        if i > 1 then values[#values + 1] = row:sub(i - 1, i - 1) end
        if i < #row then values[#values + 1] = row:sub(i + 1, i + 1) end
        M.neighbors[row:sub(i, i)] = values
    end
end

local variant_codes, variant_prefixes, variant_values, variant_keys, variant_next
function M.variants(code, lexicon)
    if variant_codes~=lexicon.codes or variant_prefixes~=lexicon.proper_code_prefixes then
        variant_codes,variant_prefixes=lexicon.codes,lexicon.proper_code_prefixes
        variant_values,variant_keys,variant_next={},{},1
    end
    local cached=variant_values[code]
    if cached then return cached end
    if not code:match("^[a-z]+$") then return {} end
    local result = {}
    local function visit(prefix, at, count)
        if at > #code then
            if count > 0 and lexicon.codes[prefix] then
                result[#result + 1] = {code = prefix, count = count}
            end
            return
        end
        local original = code:sub(at, at)
        local function append(ch, next_count)
            local next_prefix = prefix .. ch
            if lexicon.codes[next_prefix] or lexicon.proper_code_prefixes[next_prefix] then
                visit(next_prefix, at + 1, next_count)
            end
        end
        append(original, count)
        if count < 2 then
            for _, ch in ipairs(M.neighbors[original] or {}) do append(ch, count + 1) end
        end
    end
    visit("", 1, 0)
    local old=variant_keys[variant_next]
    if old then variant_values[old]=nil end
    variant_keys[variant_next],variant_values[code]=code,result
    variant_next=variant_next%2048+1
    return result
end

local function better(a, b)
    if a.score ~= b.score then return a.score > b.score end
    if (a.correction_count or 0) ~= (b.correction_count or 0) then
        return (a.correction_count or 0) < (b.correction_count or 0)
    end
    return a.text < b.text
end

function M.current(bucket, exact, position)
    local profile=M.profiles[M.profile]
    local groups = {{}, {}}
    for _, item in ipairs(bucket or {}) do
        local n = item.correction_count or 0
        if n > 0 then
            local previous = groups[n][item.text]
            if not previous or better(item, previous) then groups[n][item.text] = item end
        end
    end
    local result = {}
    for budget, group in ipairs(groups) do
        local items = {}
        for _, item in pairs(group) do items[#items + 1] = item end
        table.sort(items, better)
        local limit=budget==1 and profile.one or profile.two
        if position>24 then limit=profile.long or math.max(1,math.floor(limit/2)) end
        -- A nil limit disables only this error group's score-gap filter.
        local delta = profile.delta_one
        if budget == 2 then delta = profile.delta_two end
        local cutoff = items[1] and delta and (items[1].score - delta) or -math.huge
        local kept = 0
        for i = 1, math.min(#items, limit) do
            if items[i].score < cutoff then break end
            result[#result + 1] = items[i]
            kept = kept + 1
        end
        if M.gap_stats then
            local stats = M.gap_stats
            stats.calls = stats.calls + 1
            stats.seen = stats.seen + #items
            stats[budget] = stats[budget] + kept
            stats.pruned = stats.pruned + math.min(#items, limit) - kept
        end
    end
    -- Exact states are borrowed, never changed or removed by correction pruning.
    for i=1,math.min(#(exact or {}),profile.seeds) do result[#result+1]=exact[i] end
    return result
end

function M.add(bucket, item)
    -- Aggregate during expansion, rather than retaining a potentially quadratic
    -- list. Budget is part of identity: a cheaper prefix can still fix the tail.
    local key = tostring(item.correction_count) .. ":" .. item.text
    bucket._correction_best = bucket._correction_best or {}
    local index = bucket._correction_best[key]
    if not index then
        bucket[#bucket + 1] = item
        bucket._correction_best[key] = #bucket
    elseif better(item, bucket[index]) then bucket[index] = item end
end

function M.corrected_raw(raw, path)
    local replacements = {}
    while path do
        if path.corrected_code then
            local start = path.previous.raw_length + 1
            for i = 1, #path.corrected_code do replacements[start + i - 1] = path.corrected_code:sub(i, i) end
        end
        path = path.previous
    end
    local pieces = {}
    for i = 1, #raw do pieces[i] = replacements[i] or raw:sub(i, i) end
    return table.concat(pieces)
end

function M.merge(exact, corrected, limit, reorder)
    local seen = {}
    for _, item in ipairs(exact._confidence_candidates or exact) do seen[item.text] = true end
    for _, item in ipairs(exact) do seen[item.text] = true end
    local alternatives = {}
    local best=-math.huge
    for _,item in ipairs(exact) do best=math.max(best,item.score) end
    for _,item in ipairs(corrected) do best=math.max(best,item.score) end
    for _, item in ipairs(corrected) do
        if not seen[item.text] and (M.profile=="reference" or item.score>=best-4) then
            alternatives[#alternatives + 1] = item
        end
    end
    table.sort(alternatives, better)
    local unique = {}
    for _, item in ipairs(alternatives) do
        if not seen[item.text] then unique[#unique + 1] = item; seen[item.text] = true end
        if M.profile~="reference" and #unique==2 then break end
    end
    local remaining_max, maximum = {}, -math.huge
    for i = #exact, 1, -1 do maximum = math.max(maximum, exact[i].score); remaining_max[i] = maximum end
    local result = {}
    for k, value in pairs(exact) do if type(k) ~= "number" then result[k] = value end end
    local ci = 1
    for i = 1, #exact do
        while unique[ci] and unique[ci].score > remaining_max[i] + M.margin do
            result[#result + 1] = unique[ci]; ci = ci + 1
        end
        result[#result + 1] = exact[i]
    end
    while unique[ci] do result[#result + 1] = unique[ci]; ci = ci + 1 end
    if reorder then result = reorder(result) end
    while #result > limit do result[#result] = nil end
    return result
end

return M
