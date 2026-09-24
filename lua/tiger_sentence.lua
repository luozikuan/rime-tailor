-- TigerClaw-style sentence lattice for Rime, with optional Lua KN scoring.
-- Lexicon data is loaded from plain-text files (see load_lexicon_data below),
-- so users can edit or replace the code table without re-running exporters.
-- Pure Lua Kneser-Ney V2 reader. TCSKNM02 uses paged I/O and a bounded cache.
local BOS = "\2"
local EOS = "\3"
local ISOLATION_CACHE_ENTRIES = 8192
local learning = require("tiger_sentence_learning")
local learning_index, learning_mode, learning_affected = nil, "", false
local learning_submit -- defined with the host submission adapter below

local performance = {
    decode_calls = 0,
    decode_total_ms = 0.0,
    decode_max_ms = 0.0,
    page_misses = 0,
    page_bytes = 0,
    early_evidence_builds = 0,
    isolation_hits = 0,
    isolation_misses = 0,
    last = nil
}

local function record_decode(started)
    local elapsed = (os.clock() - started) * 1000
    performance.decode_calls = performance.decode_calls + 1
    performance.decode_total_ms = performance.decode_total_ms + elapsed
    performance.decode_max_ms = math.max(performance.decode_max_ms, elapsed)
end

local function finish_performance_sample()
    if performance.decode_calls == 0 then return end
    local sample = {
        decode_calls = performance.decode_calls,
        decode_total_ms = performance.decode_total_ms,
        decode_max_ms = performance.decode_max_ms,
        page_misses = performance.page_misses,
        page_bytes = performance.page_bytes,
        early_evidence_builds = performance.early_evidence_builds,
        isolation_hits = performance.isolation_hits,
        isolation_misses = performance.isolation_misses
    }
    performance.last = sample
    performance.decode_calls = 0
    performance.decode_total_ms = 0.0
    performance.decode_max_ms = 0.0
    performance.page_misses = 0
    performance.page_bytes = 0
    performance.early_evidence_builds = 0
    performance.isolation_hits = 0
    performance.isolation_misses = 0
end

local reset_decode_cache -- forward declaration; assigned below
local clear_model_dependent_caches -- forward declaration; assigned below

-- Plain-text lexicon data.
--   tiger_sentence.codes.txt             "text\tcode", line order = rank
--   tiger_sentence.char_ranks.txt         one character per line, in rank order
--   tiger_sentence.full_code_whitelist.txt whitelist characters
-- Lookup order: user data directory, then shared data directory. Missing
-- ranks disable the isolation penalty and the common-character filter.

local function character_at(text, index)
    local byte = text:byte(index)
    if not byte then
        return nil, index
    end
    local length = 1
    if byte >= 0xF0 then
        length = 4
    elseif byte >= 0xE0 then
        length = 3
    elseif byte >= 0xC0 then
        length = 2
    end
    return text:sub(index, index + length - 1), index + length
end

local function utf_chars(text)
    local chars = {}
    if utf8 and utf8.codes then
        for _, codepoint in utf8.codes(text) do
            chars[#chars + 1] = utf8.char(codepoint)
        end
        return chars
    end
    local index = 1
    while index <= #text do
        local character
        character, index = character_at(text, index)
        chars[#chars + 1] = character
    end
    return chars
end

local function utf_length(text)
    if utf8 and utf8.len then
        local length = utf8.len(text)
        if length then
            return length
        end
    end
    local count = 0
    local index = 1
    while index <= #text do
        _, index = character_at(text, index)
        count = count + 1
    end
    return count
end

local function utf_common_prefix(left, right)
    local left_index, right_index = 1, 1
    local last_left = 0
    while left_index <= #left and right_index <= #right do
        local left_character, next_left = character_at(left, left_index)
        local right_character, next_right = character_at(right, right_index)
        if left_character ~= right_character then
            break
        end
        last_left = next_left - 1
        left_index, right_index = next_left, next_right
    end
    return last_left > 0 and left:sub(1, last_left) or ""
end

local function is_single_character(text)
    return utf_length(text) == 1
end

local function normalize_text_content(content)
    if content:sub(1, 3) == "\239\187\191" then
        content = content:sub(4)
    end
    return (content:gsub("\r\n", "\n"):gsub("\r", "\n"))
end

local function each_content_line(content, callback)
    -- Lua 5.5 makes the iterator's control variable read-only.
    for raw_line in content:gmatch("[^\n]+") do
        local line = raw_line:gsub("^%s+", ""):gsub("%s+$", "")
        if line ~= "" and line:sub(1, 1) ~= "#" then
            callback(line)
        end
    end
end

local function data_directories()
    local directories = {}
    if rime_api then
        if type(rime_api.get_user_data_dir) == "function" then
            local ok, path = pcall(rime_api.get_user_data_dir)
            if ok and type(path) == "string" and path ~= "" then
                directories[#directories + 1] = path
            end
        end
        if type(rime_api.get_shared_data_dir) == "function" then
            local ok, path = pcall(rime_api.get_shared_data_dir)
            if ok and type(path) == "string" and path ~= "" then
                directories[#directories + 1] = path
            end
        end
    end
    return directories
end

local function read_data_file(name)
    for _, directory in ipairs(data_directories()) do
        local path = directory .. "/" .. name
        local ok, handle = pcall(io.open, path, "rb")
        if ok and handle then
            local content = handle:read("*a")
            handle:close()
            if content then
                return content, path
            end
        end
    end
    return nil, nil
end

local function parse_codes_content(content)
    local entries = {}
    local seen = {}
    each_content_line(normalize_text_content(content), function(line)
        local word, code = line:match("^(%S+)%s+(%S+)")
        if word and code then
            code = code:lower()
            if code:match("^[a-z]+$") then
                local key = word .. "\0" .. code
                if not seen[key] then
                    seen[key] = true
                    entries[#entries + 1] = { word = word, code = code }
                end
            end
        end
    end)
    return entries
end

local function parse_ranks_content(content)
    local ranks = {}
    local count = 0
    each_content_line(normalize_text_content(content), function(line)
        local character = character_at(line, 1)
        if character and ranks[character] == nil then
            count = count + 1
            ranks[character] = count
        end
    end)
    return ranks, count
end

local function parse_whitelist_content(content)
    local characters = {}
    each_content_line(normalize_text_content(content), function(line)
        local index = 1
        while index <= #line do
            local character
            character, index = character_at(line, index)
            characters[character] = true
        end
    end)
    return characters
end

local default_high_freq_limit = 1500

local lexicon_state = {
    built = false,
    high_freq_limit = nil,
    codes = {},
    lengths = {},
    max_code_len = 1,
    proper_code_prefixes = {},
    character_ranks = nil,
    ranks_count = 0,
    unknown_character_rank = 20001,
    isolation_enabled = false,
    codes_path = nil,
    codes_entries = 0,
    codes_count = 0,
    ranks_path = nil,
    whitelist_path = nil,
    whitelist_count = 0,
    errors = {}
}

-- Port of SentenceLexiconIndex.Build: exact code table with line-order ranks,
-- per-character primary code (rank-1 spelling preferred, then shortest),
-- then the high-frequency optimal-code filter with the full-code whitelist.
local function build_lexicon_index(entries, character_ranks, high_freq_limit, whitelist)
    local exact = {}
    local codes_by_character = {}
    for index = 1, #entries do
        local word = entries[index].word
        local code = entries[index].code
        local texts = exact[code]
        if not texts then
            texts = {}
            exact[code] = texts
        end
        -- parse_codes_content already deduplicates (word, code), in source
        -- order. Don't scan the same candidate ranges a second time.
        texts[#texts + 1] = word
        if is_single_character(word) then
            local character_codes = codes_by_character[word]
            if not character_codes then
                character_codes = {}
                codes_by_character[word] = character_codes
            end
            character_codes[#character_codes + 1] = code
        end
    end

    local common = nil
    if character_ranks and high_freq_limit > 0 then
        common = {}
        -- parse_ranks_content assigns dense, unique 1-based source ranks.
        for character, rank in pairs(character_ranks) do
            if rank <= high_freq_limit then common[character] = true end
        end
    end

    local primary = {}
    for character, codes in pairs(codes_by_character) do
        local best_first, best_any
        for index = 1, #codes do
            local code = codes[index]
            if #code >= 2 then
                if not best_any or #code < #best_any then
                    best_any = code
                end
                local texts = exact[code]
                if texts and texts[1] == character then
                    if not best_first or #code < #best_first then
                        best_first = code
                    end
                end
            end
        end
        local chosen = best_first or best_any
        if chosen then
            primary[character] = chosen
        end
    end

    local optimal_input = {}
    for character, codes in pairs(codes_by_character) do
        local chosen
        for index = 1, #codes do
            local code = codes[index]
            if not chosen or #code < #chosen then
                chosen = code
            end
        end
        if chosen then
            optimal_input[character] = chosen
        end
    end

    local filtered = {}
    local length_values = {}
    local max_len = 1
    local prefixes = {}
    for code, texts in pairs(exact) do
        local allowed = {}
        for index = 1, #texts do
            local text = texts[index]
            local allow_non_primary =
                #code == 1
                or not is_single_character(text)
                or not common
                or not common[text]
                or whitelist[text] == true
            if allow_non_primary or primary[text] == code then
                allowed[#allowed + 1] = {
                    t = text,
                    r = index,
                    optimal_single = optimal_input[text] == code,
                    -- A sentence cannot use one-key character edges.  Keep a
                    -- second marker for the strongest legal per-character
                    -- spelling (rank-1 preferred, then shortest).  This is
                    -- P(code|character) evidence, independent of the LM.
                    primary_single = primary[text] == code
                }
            end
        end
        if #allowed > 0 then
            filtered[code] = allowed
            length_values[#code] = true
            if #code > max_len then
                max_len = #code
            end
            for length = 1, #code - 1 do
                prefixes[code:sub(1, length)] = true
            end
        end
    end

    local lengths = {}
    for value in pairs(length_values) do
        lengths[#lengths + 1] = value
    end
    table.sort(lengths)

    return {
        codes = filtered,
        lengths = lengths,
        max_code_len = max_len,
        proper_code_prefixes = prefixes
    }
end

local isolation_cache = {}
local isolation_cache_keys = {}
local isolation_cache_next = 1

local function rebuild_lexicon(limit)
    local errors = {}
    local entries = {}
    local codes_content, codes_path = read_data_file("tiger_sentence.codes.txt")
    if codes_content then
        entries = parse_codes_content(codes_content)
    else
        errors[#errors + 1] = "missing tiger_sentence.codes.txt"
    end

    local character_ranks = nil
    local ranks_count = 0
    local ranks_content, ranks_path = read_data_file("tiger_sentence.char_ranks.txt")
    if ranks_content then
        character_ranks, ranks_count = parse_ranks_content(ranks_content)
        if ranks_count == 0 then
            character_ranks = nil
        end
    end

    local whitelist = {}
    local whitelist_count = 0
    local whitelist_content, whitelist_path =
        read_data_file("tiger_sentence.full_code_whitelist.txt")
    if whitelist_content then
        whitelist = parse_whitelist_content(whitelist_content)
        for _ in pairs(whitelist) do
            whitelist_count = whitelist_count + 1
        end
    end

    local index = build_lexicon_index(entries, character_ranks, limit, whitelist)
    lexicon_state.built = true
    lexicon_state.high_freq_limit = limit
    lexicon_state.codes = index.codes
    lexicon_state.lengths = index.lengths
    lexicon_state.max_code_len = index.max_code_len
    lexicon_state.proper_code_prefixes = index.proper_code_prefixes
    lexicon_state.character_ranks = character_ranks
    lexicon_state.ranks_count = ranks_count
    lexicon_state.unknown_character_rank = ranks_count > 0 and ranks_count + 1 or 20001
    lexicon_state.isolation_enabled = character_ranks ~= nil
    lexicon_state.codes_path = codes_path
    lexicon_state.codes_entries = #entries
    lexicon_state.codes_count = 0
    for _ in pairs(index.codes) do
        lexicon_state.codes_count = lexicon_state.codes_count + 1
    end
    lexicon_state.ranks_path = ranks_path
    lexicon_state.whitelist_path = whitelist_path
    lexicon_state.whitelist_count = whitelist_count
    lexicon_state.errors = errors
    lexicon_state.learning_rules = learning.hash((codes_content or "") .. "\0" ..
        (ranks_content or "") .. "\0" .. (whitelist_content or ""))

    clear_model_dependent_caches()
end

local function configured_high_freq_limit(env)
    -- Schema configuration: absent/unreadable/non-numeric values use the
    -- default; explicit zero and negative values disable the restriction.
    local schema = env and env.engine and env.engine.schema
    local config = schema and schema.config
    if not config then
        return nil
    end
    local ok, value = pcall(function()
        return config:get_int("tiger_sentence/high_freq_limit")
    end)
    if not ok or type(value) ~= "number" then
        -- Absent or unreadable: keep the default. An explicit 0 in the
        -- schema still disables the optimal-code restriction.
        return nil
    end
    if value < 0 then
        return 0
    end
    return math.floor(value)
end

local function ensure_lexicon(env)
    local schema = env and env.engine and env.engine.schema
    -- Decoder/diagnostic calls have no schema: they borrow the active index,
    -- never select a default schema or change its configured limit. This also
    -- avoids rebuilding (and clearing decode caches) inside a frontend call.
    if not schema then
        if not lexicon_state.built then
            rebuild_lexicon(default_high_freq_limit)
        end
        return lexicon_state
    end

    -- Only an actual schema-bearing entry point resolves configuration.
    -- Missing/unreadable keys use this schema's default, not the previous
    -- schema's value. Compare effective limits, not schema identities: two
    -- schemas with the same limit can safely share the immutable index.
    local limit = configured_high_freq_limit(env)
    if limit == nil then limit = default_high_freq_limit end
    if not lexicon_state.built or limit ~= lexicon_state.high_freq_limit then
        rebuild_lexicon(limit)
    end
    return lexicon_state
end

local function data_status()
    return {
        built = lexicon_state.built,
        high_freq_limit = lexicon_state.high_freq_limit,
        codes_path = lexicon_state.codes_path,
        codes_entries = lexicon_state.codes_entries,
        codes_count = lexicon_state.codes_count,
        ranks_path = lexicon_state.ranks_path,
        ranks_count = lexicon_state.ranks_count,
        isolation_enabled = lexicon_state.isolation_enabled,
        whitelist_path = lexicon_state.whitelist_path,
        whitelist_count = lexicon_state.whitelist_count,
        errors = lexicon_state.errors
    }
end

local kn_reader = require("tiger_sentence_ngram").new(performance)

local function file_exists(path)
    local file = io.open(path, "rb")
    if not file then return false end
    file:close()
    return true
end

-- Per-schema supplemental phrase rewards for TigerClaw sentence decoding.
local supplement = {}

local file_name = "tiger_sentence.supplement.txt"
local baseline_reward = 9.0
local weight_scale = 2.0
local baseline_weight = 1000.0
local maximum_reward = 16.0

local function reward_for_weight(weight)
    local bounded = math.max(1, math.min(1000000000, weight))
    local reward = baseline_reward + weight_scale * math.log(bounded / baseline_weight)
    return math.max(0.0, math.min(maximum_reward, reward))
end

local function empty_matcher(path, load_error)
    return {
        nodes = { { transitions = {}, failure = 1, reward = 0.0 } },
        path = path,
        count = 0,
        error = load_error
    }
end

function supplement.build(entries, path)
    local nodes = { { transitions = {}, failure = 1, reward = 0.0 } }
    local count = 0
    for text, weight in pairs(entries or {}) do
        local reward = reward_for_weight(weight)
        if text ~= "" and reward > 0.0 then
            local state = 1
            local chars = utf_chars(text)
            for i = 1, #chars do
                local next_state = nodes[state].transitions[chars[i]]
                if not next_state then
                    next_state = #nodes + 1
                    nodes[state].transitions[chars[i]] = next_state
                    nodes[next_state] = { transitions = {}, failure = 1, reward = 0.0 }
                end
                state = next_state
            end
            nodes[state].reward = math.max(nodes[state].reward, reward)
            count = count + 1
        end
    end

    if count == 0 then
        return empty_matcher(path, nil)
    end

    local queue = {}
    local head = 1
    for _, child in pairs(nodes[1].transitions) do
        nodes[child].failure = 1
        queue[#queue + 1] = child
    end
    while head <= #queue do
        local current = queue[head]
        head = head + 1
        for ch, child in pairs(nodes[current].transitions) do
            local fallback = nodes[current].failure
            while fallback ~= 1 and not nodes[fallback].transitions[ch] do
                fallback = nodes[fallback].failure
            end
            local failure_target = nodes[fallback].transitions[ch]
            if failure_target and failure_target ~= child then
                nodes[child].failure = failure_target
            else
                nodes[child].failure = 1
            end
            nodes[child].reward = math.max(
                nodes[child].reward,
                nodes[nodes[child].failure].reward)
            queue[#queue + 1] = child
        end
    end
    return { nodes = nodes, path = path, count = count, error = nil }
end

function supplement.load_file(path)
    local handle, open_error = io.open(path, "rb")
    if not handle then
        return empty_matcher(path, open_error)
    end
    local content = handle:read("*a") or ""
    handle:close()
    content = content:gsub("^\239\187\191", "")

    local entries = {}
    for raw_line in (content .. "\n"):gmatch("(.-)\r?\n") do
        local line = raw_line:match("^%s*(.-)%s*$") or ""
        if line ~= "" and line:sub(1, 1) ~= "#" then
            local text, rest = line:match("^(%S+)%s*(.-)$")
            local weight = 1000
            if rest and rest ~= "" then
                if not rest:match("^%d+$") then
                    text = nil
                else
                    weight = tonumber(rest)
                    if not weight or weight <= 0 then text = nil end
                end
            end
            if text then entries[text] = weight end
        end
    end
    return supplement.build(entries, path)
end

local function join_path(directory, name)
    if directory:sub(-1) == "/" or directory:sub(-1) == "\\" then
        return directory .. name
    end
    return directory .. "/" .. name
end

function supplement.default_path()
    if not rime_api or type(rime_api.get_user_data_dir) ~= "function" then
        return nil
    end
    local ok, directory = pcall(rime_api.get_user_data_dir)
    if not ok or type(directory) ~= "string" or directory == "" then
        return nil
    end
    return join_path(directory, file_name)
end

function supplement.load_default()
    local path = supplement.default_path()
    if not path then return empty_matcher(nil, nil) end
    local matcher = supplement.load_file(path)
    -- A missing optional file is normal; only report malformed/unreadable files
    -- after the path has actually resolved in a Rime frontend.
    return matcher
end

function supplement.advance(matcher, state, ch)
    if not matcher or matcher.count == 0 or not ch or ch == "" then
        return 1, 0.0
    end
    local nodes = matcher.nodes
    local current = type(state) == "number" and nodes[state] and state or 1
    while current ~= 1 and not nodes[current].transitions[ch] do
        current = nodes[current].failure
    end
    current = nodes[current].transitions[ch] or 1
    return current, nodes[current].reward
end

supplement.file_name = file_name
supplement.reward_for_weight = reward_for_weight

local beam_width = 200
-- A 200-wide beam protects ambiguity near the start of a sentence. Once a
-- long composition already has substantial left context, retaining all 200
-- states makes random/low-confidence input slower on every following key and
-- lets synchronous Rime translations queue behind physical input. Bound only
-- the long tail; deriving the limit from the lattice position keeps full and
-- incremental decoding identical.
local long_input_full_beam_length = 24
local long_input_beam_width = 48
local candidate_limit = 20
local max_raw_length = 128
local rank_penalty = 0.03
local emitted_character_reward = 2.0
local whole_input_single_character_reward = 5.0
-- Shape-code evidence is deliberately excluded from confidence mass and Beam
-- pruning; it must not by itself make early commit look calibrated.
local isolation_threshold = 3000
local isolation_lambda = 2.0
local ranking_prior = {
    -- Shape and lexical evidence are excluded from confidence mass.  The word
    -- filter also reranks only Top-5, so neither heuristic can manufacture
    -- early-commit confidence or introduce a candidate that the LM missed.
    canonical_code_reward = 2.0,
    lexical_prior_weight = 0.1,
    lexical_candidate_limit = 5,
    -- A full four-key spelling is strong enough to protect an otherwise
    -- isolated rare character; shorter spellings retain the legacy penalty.
    canonical_isolation_factor = 0.0,
    canonical_isolation_min_code_length = 4,
    lexical = require("tiger_sentence_lexical")
}
local early_commit_minimum_share = 0.99
-- Strong classification stays model-only even when personalization raises the
-- ordinary multi-generation share.
local early_commit_strong_share = 0.999
local early_commit_closed_boundary_share = 0.99999
local early_commit_required_evidence = 3
local early_commit_required_strong = 2
local early_commit_maximum_neutral_gap = 3
local early_commit_retained_raw_length = 3
ranking_prior.supplement_early_commit_scale = 0.05
ranking_prior.supplement_early_commit_cap = 0.75
ranking_prior.personalized_early_commit_cap = 0.80
ranking_prior.empty_code_strong_share = 0.99999
function ranking_prior.supplement_early_commit_contribution(score)
    return math.min(ranking_prior.supplement_early_commit_cap,
        math.max(0, score or 0) * ranking_prior.supplement_early_commit_scale)
end
function ranking_prior.early_confidence(candidate)
    return candidate.early_commit_confidence_score or candidate.confidence_score or candidate.score
end
-- 允许单字重码组句 defaults to on; the Rime switch only turns it off.
local allow_duplicate_single_option = "tiger_sentence_allow_duplicate_single"
local active_allow_duplicate_single = true
local BOS = kn_reader.BOS
local EOS = kn_reader.EOS
local kn_model = false
local kn_load_error = nil
local model_generation = 0
local model_failure = {} -- Only model-operation failures may trigger decode retry.

local function call_model(model, operation, ...)
    local ok, value = pcall(model[operation], ...)
    if ok and (operation ~= "logp" or
        (type(value) == "number" and value == value and math.abs(value) < math.huge)) then
        return value
    end
    model_failure.reason = ok and "non-finite model probability" or tostring(value)
    error(model_failure, 0)
end

local function close_model()
    local previous = kn_model
    kn_model = nil
    if previous and previous.close then pcall(previous.close) end
end
-- Test/frontend hook: force-disable the n-gram model so the no-model
-- fallback ordering can be exercised deterministically.
local model_disabled = false
local supplement_matcher = supplement.load_default()
local has_supplements = (supplement_matcher.count or 0) > 0
do
    local paths = {}
    for _, directory in ipairs(data_directories()) do
        paths[#paths + 1] = join_path(directory, "tiger_sentence.lexical.bin")
    end
    ranking_prior.lexical_model, ranking_prior.lexical_load_error =
        ranking_prior.lexical.load_first(paths)
end

local logp_cache_limit = 32768
local logp_cache = {}
local logp_cache_keys = {}
local logp_cache_next = 1
local observed_cache_limit = 32768
local observed_cache = {}
local observed_cache_keys = {}
local observed_cache_next = 1
local aggregate_during_expansion_threshold = 128
local decode_cache = {
    raw = nil,
    states = nil,
    result = nil,
    includes_early_commit = false,
    required_text_prefix = "",
    allow_duplicate = true
}
local state_separator = "\31"
local locked_decode_cache = {}

local function beam_limit_at(raw_length)
    if raw_length > long_input_full_beam_length then
        return long_input_beam_width
    end
    return beam_width
end

local function clear_lookup_caches()
    -- Removing entries does not shrink Lua table capacity. Replace the tables
    -- so memory-pressure/model-reset paths can actually release their storage.
    logp_cache, logp_cache_keys, logp_cache_next = {}, {}, 1
    observed_cache, observed_cache_keys, observed_cache_next = {}, {}, 1
    isolation_cache, isolation_cache_keys, isolation_cache_next = {}, {}, 1
end

clear_model_dependent_caches = function()
    clear_lookup_caches()
    if reset_decode_cache then
        reset_decode_cache()
    end
end

-- Profiles change memoization capacity only. They never change the Beam,
-- scoring policy, candidate pool, learning epoch, or a live composition.
local memory_profiles = {
    balanced = {page_bytes=8*1024*1024, context_entries=16384, bigram_entries=8192,
        index_pages=64, logp_entries=32768, observed_entries=32768, isolation_entries=8192},
    compact = {page_bytes=2*1024*1024, context_entries=4096, bigram_entries=2048,
        index_pages=16, logp_entries=8192, observed_entries=4096, isolation_entries=2048}
}
local active_memory_profile = "balanced"
local function set_memory_profile(name)
    if name == nil then return false end
    local limits = memory_profiles[name]
    if not limits then return false end
    if name == active_memory_profile then return true end
    active_memory_profile = name
    logp_cache_limit, observed_cache_limit = limits.logp_entries, limits.observed_entries
    ISOLATION_CACHE_ENTRIES = limits.isolation_entries
    clear_lookup_caches()
    if kn_model and kn_model.configure_cache then kn_model.configure_cache(limits) end
    return true
end
local function configure_memory(env)
    local schema = env and env.engine and env.engine.schema
    -- Like high_freq_limit, a schema-less decoder call must not reset an
    -- explicit frontend profile. Only actual schema entries select defaults.
    if not env or not schema then return end
    local ok, name = pcall(function()
        return schema.config:get_string("tiger_sentence/memory_profile")
    end)
    if not ok or not memory_profiles[name] then name = "balanced" end
    set_memory_profile(name)
end

-- Only committed-prefix state must be visible to both the processor and
-- translator. Keep per-key confidence state on the processor environment so
-- it does not emit a Rime property update (and a redundant UI refresh) for
-- every physical key. The old properties are cleared once for live migration.
local state_keys = {
    buffered = "tiger_sentence_buffered_text",
    locks = "tiger_sentence_locks",
    committed = "tiger_sentence_committed",
    -- Read once during migration from the old two-property format.
    committed_text = "tiger_sentence_committed_text",
    committed_raw = "tiger_sentence_committed_raw",
    -- Cleared once during migration from the old proposal-history format.
    confidence = "tiger_sentence_confidence",
    proposal = "tiger_sentence_proposal",
    stable = "tiger_sentence_stable",
    evidence_raw = "tiger_sentence_evidence_raw"
}

local function fresh_transient_state()
    return {
        trackers = {},
        last_seen_raw = "",
        last_auto_commit_raw_length = 0,
        suspended = false,
        empty_code_pending = nil,
        continuation_after_auto_commit = false,
        model_generation = model_generation
    }
end

local function transient_state(context, env)
    if not env then
        return fresh_transient_state()
    end
    if not env._tiger_sentence_transient then
        -- The old single-proposal history cannot be migrated into
        -- independent (text, raw boundary) trackers; start clean.
        env._tiger_sentence_transient = fresh_transient_state()
    end
    return env._tiger_sentence_transient
end

local function set_property_if_changed(context, key, value)
    value = value or ""
    if (context:get_property(key) or "") ~= value then
        context:set_property(key, value)
    end
end

local function parse_committed_property(value)
    local separator = (value or ""):find("\t", 1, true)
    if not separator then
        return "", ""
    end
    return value:sub(1, separator - 1), value:sub(separator + 1)
end

-- Length framing keeps arbitrary candidate text intact and shares locks with
-- the translator's separate environment without retaining model objects.
local last_lock_data, last_lock_fields = "", {}
local function read_locks(context)
    local data = context:get_property(state_keys.locks) or ""
    if data == last_lock_data then
        -- Callers append/remove locks. Share only immutable entries, never the
        -- mutable list, between processor/translator or different contexts.
        local result = {}
        for i = 1, #last_lock_fields do result[i] = last_lock_fields[i] end
        return result
    end
    local fields, offset = {}, 1
    while offset <= #data do
        local colon = data:find(":", offset, true)
        local length = colon and tonumber(data:sub(offset, colon - 1))
        if not length or length < 0 or colon + length > #data then return {} end
        fields[#fields + 1] = data:sub(colon + 1, colon + length)
        offset = colon + length + 1
    end
    local locks = {}
    for i = 1, #fields - 2, 3 do
        locks[#locks + 1] = { raw = fields[i], text = fields[i + 1], boundaries = fields[i + 2] }
    end
    last_lock_data, last_lock_fields = data, {}
    for i = 1, #locks do last_lock_fields[i] = locks[i] end
    return locks
end

local function save_locks(context, locks)
    local fields = {}
    for _, lock in ipairs(locks or {}) do
        for _, field in ipairs({lock.raw, lock.text, lock.boundaries}) do
            fields[#fields + 1] = tostring(#field) .. ":" .. field
        end
    end
    set_property_if_changed(context, state_keys.locks, table.concat(fields))
end

local function active_lock(state)
    return state.locks and state.locks[#state.locks]
end

local function synchronize_model_state(state)
    if state.model_generation == model_generation then return false end
    state.model_generation = model_generation
    state.trackers = {}
    state.last_seen_raw = ""
    state.empty_code_pending = nil
    return true
end

local function sentence_state(context, env)
    local transient = transient_state(context, env)
    local combined = context:get_property(state_keys.committed) or ""
    local committed_raw, committed_text = parse_committed_property(combined)
    if combined == "" then
        -- One-time migration from the old two-property format.
        local old_raw = context:get_property(state_keys.committed_raw) or ""
        local old_text = context:get_property(state_keys.committed_text) or ""
        if old_raw ~= "" or old_text ~= "" then
            committed_raw, committed_text = old_raw, old_text
            set_property_if_changed(context, state_keys.committed,
                old_raw .. "\t" .. old_text)
            set_property_if_changed(context, state_keys.committed_raw, "")
            set_property_if_changed(context, state_keys.committed_text, "")
        end
    end
    synchronize_model_state(transient)
    transient.committed_text = committed_text
    transient.committed_raw = committed_raw
    transient.buffered_text = context:get_property(state_keys.buffered) or ""
    transient.locks = read_locks(context)
    transient.trackers = transient.trackers or {}
    transient.last_seen_raw = transient.last_seen_raw or ""
    transient.last_auto_commit_raw_length = transient.last_auto_commit_raw_length or 0
    transient.suspended = transient.suspended or false
    transient.continuation_after_auto_commit =
        transient.continuation_after_auto_commit or false
    return transient
end

local function save_transient_state(context, state, env)
    if env then
        env._tiger_sentence_transient = state
    end
    if env and not env._tiger_sentence_legacy_cleared then
        set_property_if_changed(context, state_keys.confidence, "")
        set_property_if_changed(context, state_keys.proposal, "")
        set_property_if_changed(context, state_keys.stable, "")
        set_property_if_changed(context, state_keys.evidence_raw, "")
        env._tiger_sentence_legacy_cleared = true
    end
end

local function save_sentence_state(context, state, env)
    set_property_if_changed(context, state_keys.buffered, state.buffered_text or "")
    save_locks(context, state.locks)
    set_property_if_changed(context, state_keys.committed,
        (state.committed_raw or "") .. "\t" .. (state.committed_text or ""))
    save_transient_state(context, state, env)
end

local function reset_sentence_state(context, env, continuation_after_auto_commit)
    finish_performance_sample()
    local transient = fresh_transient_state()
    transient.continuation_after_auto_commit = continuation_after_auto_commit or false
    save_sentence_state(context, {
        committed_text = "",
        committed_raw = "",
        trackers = transient.trackers,
        last_seen_raw = transient.last_seen_raw,
        last_auto_commit_raw_length = transient.last_auto_commit_raw_length,
        suspended = transient.suspended,
        empty_code_pending = transient.empty_code_pending,
        continuation_after_auto_commit = transient.continuation_after_auto_commit
    }, env)
end

local function ensure_kn()
    if model_disabled then
        return nil
    end
    if kn_model ~= false then
        return kn_model
    end
    kn_model, kn_load_error = kn_reader.try_load(memory_profiles[active_memory_profile])
    kn_model = kn_model or nil
    return kn_model
end

local function model_status()
    local model = ensure_kn()
    if model then
        return {
            loaded = true,
            path = model.path,
            format = model.format,
            bytes = model.bytes,
            error = nil
        }
    end
    return {
        loaded = false,
        path = nil,
        format = nil,
        bytes = 0,
        error = kn_load_error
    }
end

local function logp(prev2, prev1, target)
    local key = prev2 .. "\0" .. prev1 .. "\0" .. target
    local cached = logp_cache[key]
    if cached ~= nil then
        return cached
    end
    local model = ensure_kn()
    local value = 0
    if model then
        value = call_model(model, "logp", prev2, prev1, target)
    end
    local old_key = logp_cache_keys[logp_cache_next]
    if old_key then
        logp_cache[old_key] = nil
    end
    logp_cache[key] = value
    logp_cache_keys[logp_cache_next] = key
    logp_cache_next = logp_cache_next % logp_cache_limit + 1
    return value
end

local function trailing_selector_span(raw)
    local index = #raw
    while index >= 1 do
        local mark = raw:sub(index, index)
        if mark:match("%d") or mark == ";" or mark == "'" then
            index = index - 1
        else
            break
        end
    end
    return #raw - index
end

local function normalize(raw)
    if not raw then
        return ""
    end
    return raw:lower():gsub("%s+", "")
end

local function has_letter(raw)
    return raw:find("%a") ~= nil
end

local function candidate_chars(candidate)
    if not candidate._chars then
        candidate._chars = utf_chars(candidate.t)
    end
    return candidate._chars
end

local function candidate_char_count(candidate)
    if candidate._char_count == nil then
        candidate._char_count = utf_length(candidate.t)
    end
    return candidate._char_count
end

local function candidate_is_single(candidate)
    if candidate._single == nil then
        candidate._single = candidate_char_count(candidate) == 1
    end
    return candidate._single
end

local function eligible_candidates(candidates, selected_rank, whole_input_edge, allow_duplicate_single)
    -- Most code lists contain one entry. Reuse that immutable list instead of
    -- storing an identical one-element _duplicate/_rank_N table on every code.
    if #candidates == 1 then
        local candidate = candidates[1]
        if selected_rank > 0 then
            if candidate.r == selected_rank then return candidates end
        elseif whole_input_edge or candidate.r == 1 or
            (allow_duplicate_single and candidate_is_single(candidate)) then
            return candidates
        end
    end
    if selected_rank == 0 then
        if whole_input_edge then
            return candidates
        end
        if allow_duplicate_single then
            -- Rank one plus single-character duplicates; non-first
            -- multi-character words still need an explicit selector.
            local cached = candidates._duplicate
            if cached then
                return cached
            end
            local selected = {}
            for index = 1, #candidates do
                if candidates[index].r == 1 or candidate_is_single(candidates[index]) then
                    selected[#selected + 1] = candidates[index]
                end
            end
            candidates._duplicate = selected
            return selected
        end
    end
    local rank = selected_rank > 0 and selected_rank or 1
    local cache_key = "_rank_" .. tostring(rank)
    local cached = candidates[cache_key]
    if cached then
        return cached
    end
    local selected = {}
    for index = 1, #candidates do
        if candidates[index].r == rank then
            selected[#selected + 1] = candidates[index]
        end
    end
    candidates[cache_key] = selected
    return selected
end

local function has_observed_bigram(previous, target)
    local key = previous .. "\0" .. target
    local cached = observed_cache[key]
    if cached ~= nil then
        return cached
    end
    local model = ensure_kn()
    local value = model and model.has_observed_bigram and
        call_model(model, "has_observed_bigram", previous, target) or false
    local old_key = observed_cache_keys[observed_cache_next]
    if old_key then
        observed_cache[old_key] = nil
    end
    observed_cache[key] = value
    observed_cache_keys[observed_cache_next] = key
    observed_cache_next = observed_cache_next % observed_cache_limit + 1
    return value
end

local function isolation_penalty(text)
    local model = ensure_kn()
    if not model or not model.has_observed_bigram or not text or text == "" or
        not lexicon_state.isolation_enabled then
        return 0
    end
    local cached = isolation_cache[text]
    if cached ~= nil then
        performance.isolation_hits = performance.isolation_hits + 1
        return cached
    end
    performance.isolation_misses = performance.isolation_misses + 1
    local chars = utf_chars(text)
    local penalty = 0
    for index = 1, #chars do
        local rank = (lexicon_state.character_ranks[chars[index]] or
            lexicon_state.unknown_character_rank)
        if rank > isolation_threshold then
            local left_hit = index > 1 and has_observed_bigram(chars[index - 1], chars[index])
            local right_hit = index < #chars and has_observed_bigram(chars[index], chars[index + 1])
            if not left_hit and not right_hit then
                penalty = penalty + isolation_lambda
            end
        end
    end
    local old_key = isolation_cache_keys[isolation_cache_next]
    if old_key then isolation_cache[old_key] = nil end
    isolation_cache[text] = penalty
    isolation_cache_keys[isolation_cache_next] = text
    isolation_cache_next = isolation_cache_next % ISOLATION_CACHE_ENTRIES + 1
    return penalty
end

-- Evaluate only published/scored paths, never during Beam expansion. Appending
-- an edge can change the old final character's right neighbour, but cannot
-- change any earlier character's isolation status.
local function path_isolation_penalty(item)
    local model = ensure_kn()
    if not item or not model or not model.has_observed_bigram or
        not lexicon_state.isolation_enabled then return 0 end
    if item._isolation_penalty ~= nil then
        performance.isolation_hits = performance.isolation_hits + 1
        return item._isolation_penalty
    end
    performance.isolation_misses = performance.isolation_misses + 1
    local previous = item.previous
    local penalty = path_isolation_penalty(previous)
    local last_char = previous and previous._isolation_last_char
    local last_weight = previous and previous._isolation_last_weight or 0.0
    local chars = item.edge_chars or {}
    local edge_factor = item.edge_primary_single and
        (item.edge_code_length or 0) >= ranking_prior.canonical_isolation_min_code_length and
        ranking_prior.canonical_isolation_factor or 1.0
    for i = 1, #chars do
        local ch = chars[i]
        local rank = lexicon_state.character_ranks[ch] or lexicon_state.unknown_character_rank
        local rare = rank > isolation_threshold
        local rare_weight = rare and edge_factor or 0.0
        local linked = last_char and (last_weight > 0.0 or rare_weight > 0.0) and
            has_observed_bigram(last_char, ch)
        if last_weight > 0.0 and linked then
            penalty = penalty - isolation_lambda * last_weight
        end
        last_weight = rare and not linked and rare_weight or 0.0
        if last_weight > 0.0 then
            penalty = penalty + isolation_lambda * last_weight
        end
        last_char = ch
    end
    item._isolation_penalty = penalty
    item._isolation_last_char = last_char
    item._isolation_last_weight = last_weight
    item._isolation_last_isolated = last_weight > 0.0
    return penalty
end

-- Independent full-path oracle used by regressions.  This deliberately does
-- not read or populate the lazy per-node isolation cache above.
ranking_prior.reference_path_isolation_penalty = function(item)
    local model = ensure_kn()
    if not item or not model or not model.has_observed_bigram or
        not lexicon_state.isolation_enabled then return 0 end
    local edges = {}
    while item and item.previous do
        table.insert(edges, 1, item)
        item = item.previous
    end
    local penalty, last_char, last_weight = 0.0, nil, 0.0
    for _, edge in ipairs(edges) do
        local edge_factor = edge.edge_primary_single and
            (edge.edge_code_length or 0) >=
                ranking_prior.canonical_isolation_min_code_length and
            ranking_prior.canonical_isolation_factor or 1.0
        for _, ch in ipairs(edge.edge_chars or {}) do
            local rank = lexicon_state.character_ranks[ch] or
                lexicon_state.unknown_character_rank
            local rare_weight = rank > isolation_threshold and edge_factor or 0.0
            local linked = last_char and (last_weight > 0.0 or rare_weight > 0.0) and
                has_observed_bigram(last_char, ch)
            if last_weight > 0.0 and linked then
                penalty = penalty - isolation_lambda * last_weight
            end
            last_weight = rare_weight > 0.0 and not linked and rare_weight or 0.0
            if last_weight > 0.0 then
                penalty = penalty + isolation_lambda * last_weight
            end
            last_char = ch
        end
    end
    return penalty
end

local function parse_selector(raw, code_end)
    local next_index = code_end + 1
    if next_index > #raw then
        return 0, code_end
    end
    local mark = raw:sub(next_index, next_index)
    if mark == ";" then
        return 2, next_index
    end
    if mark == "'" then
        return 3, next_index
    end
    if mark:match("%d") then
        local digit_end = next_index
        while digit_end < #raw and raw:sub(digit_end + 1, digit_end + 1):match("%d") do
            digit_end = digit_end + 1
        end
        local token = raw:sub(next_index, digit_end)
        if token == "0" then
            return 10, digit_end
        end
        return tonumber(token) or 0, digit_end
    end
    return 0, code_end
end

local function advance_required_prefix(required, matched_length, candidate_text)
    if matched_length >= #required then
        return matched_length
    end
    candidate_text = candidate_text or ""
    local compare_length = math.min(#candidate_text, #required - matched_length)
    if compare_length == 0 or
        required:sub(matched_length + 1, matched_length + compare_length) ~=
        candidate_text:sub(1, compare_length) then
        return nil
    end
    return math.min(#required, matched_length + #candidate_text)
end

local function has_complete_candidate(raw_code, required_text_prefix, excluded_text, group_eligible_only, locked)
    local raw = normalize(raw_code)
    if raw == "" or not has_letter(raw) then
        return false
    end

    local required = required_text_prefix or ""
    if required == "" and not excluded_text and not group_eligible_only and not locked then
        local reachable = { [0] = true }
        for position = 0, #raw - 1 do
            if reachable[position] then
                for i = 1, #lexicon_state.lengths do
                    local code_end = position + lexicon_state.lengths[i]
                    if code_end <= #raw then
                        local candidates = lexicon_state.codes[raw:sub(position + 1, code_end)]
                        if candidates then
                            local selected_rank, consumed_end = parse_selector(raw, code_end)
                            local whole_input_edge = position == 0 and consumed_end == #raw
                            if not (#raw > 1 and consumed_end - position < 2) and
                                #eligible_candidates(candidates, selected_rank,
                                    whole_input_edge, active_allow_duplicate_single) > 0 then
                                reachable[consumed_end] = true
                            end
                        end
                    end
                end
            end
        end
        return reachable[#raw] or false
    end

    local first_ranks_only = group_eligible_only and not raw:find("[;'0-9]")
    local stride = excluded_text and (#excluded_text + 2) or 1
    local states = {}
    for index = 0, #raw do states[index] = {} end
    local start, matched, excluded = 0, 0, 0
    if locked then
        local prefix = normalize(locked.raw)
        matched = math.min(#required, #locked.text)
        if raw:sub(1, #prefix) ~= prefix or required:sub(1, matched) ~= locked.text:sub(1, matched) then return false end
        start = #prefix
        if excluded_text then excluded = excluded_text:sub(1, #locked.text) == locked.text and #locked.text or #excluded_text + 1 end
        if start == #raw then return matched == #required and (not excluded_text or excluded ~= #excluded_text) end
    end
    states[start][matched * stride + excluded] = true
    for position = start, #raw - 1 do
        if next(states[position]) then
            for i = 1, #lexicon_state.lengths do
                local code_length = lexicon_state.lengths[i]
                local code_end = position + code_length
                if code_end <= #raw then
                    local candidates = lexicon_state.codes[raw:sub(position + 1, code_end)]
                    if candidates then
                        local selected_rank, consumed_end = parse_selector(raw, code_end)
                        local whole_input_edge = position == 0 and consumed_end == #raw
                        if not (#raw > 1 and consumed_end - position < 2) then
                            local selected = eligible_candidates(
                                candidates, selected_rank, whole_input_edge,
                                active_allow_duplicate_single)
                            for packed in pairs(states[position]) do
                                local matched_length = math.floor(packed / stride)
                                for candidate_index = 1, #selected do
                                    local candidate = selected[candidate_index]
                                    local next_matched = advance_required_prefix(
                                        required,
                                        matched_length,
                                        candidate.t)
                                    if next_matched and (not first_ranks_only or candidate.r == 1 or
                                        (active_allow_duplicate_single and candidate_is_single(candidate))) then
                                        local next_excluded = packed % stride
                                        if excluded_text and next_excluded <= #excluded_text then
                                            if excluded_text:sub(next_excluded + 1,
                                                next_excluded + #candidate.t) == candidate.t then
                                                next_excluded = next_excluded + #candidate.t
                                            else
                                                next_excluded = #excluded_text + 1
                                            end
                                        end
                                        if consumed_end == #raw and next_matched == #required and
                                            (not excluded_text or next_excluded ~= #excluded_text) then
                                            return true
                                        end
                                        states[consumed_end][next_matched * stride + next_excluded] = true
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end
    end
    return false
end

local function state_better_rank_first(left, right)
    local left_rank = left.max_rank or 1
    local right_rank = right.max_rank or 1
    if left_rank ~= right_rank then
        return left_rank < right_rank
    end
    if left.score == right.score then
        return left.text < right.text
    end
    return left.score > right.score
end

local function state_better_score_first(left, right)
    if left.score == right.score then
        local left_rank = left.max_rank or 1
        local right_rank = right.max_rank or 1
        if left_rank ~= right_rank then
            return left_rank < right_rank
        end
        return left.text < right.text
    end
    return left.score > right.score
end

-- Without an n-gram model the per-character reward dominates the score and
-- multi-segment concatenations would outrank direct code entries. Fall back
-- to lexicon rank first, then fewer lexicon edges, then score.
local function state_better_no_model(left, right)
    local left_rank = left.max_rank or 1
    local right_rank = right.max_rank or 1
    if left_rank ~= right_rank then
        return left_rank < right_rank
    end
    local left_edges = left.edge_count or 0
    local right_edges = right.edge_count or 0
    if left_edges ~= right_edges then
        return left_edges < right_edges
    end
    if left.score == right.score then
        return left.text < right.text
    end
    return left.score > right.score
end

-- Mirrors SentenceInputDecoder.GetBeamStateComparison. Resolve this once per
-- bucket instead of probing model availability for every heap comparison.
local function current_state_comparator()
    if not ensure_kn() then
        return state_better_no_model
    end
    if active_allow_duplicate_single then
        return state_better_score_first
    end
    return state_better_rank_first
end

learning.source_direct, learning.source_composed = 1, 2
function learning.source_union(a, b)
    a, b = a or 0, b or 0
    if a == 0 then return b end
    if b == 0 or a == b then return a end
    return 3
end
function learning.candidate_is_direct(item)
    local source = item and item.source_mask or 0
    return source == learning.source_direct or source == 3
end
function learning.candidate_is_composed_only(item)
    return item and item.source_mask == learning.source_composed
end

local function duplicate_better(item, previous)
    if (item.learning_score or 0) > 0 or (previous.learning_score or 0) > 0 or
        (item.learning_potential or 0) > 0 or (previous.learning_potential or 0) > 0 then
        return item.score + (item.learning_potential or 0) > previous.score + (previous.learning_potential or 0)
    end
    local item_rank = item.max_rank or 1
    local previous_rank = previous.max_rank or 1
    if item_rank ~= previous_rank then
        return item_rank < previous_rank
    end
    if item.score ~= previous.score then
        return item.score > previous.score
    end
    return (item.edge_count or 0) < (previous.edge_count or 0)
end

local function logsumexp(left, right)
    local maximum = math.max(left, right)
    return maximum + math.log(math.exp(left - maximum) + math.exp(right - maximum))
end

local function new_bucket()
    return {}
end

local function add_aggregated(bucket, item)
    local best = bucket._best
    local mass = bucket._mass
    local previous = best[item.text]
    local item_mass = item.mass_score or item.score
    if not previous then
        best[item.text] = item
        mass[item.text] = item_mass
        bucket._order[#bucket._order + 1] = item.text
    else
        mass[item.text] = logsumexp(mass[item.text], item_mass)
        local source = learning.source_union(previous.source_mask, item.source_mask)
        local direct_rank = math.min(previous.direct_rank or math.huge, item.direct_rank or math.huge)
        if duplicate_better(item, previous) then
            best[item.text] = item
        end
        best[item.text].source_mask = source
        best[item.text].direct_rank = direct_rank
    end
    best[item.text].mass_score = mass[item.text]
end

local function ensure_aggregated(bucket)
    if bucket._best then
        return
    end
    local best = {}
    local mass = {}
    local order = {}
    for i = 1, #bucket do
        local item = bucket[i]
        local previous = best[item.text]
        local item_mass = item.mass_score or item.score
        if mass[item.text] == nil then
            mass[item.text] = item_mass
        else
            mass[item.text] = logsumexp(mass[item.text], item_mass)
        end
        if not previous then
            order[#order + 1] = item.text
            best[item.text] = item
        else
            local source = learning.source_union(previous.source_mask, item.source_mask)
            local direct_rank = math.min(previous.direct_rank or math.huge, item.direct_rank or math.huge)
            if duplicate_better(item, previous) then
                best[item.text] = item
            end
            best[item.text].source_mask = source
            best[item.text].direct_rank = direct_rank
        end
    end
    for i = #bucket, 1, -1 do
        bucket[i] = nil
    end
    for i = 1, #order do
        best[order[i]].mass_score = mass[order[i]]
    end
    bucket._best = best
    bucket._mass = mass
    bucket._order = order
end

local function add_state(bucket, item)
    if bucket._frozen then
        bucket._frozen = nil
        ensure_aggregated(bucket)
    end
    if bucket._best then
        add_aggregated(bucket, item)
        return
    end
    bucket[#bucket + 1] = item
    if #bucket >= aggregate_during_expansion_threshold then
        ensure_aggregated(bucket)
    end
end

local function sift_worst_up(heap, index, better)
    while index > 1 do
        local parent = math.floor(index / 2)
        if not better(heap[parent], heap[index]) then
            return
        end
        heap[parent], heap[index] = heap[index], heap[parent]
        index = parent
    end
end

local function sift_worst_down(heap, index, better)
    while true do
        local left = index * 2
        if left > #heap then
            return
        end
        local right = left + 1
        local worse = left
        if right <= #heap and better(heap[left], heap[right]) then
            worse = right
        end
        if not better(heap[index], heap[worse]) then
            return
        end
        heap[index], heap[worse] = heap[worse], heap[index]
        index = worse
    end
end

local function select_exact_top(values, limit, better)
    better = better or state_better_rank_first
    local heap = {}
    for i = 1, #values do
        local item = values[i]
        if #heap < limit then
            heap[#heap + 1] = item
            sift_worst_up(heap, #heap, better)
        elseif better(item, heap[1]) then
            heap[1] = item
            sift_worst_down(heap, 1, better)
        end
    end
    table.sort(heap, better)
    return heap
end

local function dedup_limit(bucket, limit)
    if not bucket then
        return new_bucket()
    end
    if bucket._frozen then
        return bucket
    end
    ensure_aggregated(bucket)
    local result = {}
    for i = 1, #bucket._order do
        local selected = bucket._best[bucket._order[i]]
        if selected then
            result[#result + 1] = selected
        end
    end
    local truncated_now = #result > limit
    local truncated = (bucket._truncated or false) or truncated_now
    local better = current_state_comparator()
    for _, item in ipairs(result) do
        if (item.learning_score or 0) > 0 then better = state_better_score_first; break end
    end
    if truncated_now then
        local reserved
        for _, item in ipairs(result) do
            if (item.learning_potential or 0) > 0 then
                reserved = reserved or {}; reserved[#reserved + 1] = item
            end
        end
        if reserved then
            table.sort(reserved, function(a, b) return a.score + a.learning_potential > b.score + b.learning_potential end)
        end
        result = select_exact_top(result, limit, better)
        if reserved then
            local kept, added = {}, 0
            for _, item in ipairs(result) do kept[item] = true end
            for _, item in ipairs(reserved) do
                if added == 4 then break end
                if not kept[item] then result[#result + 1] = item; added = added + 1 end
            end
        end
    else
        table.sort(result, better)
    end
    -- result is private to this invocation; publishing it directly avoids
    -- allocating/copying a second array without touching an older snapshot.
    result._truncated = truncated
    result._frozen = true
    return result
end

local function new_states(length)
    local states = {}
    for index = 0, length do
        states[index] = new_bucket()
    end
    add_state(states[0], {
        score = 0,
        mass_score = 0,
        text = "",
        prev2 = BOS,
        prev1 = BOS,
        max_rank = 1,
        supplement_state = 1,
        supplement_score = 0.0,
        code_score = 0.0,
        previous = nil,
        text_length = 0,
        text_char_count = 0,
        raw_length = 0,
        edge_count = 0
    })
    return states
end

local function expand_range(raw, states, from_pos, length, minimum_consumed_end)
    minimum_consumed_end = minimum_consumed_end or -1
    -- Collect shape evidence on paths but do not put it into Beam scores.
    -- The existing LM keeps complete control of candidate generation and the
    -- prior is applied only after a path reaches the final boundary.
    local code_reward_per_key = ensure_kn() and ranking_prior.canonical_code_reward or 0.0
    local protect_primary_rare = ranking_prior.canonical_isolation_factor < 1.0
    for position = from_pos, length - 1 do
        local current = dedup_limit(states[position], beam_limit_at(position))
        states[position] = current
        if #current > 0 then
            for i = 1, #lexicon_state.lengths do
                local code_length = lexicon_state.lengths[i]
                if position + code_length <= length then
                    local code = raw:sub(position + 1, position + code_length)
                    local candidates = lexicon_state.codes[code]
                    if candidates then
                        local selected_rank, consumed_end = parse_selector(raw, position + code_length)
                        local whole_input_edge = position == 0 and consumed_end == length
                        if consumed_end > minimum_consumed_end and
                            not (length > 1 and consumed_end - position < 2) then
                            local selected_candidates = eligible_candidates(
                                candidates, selected_rank, whole_input_edge,
                                active_allow_duplicate_single)
                            -- A descendant cannot recover probability mass
                            -- already discarded at an earlier lattice boundary.
                            if #selected_candidates > 0 and current._truncated then
                                states[consumed_end]._truncated = true
                            end
                            for c = 1, #current do
                                local item = current[c]
                                for k = 1, #selected_candidates do
                                    local candidate = selected_candidates[k]
                                    local score = item.score
                                    local prev2, prev1 = item.prev2, item.prev1
                                    local supplement_state = item.supplement_state or 1
                                    local supplement_added = 0.0
                                    local chars = candidate_chars(candidate)
                                    for ci = 1, #chars do
                                        score = score + logp(prev2, prev1, chars[ci])
                                        score = score + emitted_character_reward
                                        if has_supplements then
                                            local supplement_reward
                                            supplement_state, supplement_reward = supplement.advance(
                                                supplement_matcher, supplement_state, chars[ci])
                                            score = score + supplement_reward
                                            supplement_added = supplement_added + supplement_reward
                                        end
                                        prev2 = prev1
                                        prev1 = chars[ci]
                                    end
                                    if selected_rank == 0 then
                                        if candidate._log_rank == nil then
                                            candidate._log_rank = math.log(candidate.r)
                                        end
                                        score = score - rank_penalty * candidate._log_rank
                                    end
                                    local code_reward_added = 0.0
                                    if code_reward_per_key > 0.0 and selected_rank == 0 and
                                        candidate.primary_single and #chars == 1 then
                                        -- Longer primary spellings carry more
                                        -- shape evidence than two-key ones.
                                        -- Summing covered raw keys also makes
                                        -- the feature neutral when two paths
                                        -- both explain every key canonically.
                                        code_reward_added = code_reward_per_key * code_length
                                    end
                                    local whole_input_single_character_reward_added = 0.0
                                    if whole_input_edge and selected_rank == 0 and
                                        candidate.optimal_single and candidate_is_single(candidate) then
                                        whole_input_single_character_reward_added =
                                            whole_input_single_character_reward
                                        score = score + whole_input_single_character_reward_added
                                    end
                                    local text = item.text .. candidate.t
                                    local direct_edge = item.previous == nil and position == 0 and whole_input_edge
                                    local learned = item.learning_score or 0
                                    local potential = 0
                                    local learning_early_bonus = item.learning_early_commit_bonus or 0
                                    if not direct_edge then
                                        learned, potential, learning_early_bonus = learning.reward(
                                            learning_index, learning_mode, raw, text, consumed_end, item)
                                        if learned > 0 or potential > 0 then learning_affected = true end
                                    end
                                    add_state(states[consumed_end], {
                                        score = score + learned - (item.learning_score or 0),
                                        learning_score = learned,
                                        learning_potential = potential,
                                        learning_early_commit_bonus = learning_early_bonus,
                                        mass_score = (item.mass_score or item.score) +
                                            score - item.score - supplement_added -
                                            whole_input_single_character_reward_added,
                                        text = text,
                                        prev2 = prev2,
                                        prev1 = prev1,
                                        max_rank = math.max(item.max_rank or 1, candidate.r),
                                        source_mask = direct_edge and learning.source_direct or learning.source_composed,
                                        direct_rank = direct_edge and candidate.r or math.huge,
                                        supplement_state = supplement_state,
                                        supplement_score = (item.supplement_score or 0.0) +
                                            supplement_added,
                                        code_score = (item.code_score or 0.0) +
                                            code_reward_added,
                                        previous = item,
                                        edge_chars = chars,
                                        edge_primary_single =
                                            protect_primary_rare and #chars == 1 and
                                            (candidate.primary_single or selected_rank > 0),
                                        edge_code_length = protect_primary_rare and code_length or nil,
                                        text_length = #text,
                                        text_char_count = (utf8 and utf8.len and item.text_char_count) and
                                            item.text_char_count + #chars or nil,
                                        raw_length = consumed_end,
                                        edge_count = (item.edge_count or 0) + 1
                                    })
                                end
                            end
                        end
                    end
                end
            end
        end
    end
end

local function segmented_from_path(raw, path)
    if not raw or raw == "" or not path then
        return ""
    end
    local ends = {}
    while path and (path.raw_length or 0) > 0 do
        ends[#ends + 1] = path.raw_length
        path = path.previous
    end
    local pieces = {}
    local start = 1
    for index = #ends, 1, -1 do
        local finish = ends[index]
        pieces[#pieces + 1] = raw:sub(start, finish)
        start = finish + 1
    end
    return table.concat(pieces, " ")
end

local candidate_display_meta = {
    __index = function(item, key)
        if key == "segmented" then
            local value = segmented_from_path(item._raw, item.path)
            rawset(item, key, value)
            return value
        end
    end
}

local function evaluate_state(item)
    local eos_score = logp(item.prev2, item.prev1, EOS)
    local ending_adjustment = eos_score - path_isolation_penalty(item) +
        (item.code_score or 0.0)
    -- Code-conditioned rare-character relief is a ranking heuristic, just
    -- like the canonical-code and supplement priors.  Confidence keeps the
    -- legacy text-only isolation term so the heuristic cannot manufacture a
    -- high-share early commit.
    local confidence_ending_adjustment = eos_score - isolation_penalty(item.text)
    local confidence_score = (item.mass_score or item.score) + confidence_ending_adjustment
    local direct = learning.candidate_is_direct(item)
    local personalization = math.min(ranking_prior.personalized_early_commit_cap,
        ranking_prior.supplement_early_commit_contribution(item.supplement_score or 0) +
        (direct and 0 or (item.learning_early_commit_bonus or 0)))
    return {
        score = item.score + ending_adjustment - (direct and (item.learning_score or 0) or 0),
        confidence_score = confidence_score,
        early_commit_confidence_score = confidence_score + personalization,
        text = item.text,
        prev2 = item.prev2,
        prev1 = item.prev1,
        max_rank = math.max(1, item.max_rank or 1),
        supplement_score = item.supplement_score or 0.0,
        code_score = item.code_score or 0.0,
        learning_score = direct and 0 or (item.learning_score or 0),
        source_mask = item.source_mask or 0,
        direct_rank = item.direct_rank or math.huge,
        edge_count = item.edge_count or 0,
        path = item
    }
end

-- Partial tails are probability evidence, not menu candidates. Preserve the
-- exact confidence operation order, but do not compute unused ranking priors.
local function evaluate_evidence_state(item)
    local confidence_ending_adjustment = logp(item.prev2, item.prev1, EOS) - isolation_penalty(item.text)
    local base_confidence = (item.mass_score or item.score) + confidence_ending_adjustment
    local personalization = math.min(ranking_prior.personalized_early_commit_cap,
        ranking_prior.supplement_early_commit_contribution(item.supplement_score or 0) +
        (learning.candidate_is_direct(item) and 0 or (item.learning_early_commit_bonus or 0)))
    return {text=item.text, path=item, confidence_score=base_confidence,
        early_commit_confidence_score=base_confidence + personalization}
end

local function add_early_commit_pool_candidate(pool, pool_index, candidate)
    if not candidate.text or candidate.text == "" then
        return
    end
    local raw_length = candidate.path and candidate.path.raw_length or 0
    local boundary = pool_index[raw_length]
    if not boundary then
        boundary = {}
        pool_index[raw_length] = boundary
    end
    local position = boundary[candidate.text]
    if not position then
        pool[#pool + 1] = candidate
        boundary[candidate.text] = #pool
        return
    end
    local previous = pool[position]
    local combined = logsumexp(previous.confidence_score, candidate.confidence_score)
    local combined_early = logsumexp(ranking_prior.early_confidence(previous), ranking_prior.early_confidence(candidate))
    -- Copy only on a collision: completed candidates also belong to the menu
    -- and must not have their probability mass changed by dropped-tail merges.
    local best = ranking_prior.early_confidence(candidate) > ranking_prior.early_confidence(previous) and candidate or previous
    pool[position] = {text=best.text, confidence_score=combined,
        early_commit_confidence_score=combined_early, path=best.path}
end

-- Per-(text prefix, raw boundary) evidence, mirroring
-- SentenceInputDecoder.BuildPrefixEvidence. Boundary mass is counted once per
-- candidate and raw boundary so negligible crossing paths cannot veto an
-- otherwise closed boundary.
local function build_prefix_evidence(pool)
    if #pool == 0 then return {} end
    local base_max, early_max = pool[1].confidence_score or pool[1].score, ranking_prior.early_confidence(pool[1])
    for i = 2, #pool do
        base_max = math.max(base_max, pool[i].confidence_score or pool[i].score)
        early_max = math.max(early_max, ranking_prior.early_confidence(pool[i]))
    end
    local base_total, early_total = 0, 0
    local mass_by_boundary, order, base_boundary_mass = {}, {}, {}
    for i = 1, #pool do
        local item = pool[i]
        local base_weight = math.exp((item.confidence_score or item.score) - base_max)
        local early_weight = math.exp(ranking_prior.early_confidence(item) - early_max)
        base_total = base_total + base_weight
        early_total = early_total + early_weight
        local state = item.path
        while state do
            local prefix_text = state.text
            if prefix_text == nil then
                local text_length = state.text_length or 0
                prefix_text = text_length > 0 and item.text:sub(1, text_length) or ""
            end
            if prefix_text ~= "" and #prefix_text <= #item.text then
                local boundary = mass_by_boundary[state.raw_length]
                if not boundary then boundary = {}; mass_by_boundary[state.raw_length] = boundary end
                local entry = boundary[prefix_text]
                if not entry then
                    entry = {text=prefix_text,raw_length=state.raw_length,base_weight=0.0,early_weight=0.0,
                        text_char_count=state.text_char_count or utf_length(prefix_text)}
                    boundary[prefix_text] = entry; order[#order + 1] = entry
                end
                entry.base_weight = entry.base_weight + base_weight
                entry.early_weight = entry.early_weight + early_weight
                base_boundary_mass[state.raw_length] = (base_boundary_mass[state.raw_length] or 0) + base_weight
            end
            state = state.previous
        end
    end
    if base_total <= 0 or early_total <= 0 then return {} end
    for i = 1, #order do
        local entry = order[i]
        local boundary_share = (base_boundary_mass[entry.raw_length] or 0) / base_total
        entry.share = entry.early_weight / early_total
        entry.base_share = entry.base_weight / base_total
        entry.boundary_share = boundary_share
        entry.boundary_closed = boundary_share >= early_commit_closed_boundary_share
        entry.base_weight, entry.early_weight = nil, nil
    end
    order._by_boundary = mass_by_boundary
    return order
end

local function has_low_confidence_completed_generation(candidates)
    if #candidates == 0 then
        return false
    end
    local max_score = candidates[1].confidence_score or candidates[1].score
    for i = 2, #candidates do
        local score = candidates[i].confidence_score or candidates[i].score
        if score > max_score then
            max_score = score
        end
    end
    local total = 0
    for i = 1, #candidates do
        total = total + math.exp((candidates[i].confidence_score or candidates[i].score) - max_score)
    end
    return total > 0 and 1.0 / total < early_commit_minimum_share
end

local function incomplete_code_tail(tail)
    if tail == "" or not tail:match("^[A-Za-z]+$") or
        not lexicon_state.proper_code_prefixes[tail] then
        return false
    end
    return #tail < 2 or lexicon_state.codes[tail] == nil
end

local function truncated_early_commit_evidence()
    return {
        prefixes = {},
        proposal = "",
        proposal_share = 0.0,
        raw_lengths = {},
        neutral_incomplete_tail = false,
        merged_incomplete_tail = false,
        neutral_low_confidence = false,
        confidence_truncated = true
    }
end

local function build_early_commit_evidence(
    raw, states, completed, completed_truncated, required_text_prefix)
    performance.early_evidence_builds = performance.early_evidence_builds + 1
    -- Preserve retained mass for the strong-truncated policy. The commit layer
    -- still requires model-only strong evidence and never lets personalization
    -- turn truncated evidence into strong evidence.
    local pool = {}
    local pool_index = {}
    local visible = {}
    for i = 1, #completed do
        local candidate = completed[i]
        if candidate.text and candidate.text ~= "" and
            (required_text_prefix == "" or
             candidate.text:sub(1, #required_text_prefix) == required_text_prefix) then
            visible[#visible + 1] = candidate
            add_early_commit_pool_candidate(pool, pool_index, candidate)
        end
    end

    local truncated = completed_truncated or false
    local merged_incomplete_tail = false
    local maximum_tail_length = math.min(lexicon_state.max_code_len - 1, #raw - 1)
    for tail_length = 1, maximum_tail_length do
        local consumed_length = #raw - tail_length
        local tail = raw:sub(consumed_length + 1)
        if incomplete_code_tail(tail) and states[consumed_length] then
            local partial = dedup_limit(
                states[consumed_length], beam_limit_at(consumed_length))
            states[consumed_length] = partial
            local added = false
            for i = 1, #partial do
                local candidate = evaluate_evidence_state(partial[i])
                if candidate.text and candidate.text ~= "" and
                    (required_text_prefix == "" or
                     candidate.text:sub(1, #required_text_prefix) == required_text_prefix) then
                    add_early_commit_pool_candidate(pool, pool_index, candidate)
                    added = true
                end
            end
            if added then
                merged_incomplete_tail = true
                truncated = truncated or (partial._truncated or false)
            end
        end
    end

    local prefixes = build_prefix_evidence(pool)

    local proposal = ""
    local proposal_share = 0.0
    local proposal_raw_length = 0
    local proposal_chars = 0
    local raw_lengths = {}
    for i = 1, #prefixes do
        local prefix = prefixes[i]
        if prefix.boundary_closed then
            local current = raw_lengths[prefix.text]
            if not current or prefix.share > current.share or
                (prefix.share == current.share and
                 prefix.raw_length < current.raw_length) then
                raw_lengths[prefix.text] = prefix
            end
            if prefix.share >= early_commit_minimum_share then
                local replace = proposal == ""
                if not replace then
                    local prefix_chars = prefix.text_char_count or utf_length(prefix.text)
                    if prefix_chars ~= proposal_chars then
                        replace = prefix_chars > proposal_chars
                    elseif prefix.share ~= proposal_share then
                        replace = prefix.share > proposal_share
                    else
                        replace = prefix.raw_length < proposal_raw_length
                    end
                end
                if replace then
                    proposal = prefix.text
                    proposal_share = prefix.share
                    proposal_raw_length = prefix.raw_length
                    proposal_chars = prefix.text_char_count or utf_length(prefix.text)
                end
            end
        end
    end
    local raw_length_values = {}
    for text, prefix in pairs(raw_lengths) do
        raw_length_values[text] = prefix.raw_length
    end

    return {
        prefixes = prefixes,
        proposal = proposal,
        proposal_share = proposal_share,
        raw_lengths = raw_length_values,
        neutral_incomplete_tail = #visible == 0 and merged_incomplete_tail,
        merged_incomplete_tail = merged_incomplete_tail,
        neutral_low_confidence = has_low_confidence_completed_generation(visible),
        confidence_truncated = truncated
    }
end

-- With the duplicate single-character option enabled, segmented candidate
-- lists compete by score; whole-input single edges keep lexicon-rank order.
local function prefer_score_over_lexicon_rank(values)
    if not active_allow_duplicate_single then
        return false
    end
    for i = 1, #values do
        local path = values[i].path
        if path and path.previous and (path.previous.raw_length or 0) > 0 then
            return true
        end
    end
    return false
end

function learning.apply_fusion_ordering(raw, candidates)
    if #candidates < 2 then return candidates end
    local has_direct = false
    for i = 1, #candidates do
        if learning.candidate_is_direct(candidates[i]) then has_direct = true; break end
    end
    if not has_direct then return candidates end
    local base, direct, composed = {}, {}, {}
    for i = 1, #candidates do
        local item = candidates[i]
        if base[item.text] == nil then base[item.text] = i end
        if learning.candidate_is_direct(item) then direct[#direct + 1] = item
        else composed[#composed + 1] = item end
    end
    table.sort(direct, function(a, b)
        local ar, br = a.direct_rank or math.huge, b.direct_rank or math.huge
        if ar ~= br then return ar < br end
        return (base[a.text] or math.huge) < (base[b.text] or math.huge)
    end)
    if #direct == 0 or #composed == 0 then
        if #composed == 0 then
            for i = 1, #direct do candidates[i] = direct[i] end
        end
        return candidates
    end
    -- Private to this merge: no preference can survive a learning/schema epoch.
    -- Zero is a cached score, not a miss. Avoid constructing/hashing each pair
    -- repeatedly while its source prefix is promoted.
    local pair_scores = {}
    local function pair_score(d, c)
        if not learning_index or learning_mode == "" then return 0 end
        local key = (d - 1) * #composed + c
        local score = pair_scores[key]
        if score == nil then
            score = learning.fusion_score(learning_index, learning_mode, raw, direct[d].text, composed[c].text)
            pair_scores[key] = score
        end
        return score
    end
    local merged, di, ci = {}, 1, 1
    while di <= #direct and ci <= #composed do
        local d, c = direct[di], composed[ci]
        local direct_prefix, composed_prefix = 0, 0
        for i = di, #direct do
            direct_prefix = math.max(direct_prefix,
                pair_score(i, ci))
        end
        for i = ci, #composed do
            composed_prefix = math.max(composed_prefix,
                -pair_score(di, i))
        end
        local take_direct
        if direct_prefix > 0 or composed_prefix > 0 then
            if math.abs(direct_prefix - composed_prefix) > 1e-12 then
                take_direct = direct_prefix > composed_prefix
            else
                take_direct = (base[d.text] or math.huge) < (base[c.text] or math.huge)
            end
        else
            take_direct = (base[d.text] or math.huge) < (base[c.text] or math.huge)
        end
        if take_direct then merged[#merged + 1] = direct[di]; di = di + 1
        else merged[#merged + 1] = composed[ci]; ci = ci + 1 end
    end
    while di <= #direct do merged[#merged + 1] = direct[di]; di = di + 1 end
    while ci <= #composed do merged[#merged + 1] = composed[ci]; ci = ci + 1 end
    for i = 1, #merged do candidates[i] = merged[i] end
    return candidates
end

local function emit(raw, states, length, include_early_commit, required_text_prefix)
    local completed = dedup_limit(states[length], beam_limit_at(length))
    states[length] = completed
    local all_candidates = {}
    for i = 1, #completed do
        all_candidates[i] = evaluate_state(completed[i])
    end
    local better
    if not ensure_kn() then
        better = state_better_no_model
    else
        better = prefer_score_over_lexicon_rank(all_candidates)
            and state_better_score_first
            or state_better_rank_first
    end
    for _, item in ipairs(all_candidates) do
        if (item.learning_score or 0) > 0 then better = state_better_score_first; break end
    end
    local result = select_exact_top(all_candidates, candidate_limit, better)
    if #result > 1 and ranking_prior.lexical_model and
        ranking_prior.lexical_prior_weight > 0.0 and ensure_kn() then
        -- Rerank only the first five displayed candidates. Character LM
        -- remains responsible for candidate generation; the word filter
        -- supplies a small, non-overlapping real-word vote at the end.
        local lexical_lookup_cache = {}
        for i = 1, math.min(#result, ranking_prior.lexical_candidate_limit) do
            local lexical_score = ranking_prior.lexical.score(
                ranking_prior.lexical_model, result[i].text, lexical_lookup_cache) *
                ranking_prior.lexical_prior_weight
            result[i].lexical_score = lexical_score
            result[i].score = result[i].score + lexical_score
        end
        table.sort(result, better)
    end
    learning.apply_fusion_ordering(raw, result)
    result.learning_affected = learning_affected
    result._completed_truncated = completed._truncated or false
    -- Display Top-K is not the probability pool. Retain the scored beam for
    -- evidence upgrades and empty-code confidence, including off-menu outputs.
    result._confidence_candidates = all_candidates
    for i = 1, #result do
        result[i]._raw = raw
        setmetatable(result[i], candidate_display_meta)
    end
    result.early_commit_evidence = {
        prefixes = {},
        proposal = "",
        proposal_share = 0.0,
        raw_lengths = {},
        neutral_incomplete_tail = false,
        merged_incomplete_tail = false,
        neutral_low_confidence = false,
        confidence_truncated = completed._truncated or false
    }
    if include_early_commit then
        result.early_commit_evidence = build_early_commit_evidence(
            raw,
            states,
            all_candidates,
            completed._truncated or false,
            required_text_prefix or "")
    end
    return result
end

local function prefix_evidence_equal(left, right)
    local left_prefixes = left.prefixes or {}
    local right_prefixes = right.prefixes or {}
    if #left_prefixes ~= #right_prefixes then
        return false
    end
    local right_by_key = {}
    for i = 1, #right_prefixes do
        right_by_key[right_prefixes[i].text .. state_separator ..
            tostring(right_prefixes[i].raw_length)] = right_prefixes[i]
    end
    for i = 1, #left_prefixes do
        local item = left_prefixes[i]
        local other = right_by_key[item.text .. state_separator ..
            tostring(item.raw_length)]
        if not other or other.boundary_closed ~= item.boundary_closed or
            math.abs((other.share or 0.0) - (item.share or 0.0)) > 1e-9 or
            math.abs((other.base_share or other.share or 0.0) - (item.base_share or item.share or 0.0)) > 1e-9 or
            math.abs((other.boundary_share or 0.0) - (item.boundary_share or 0.0)) > 1e-9 then
            return false
        end
    end
    if (left.merged_incomplete_tail or false) ~= (right.merged_incomplete_tail or false) or
        (left.neutral_low_confidence or false) ~= (right.neutral_low_confidence or false) then
        return false
    end
    return true
end

-- Compare behavior-bearing data, not cache implementation details. Off-menu
-- confidence and learning inhibition are just as observable as display Top-K.
local results_equal
do
local function paths_equal(left, right)
    while left and right do
        if left.raw_length ~= right.raw_length or left.text_length ~= right.text_length or
            left.text ~= right.text or left.prev2 ~= right.prev2 or left.prev1 ~= right.prev1 or
            left.score ~= right.score or
            (left.mass_score or left.score) ~= (right.mass_score or right.score) or
            (left.learning_score or 0) ~= (right.learning_score or 0) or
            (left.learning_potential or 0) ~= (right.learning_potential or 0) or
            (left.code_score or 0) ~= (right.code_score or 0) or
            (left.max_rank or 1) ~= (right.max_rank or 1) or
            (left.edge_count or 0) ~= (right.edge_count or 0) or
            (left.edge_primary_single or false) ~= (right.edge_primary_single or false) or
            (left.edge_code_length or 0) ~= (right.edge_code_length or 0) then
            return false
        end
        left, right = left.previous, right.previous
    end
    return left == nil and right == nil
end

local function candidates_equal(left, right, display)
    if #left ~= #right then return false end
    for i = 1, #left do
        local a, b = left[i], right[i]
        if a.text ~= b.text or (display and a.segmented ~= b.segmented) or
            a.score ~= b.score or
            (a.confidence_score or a.score) ~= (b.confidence_score or b.score) or
            ranking_prior.early_confidence(a) ~= ranking_prior.early_confidence(b) or
            (a.supplement_score or 0) ~= (b.supplement_score or 0) or
            (a.code_score or 0) ~= (b.code_score or 0) or
            (a.lexical_score or 0) ~= (b.lexical_score or 0) or
            (a.learning_score or 0) ~= (b.learning_score or 0) or
            (a.max_rank or 1) ~= (b.max_rank or 1) or
            (a.edge_count or 0) ~= (b.edge_count or 0) or
            not paths_equal(a.path, b.path) then
            return false
        end
    end
    return true
end

results_equal = function(left, right)
    if (left.learning_affected or false) ~= (right.learning_affected or false) or
        (left._completed_truncated or false) ~= (right._completed_truncated or false) or
        not candidates_equal(left, right, true) or
        not candidates_equal(left._confidence_candidates or {}, right._confidence_candidates or {}, false) then
        return false
    end
    local left_evidence = left.early_commit_evidence or {}
    local right_evidence = right.early_commit_evidence or {}
    if (left_evidence.proposal or "") ~= (right_evidence.proposal or "") or
        (left_evidence.proposal_share or 0.0) ~= (right_evidence.proposal_share or 0.0) or
        (left_evidence.confidence_truncated or false) ~= (right_evidence.confidence_truncated or false) or
        (left_evidence.neutral_incomplete_tail or false) ~= (right_evidence.neutral_incomplete_tail or false) or
        not prefix_evidence_equal(left_evidence, right_evidence) then
        return false
    end
    local left_raw_lengths = left_evidence.raw_lengths or {}
    local right_raw_lengths = right_evidence.raw_lengths or {}
    for text, raw_length in pairs(left_raw_lengths) do
        if right_raw_lengths[text] ~= raw_length then return false end
    end
    for text, raw_length in pairs(right_raw_lengths) do
        if left_raw_lengths[text] ~= raw_length then return false end
    end
    return true
end

end -- result-comparison helpers

-- Resolve one already-confirmed lattice edge from its recorded raw/text
-- boundaries.  Locked-prefix replay must rebuild every ranking feature that
-- ordinary expansion attached to that edge; otherwise adding a suffix would
-- silently change scores or rare-character protection at the lock boundary.
ranking_prior.resolve_locked_edge = function(raw, raw_start, raw_end, text)
    for i = 1, #lexicon_state.lengths do
        local code_length = lexicon_state.lengths[i]
        local code_end = raw_start + code_length
        if code_end <= raw_end then
            local candidates = lexicon_state.codes[raw:sub(raw_start + 1, code_end)]
            if candidates then
                local selected_rank, consumed_end = parse_selector(raw, code_end)
                if consumed_end == raw_end then
                    if selected_rank > 0 then
                        local candidate = candidates[selected_rank]
                        if candidate and candidate.t == text then
                            return candidate, selected_rank, code_length
                        end
                    else
                        -- A whole-input menu can lock a non-first candidate
                        -- without writing a selector into the raw stream.
                        for candidate_index = 1, #candidates do
                            if candidates[candidate_index].t == text then
                                return candidates[candidate_index], 0, code_length
                            end
                        end
                    end
                end
            end
        end
    end
    return nil
end

local function decode_full(raw_code, include_early_commit, required_text_prefix)
    ensure_lexicon(nil)
    local raw = normalize(raw_code)
    if raw == "" or not has_letter(raw) then
        return {}
    end
    local length = #raw
    local started = os.clock()
    local previous_affected = learning_affected
    learning_affected = false
    local states = new_states(length)
    expand_range(raw, states, 0, length)
    local result = emit(
        raw,
        states,
        length,
        include_early_commit or false,
        required_text_prefix or "")
    record_decode(started)
    learning_affected = previous_affected
    return result
end

local function decode(raw_code, include_early_commit, required_text_prefix, locked)
    ensure_lexicon(nil)
    learning_affected = decode_cache.learning_affected or false
    local raw = normalize(raw_code)
    required_text_prefix = required_text_prefix or ""
    if locked then
        local prefix = normalize(locked.raw)
        if prefix == "" or raw:sub(1, #prefix) ~= prefix then return {} end
        local started = os.clock()
        local cache = locked_decode_cache
        local compatible = cache.prefix == prefix and cache.text == locked.text and
            cache.boundaries == locked.boundaries and cache.allow_duplicate == active_allow_duplicate_single
        learning_affected = compatible and cache.learning_affected or false
        if compatible and cache.raw == raw and cache.result and
            (not include_early_commit or (cache.includes_early_commit and cache.required == required_text_prefix)) then
            return cache.result
        end
        local states = compatible and cache.states or nil
        if states and cache.raw == raw then
            if cache.result then
                cache.result.early_commit_evidence = build_early_commit_evidence(raw, states,
                    cache.result._confidence_candidates, cache.result._completed_truncated, required_text_prefix)
                cache.includes_early_commit, cache.required = true, required_text_prefix
                record_decode(started)
                return cache.result
            end
        elseif states and #raw > #cache.raw and raw:sub(1, #cache.raw) == cache.raw then
            local old_n = #cache.raw
            for i = old_n + 1, #raw do states[i] = new_bucket() end
            local max_consume = lexicon_state.max_code_len + trailing_selector_span(raw)
            expand_range(raw, states, math.max(#prefix, old_n + 1 - max_consume), #raw, old_n)
        elseif states and #raw < #cache.raw and cache.raw:sub(1, #raw) == raw then
            for i = #raw + 1, #cache.raw do states[i] = nil end
        else
            states = nil
        end
        if not states then
            learning_affected = false
            states = new_states(#raw)
            -- Reconstruct confirmed boundaries and score their text as context,
            -- without re-searching or allowing an edge to cross the lock.
            local seed = { text = "", prev2 = BOS, prev1 = BOS, score = 0, mass_score = 0,
                max_rank = 1, supplement_state = 1, supplement_score = 0,
                code_score = 0,
                raw_length = 0, text_length = 0, text_char_count = 0, edge_count = 0 }
            for raw_boundary, text_boundary in locked.boundaries:gmatch("(%d+),(%d+);") do
                local r, t = tonumber(raw_boundary), tonumber(text_boundary)
                local edge_text = locked.text:sub(seed.text_length + 1, t)
                local candidate, selected_rank, code_length = ranking_prior.resolve_locked_edge(
                    raw, seed.raw_length, r, edge_text)
                -- Text-only Backspace can shorten an already confirmed
                -- multi-character edge while deliberately retaining its raw
                -- boundary (for example 团圆/cd -> 团/cd).  Such an opaque
                -- lock was valid before ranking priors existed, so replay it
                -- with legacy-neutral code evidence instead of rejecting the
                -- whole suffix. Exact surviving edges still recover their
                -- canonical-code and rare-character metadata.
                local chars = candidate and candidate_chars(candidate) or
                    utf_chars(edge_text)
                local protect_primary_rare =
                    ranking_prior.canonical_isolation_factor < 1.0
                local item = { text = locked.text:sub(1, t), previous = seed, edge_chars = chars,
                    raw_length = r, text_length = t, edge_count = seed.edge_count + 1,
                    text_char_count = (utf8 and utf8.len and seed.text_char_count) and
                        seed.text_char_count + #chars or nil,
                    prev2 = seed.prev2, prev1 = seed.prev1, score = seed.score,
                    supplement_state = seed.supplement_state,
                    supplement_score = seed.supplement_score,
                    code_score = seed.code_score or 0,
                    -- A confirmed prefix keeps the historical neutral rank;
                    -- the user's lock, not its former menu rank, is decisive.
                    max_rank = 1,
                    edge_primary_single = candidate and protect_primary_rare and #chars == 1 and
                        (candidate.primary_single or selected_rank > 0),
                    edge_code_length = candidate and protect_primary_rare and code_length or nil }
                for _, ch in ipairs(chars) do
                    item.score = item.score + logp(item.prev2, item.prev1, ch) + emitted_character_reward
                    if has_supplements then
                        local reward
                        item.supplement_state, reward = supplement.advance(supplement_matcher, item.supplement_state, ch)
                        item.score = item.score + reward
                        item.supplement_score = item.supplement_score + reward
                    end
                    item.prev2, item.prev1 = item.prev1, ch
                end
                local code_reward_added = 0.0
                if candidate and ensure_kn() and ranking_prior.canonical_code_reward > 0.0 and
                    selected_rank == 0 and candidate.primary_single and #chars == 1 then
                    code_reward_added = ranking_prior.canonical_code_reward * code_length
                    item.code_score = item.code_score + code_reward_added
                end
                -- Preserve the original locked-replay operation order. Shape
                -- evidence is tracked separately and enters only final rank.
                item.mass_score = item.score - item.supplement_score -
                    (seed.learning_score or 0)
                local learned, potential, learning_early_bonus = learning.reward(
                    learning_index, learning_mode, raw, item.text, r, seed)
                item.learning_score, item.learning_potential = learned, potential
                item.learning_early_commit_bonus = learning_early_bonus
                item.score = item.score + learned - (seed.learning_score or 0)
                if learned > 0 or potential > 0 then learning_affected = true end
                seed = item
            end
            if seed.raw_length ~= #prefix or seed.text ~= locked.text then return {} end
            states[0] = new_bucket()
            add_state(states[#prefix], seed)
            expand_range(raw, states, #prefix, #raw)
        end
        local result = emit(raw, states, #raw, include_early_commit or false, required_text_prefix)
        locked_decode_cache = {prefix=prefix, text=locked.text, boundaries=locked.boundaries,
            allow_duplicate=active_allow_duplicate_single, raw=raw, states=states, result=result,
            includes_early_commit=include_early_commit or false, required=required_text_prefix,
            learning_affected=result.learning_affected or false}
        record_decode(started)
        return result
    end
    if raw == "" or not has_letter(raw) then
        decode_cache.raw = raw
        decode_cache.states = nil
        decode_cache.result = {}
        decode_cache.includes_early_commit = include_early_commit or false
        decode_cache.required_text_prefix = required_text_prefix
        decode_cache.allow_duplicate = active_allow_duplicate_single
        return decode_cache.result
    end
    if decode_cache.raw == raw and decode_cache.result and
        decode_cache.allow_duplicate == active_allow_duplicate_single and
        (not include_early_commit or
         (decode_cache.includes_early_commit and
          decode_cache.required_text_prefix == required_text_prefix)) then
        return decode_cache.result
    end

    local length = #raw
    local started = os.clock()
    local states = nil
    local old_raw = decode_cache.raw
    local old_states = decode_cache.states
    if old_states and old_raw == raw and
        decode_cache.allow_duplicate == active_allow_duplicate_single then
        -- The translator normally cached this exact composition without
        -- confidence metadata. The processor may immediately request the same
        -- lattice with early-commit evidence before accepting the next key.
        -- Reuse the lattice; rebuilding a long composition here caused the
        -- visible pause after roughly forty uncommitted keys.
        -- Only evidence is missing/different. Keep final scoring, Top-K and
        -- lazily generated display strings for this exact generation.
        local result = decode_cache.result
        if result then
            result.early_commit_evidence = build_early_commit_evidence(
                raw, old_states, result._confidence_candidates,
                result._completed_truncated,
                required_text_prefix)
            decode_cache.includes_early_commit = true
            decode_cache.required_text_prefix = required_text_prefix
            record_decode(started)
            return result
        end
        states = old_states
    elseif old_states and type(old_raw) == "string" and old_raw ~= "" then
        local old_n = #old_raw
        -- Whole-input rewards/eligibility depend on the *current* end of input.
        -- TXT tables may have more than four letters; a rank selector can also
        -- extend one whole-input edge. Rebuild while either generation could
        -- be such an edge, including after deleting part of a numeric selector.
        local max_code = lexicon_state.max_code_len
        if old_n <= max_code + trailing_selector_span(old_raw) or
            length <= max_code + trailing_selector_span(raw) then
            states = nil
        elseif length > old_n and raw:sub(1, old_n) == old_raw then
            local max_consume = lexicon_state.max_code_len + trailing_selector_span(raw)
            local from_pos = math.max(0, old_n + 1 - max_consume)
            states = old_states
            for index = old_n + 1, length do
                states[index] = new_bucket()
            end
            expand_range(raw, states, from_pos, length, old_n)
        elseif length < old_n and old_raw:sub(1, length) == raw then
            states = old_states
            for index = length + 1, old_n do
                states[index] = nil
            end
        end
    end

    if not states then
        learning_affected = false
        states = new_states(length)
        expand_range(raw, states, 0, length)
    end

    local result = emit(
        raw,
        states,
        length,
        include_early_commit or false,
        required_text_prefix)
    decode_cache.raw = raw
    decode_cache.states = states
    decode_cache.result = result
    decode_cache.learning_affected = result.learning_affected or false
    decode_cache.includes_early_commit = include_early_commit or false
    decode_cache.required_text_prefix = required_text_prefix
    decode_cache.allow_duplicate = active_allow_duplicate_single
    record_decode(started)
    return result
end

-- A model read can fail after push_input has already changed the composition.
-- Retry the entire decode with one coherent no-model scoring policy, never just
-- substitute zero for a failed probability in a partially scored lattice.
-- Non-model/programming errors still propagate normally.
local function guarded_decode(operation)
    return function(...)
        local ok, result = pcall(operation, ...)
        if ok then return result end
        if result ~= model_failure then error(result, 0) end
        kn_load_error = "runtime n-gram failure: " .. model_failure.reason
        close_model()
        model_generation = model_generation + 1
        clear_model_dependent_caches()
        if log and type(log.error) == "function" then
            pcall(log.error, "tiger_sentence: " .. kn_load_error .. "; using no-model fallback")
        end
        return operation(...)
    end
end

decode = guarded_decode(decode)
decode_full = guarded_decode(decode_full)

local function trim_segmented_after_raw_prefix(segmented, raw_prefix_length)
    if not segmented or segmented == "" or raw_prefix_length <= 0 then
        return segmented or ""
    end
    local raw_count = 0
    local index = 1
    while index <= #segmented and raw_count < raw_prefix_length do
        if segmented:sub(index, index) ~= " " then
            raw_count = raw_count + 1
        end
        index = index + 1
    end
    while index <= #segmented and segmented:sub(index, index) == " " do
        index = index + 1
    end
    return index <= #segmented and segmented:sub(index) or ""
end

local function find_raw_length_for_text(text, candidates)
    local text_length = #text
    for i = 1, #candidates do
        local candidate = candidates[i]
        if candidate.text:sub(1, text_length) == text then
            local state = candidate.path
            while state do
                if state.text_length == text_length then
                    return state.raw_length
                end
                state = state.previous
            end
        end
    end
    return 0
end

-- Independent per-(text prefix, raw boundary) trackers, mirroring
-- InputMethodEngine.TryAutoCommitSentencePrefix.
local function find_prefix_evidence(prefixes, text, raw_length)
    if prefixes._by_boundary then
        local boundary = prefixes._by_boundary[raw_length]
        return boundary and boundary[text] or nil
    end
    -- Plain arrays remain supported for external fixtures and old callers.
    for i = 1, #prefixes do
        if prefixes[i].text == text and prefixes[i].raw_length == raw_length then
            return prefixes[i]
        end
    end
    return nil
end

local function common_text_prefix(left, right)
    return utf_common_prefix(left, right)
end

local function prefix_extends(left, right)
    return left:sub(1, #right) == right or right:sub(1, #left) == left
end

local function prefix_contradicted(tracker, prefixes)
    if #prefixes == 0 then
        return false
    end
    local self = find_prefix_evidence(prefixes, tracker.text, tracker.raw_length)
    local self_share = self and self.share or 0.0
    for i = 1, #prefixes do
        local prefix = prefixes[i]
        if prefix.text ~= "" and prefix.text ~= tracker.text and
            not prefix_extends(prefix.text, tracker.text) then
            local shared_stem = common_text_prefix(prefix.text, tracker.text)
            if shared_stem ~= "" and #shared_stem < #tracker.text then
                if self == nil or prefix.share > self_share then
                    return true
                end
            end
        end
    end
    return false
end

local function prefix_belongs_to_visible(prefix, visible)
    local index = visible._prefix_membership
    if not index then
        index = {}
        for i = 1, #visible do
            local candidate = visible[i]
            local state = candidate.path
            while candidate.text and state do
                local text = state.text
                if text == nil and type(state.text_length) == "number" and
                    state.text_length >= 0 and state.text_length <= #candidate.text then
                    text = candidate.text:sub(1, state.text_length)
                end
                if text and candidate.text:sub(1, #text) == text then
                    local boundary = index[state.raw_length]
                    if not boundary then boundary = {}; index[state.raw_length] = boundary end
                    boundary[text] = true
                end
                state = state.previous
            end
        end
        -- A decoded generation has immutable text/path boundaries. Display
        -- materialization only adds formatting fields, never changes membership.
        visible._prefix_membership = index
    end
    local boundary = index[prefix.raw_length]
    return boundary and boundary[prefix.text] or false
end

local function retain_trackers_without_counting(trackers, prefixes, reset_maturity)
    local next_trackers = {}
    for key, tracker in pairs(trackers) do
        local current = find_prefix_evidence(prefixes, tracker.text, tracker.raw_length)
        if current and not prefix_contradicted(tracker, prefixes) then
            tracker.gap_count = tracker.gap_count + 1
            if tracker.gap_count <= early_commit_maximum_neutral_gap then
                tracker.last_share = current.share
                if reset_maturity then
                    tracker.evidence_count = 0
                    tracker.strong_count = 0
                end
                next_trackers[key] = tracker
            end
        end
    end
    return next_trackers
end

local function tracker_better(left, right)
    local left_chars = left.text_char_count or utf_length(left.text)
    local right_chars = right.text_char_count or utf_length(right.text)
    if left_chars ~= right_chars then
        return left_chars > right_chars
    end
    if left.last_share ~= right.last_share then
        return left.last_share > right.last_share
    end
    return left.raw_length < right.raw_length
end

-- Retained lookahead must be compared after the same number of emitted text
-- elements, not after the same raw boundary. For example, committing 有 at nv
-- must also wait until the one-element alternative 郁 at nvt has K raw keys of
-- suffix evidence. A second edge such as nv|tah must not delay a one-element
-- commit, because it has already emitted two text elements.
local function competing_boundary_end(
    raw, committed_raw_length, proposed_raw_length, target_text_elements)
    if type(raw) ~= "string" or proposed_raw_length <= committed_raw_length or
        committed_raw_length < 0 or proposed_raw_length > #raw or
        type(target_text_elements) ~= "number" or target_text_elements < 1 then
        return proposed_raw_length
    end
    local reachable = {[committed_raw_length] = {[0] = true}}
    local furthest = proposed_raw_length
    for start = committed_raw_length, #raw - 1 do
        local counts = reachable[start]
        if counts then
            local maximum = math.min(lexicon_state.max_code_len, #raw - start)
            for length = 1, maximum do
                local finish = start + length
                local entries = lexicon_state.codes[raw:sub(start + 1, finish)]
                if entries then
                    for count in pairs(counts) do
                        for index = 1, #entries do
                            local next_count = count + utf_length(entries[index].t)
                            if next_count == target_text_elements then
                                furthest = math.max(furthest, finish)
                            elseif next_count < target_text_elements then
                                local next_counts = reachable[finish]
                                if not next_counts then
                                    next_counts = {}
                                    reachable[finish] = next_counts
                                end
                                next_counts[next_count] = true
                            end
                        end
                    end
                end
            end
        end
    end
    return furthest
end

local function has_selection_suffix(raw)
    return raw and raw:find("[;'0-9]") ~= nil
end

local function implicit_rank_allowed(candidate, raw, continuation_after_auto_commit)
    if not continuation_after_auto_commit then
        return true
    end
    -- Segmented paths already passed decoder eligibility. Do not discard
    -- legal duplicate singles when empty-code commit fixes an earlier prefix.
    local previous = candidate.path and candidate.path.previous
    return has_selection_suffix(raw) or (candidate.max_rank or 1) <= 1 or
        (active_allow_duplicate_single and previous and (previous.text or "") ~= "")
end

local function strong_empty_code_candidate(candidate, eligible, visible_top, pool_truncated)
    -- Confidence shares computed over a truncated pool are not trustworthy;
    -- Windows requires ConfidenceTruncated == false for the strong accept.
    if pool_truncated then
        return false
    end
    if not visible_top or candidate.text ~= visible_top.text then
        return false
    end
    local max_score = eligible[1].confidence_score or eligible[1].score
    for i = 2, #eligible do
        local score = eligible[i].confidence_score or eligible[i].score
        if score > max_score then
            max_score = score
        end
    end
    local total = 0
    local candidate_mass = 0
    for i = 1, #eligible do
        local mass = math.exp(
            (eligible[i].confidence_score or eligible[i].score) - max_score)
        total = total + mass
        if eligible[i] == candidate then
            candidate_mass = candidate_mass + mass
        end
    end
    return total > 0 and candidate_mass / total >= ranking_prior.empty_code_strong_share
end

-- Mirrors InputMethodEngine.GetEmptyCodeAutoCommitCandidate: accept exactly
-- one group-eligible candidate, or a group-eligible visible top whose
-- untruncated confidence share reaches the strong threshold.
local function capture_empty_code_candidate(full_before, committed_text, locked)
    local decoded = decode(full_before, false, committed_text, locked)
    if #decoded == 0 or decoded.learning_affected then
        return nil
    end
    local visible_top = decoded[1]
    local restrict = not has_selection_suffix(full_before)
    local function is_eligible(candidate)
        local previous = candidate.path and candidate.path.previous
        return not restrict or (candidate.max_rank or 1) <= 1 or
            (active_allow_duplicate_single and
             ((previous and (previous.text or "") ~= "") or utf_length(candidate.text) == 1))
    end
    -- Preserve the displayed choice, but assess its confidence against all
    -- group-eligible beam outputs rather than just the visible twenty.
    local first
    for i = 1, #decoded do
        if is_eligible(decoded[i]) then first = decoded[i]; break end
    end
    if not first then return nil end
    local eligible = {}
    for _, candidate in ipairs(decoded._confidence_candidates or decoded) do
        if is_eligible(candidate) then eligible[#eligible + 1] = candidate end
    end
    if not first.text or first.text == "" or
        first.text:sub(1, #committed_text) ~= committed_text or
        #first.text <= #committed_text then
        return nil
    end
    local pool_truncated =
        (decoded.early_commit_evidence or {}).confidence_truncated or false
    if #eligible > 1 and
        not strong_empty_code_candidate(first, eligible, visible_top, pool_truncated) then
        return nil
    end
    local previous = first.path and first.path.previous
    return {
        candidate_text = first.text,
        requires_uniqueness_check = #eligible == 1,
        committed_text = committed_text,
        base_raw_length = #full_before,
        last_segment_start = previous and previous.raw_length or 0
    }
end

local function cycle_candidate_highlight(context, step)
    if not context:has_menu() then return false end
    local composition = context.composition
    if not composition or composition:empty() then return false end
    local segment = composition:back()
    local menu = segment and segment.menu
    if not menu then return false end
    -- candidate_count() is only the materialized prefix of a lazy Rime menu.
    -- Our translator emits at most candidate_limit items: prepare that bounded
    -- list before deciding where cyclic navigation should wrap.
    local count = type(menu.prepare) == "function"
        and menu:prepare(candidate_limit) or menu:candidate_count()
    if not count or count <= 0 then return false end
    local selected = segment.selected_index or 0
    local target = (selected + step) % count
    -- Highlight changes only the active index. Context:select(), by contrast,
    -- selects the candidate and may commit a whole-composition sentence.
    if type(context.highlight) == "function" and context:highlight(target) then
        return true
    end
    -- Compatibility fallback for a librime build predating Context::Highlight.
    -- librime-lua exposes Segment.selected_index as a writable field.
    segment.selected_index = target
    return segment.selected_index == target
end

reset_decode_cache = function()
    locked_decode_cache = {}
    learning_affected = false
    decode_cache.raw = nil
    decode_cache.states = nil
    decode_cache.result = nil
    decode_cache.learning_affected = false
    decode_cache.includes_early_commit = false
    decode_cache.required_text_prefix = ""
    decode_cache.allow_duplicate = active_allow_duplicate_single
end

local function set_allow_duplicate_single(context)
    local allowed = true
    if context and type(context.get_option) == "function" then
        local ok, value = pcall(context.get_option, context, allow_duplicate_single_option)
        if ok and value == false then
            allowed = false
        end
    end
    if allowed ~= active_allow_duplicate_single then
        active_allow_duplicate_single = allowed
        reset_decode_cache()
    end
    return allowed
end

-- Replace the live composition with one atomic input mutation. clear() plus
-- push_input() emits an intermediate empty-composition notification that some
-- frontends render as a one-frame flash; assigning context.input triggers a
-- single change event carrying the final raw code. The set_input method hook
-- exists for tests; the clear+push fallback covers frontends whose context
-- does not accept direct input assignment.
-- The private leading marker keeps a text-only preedit alive in Rime. It is
-- never decoder input or candidate/preedit output.
local function buffered_text(context)
    return context:get_property(state_keys.buffered) or ""
end

local function live_input(context)
    local value = context.input or ""
    if buffered_text(context) ~= "" and value:sub(1, 1) == "~" then return value:sub(2) end
    return value
end

local function restore_composition_input(context, value)
    if buffered_text(context) ~= "" then value = "~" .. value end
    if context.input == value and buffered_text(context) ~= "" and
        type(context.refresh_non_confirmed_composition) == "function" then
        -- Text-only deletion changes the prefix but leaves raw input as "~".
        -- Rime otherwise reuses that segment's old menu/preedit translation.
        -- Invalidate the translation without clearing the live composition.
        if context:refresh_non_confirmed_composition() then return end
    end
    if type(context.set_input) == "function" then
        context:set_input(value)
        return
    end
    local ok = pcall(function()
        context.input = value
    end)
    if ok and context.input == value then
        return
    end
    context:clear()
    if value ~= "" then
        context:push_input(value)
    end
end

-- Rime uses a byte offset in the raw input, not an index in displayed text.
-- Old frontend/test contexts without caret_pos retain end-append behaviour.
local function input_caret(context)
    local length = #live_input(context)
    local caret = context.caret_pos
    if type(caret) ~= "number" then return length end
    if buffered_text(context) ~= "" then caret = caret - 1 end
    return math.max(0, math.min(length, math.floor(caret)))
end

local function submit_early(env, state, selected, commit)
    local context = env.engine.context
    if context:get_option("tiger_sentence_early_commit_to_preedit") or (state.buffered_text or "") ~= "" then
        state.buffered_text = (state.buffered_text or "") .. commit
        -- Confirmed text must never be resegmented. Keeping an opaque consumed
        -- raw boundary also lets Backspace edit inside a multi-character word.
        state.locks = {{raw=state.committed_raw, text=state.committed_text,
            boundaries=tostring(#state.committed_raw)..","..tostring(#state.committed_text)..";"}}
        save_sentence_state(context, state, env)
    else
        env.engine:commit_text(commit)
        learning_submit(env, selected, commit, commit)
    end
end

local function invalidate_edit_state(context, state, env, first_changed, full_length, deleted_tail)
    local previous_lock = active_lock(state)
    state.tab_pending = false
    state.trackers = {}
    state.last_seen_raw = ""
    state.empty_code_pending = nil
    -- Editing a locked but uncommitted range invalidates that lock and every
    -- subsequent one. Reaching its boundary by deletion also unlocks it.
    -- Never discard a lock for text already committed to the application.
    while active_lock(state) and #active_lock(state).raw > #state.committed_raw and
        (first_changed < #active_lock(state).raw or
         full_length <= #active_lock(state).raw) do
        table.remove(state.locks)
    end
    save_sentence_state(context, state, env)
    -- A trailing letter cannot change any earlier selector or locked edge.
    -- Keep the existing lattice only for the exact, still-active lock/raw
    -- generation. decode() can then shrink its buckets and rescore the end.
    -- Learning-affected generations retain the conservative rebuild: the
    -- cumulative inhibition flag can include an edge in the deleted tail.
    local cache = locked_decode_cache
    local lock = active_lock(state)
    local reuse_tail = deleted_tail and deleted_tail:match("^[a-z]$") and
        first_changed == full_length and lock and lock == previous_lock and
        cache.states and not cache.learning_affected and
        cache.raw == normalize(state.committed_raw .. live_input(context)) and
        #cache.raw == full_length + 1 and cache.prefix == normalize(lock.raw) and
        cache.text == lock.text and cache.boundaries == lock.boundaries and
        cache.allow_duplicate == active_allow_duplicate_single
    if not reuse_tail then reset_decode_cache() end
end

local function get_min_retained_raw_length(env)
    local schema = env and env.engine and env.engine.schema
    local config = schema and schema.config
    if not config then
        return 0
    end
    local ok, value = pcall(function()
        return config:get_int("tiger_sentence/min_retained_raw_length")
    end)
    if ok and type(value) == "number" and value >= 0 then
        return math.floor(value)
    end
    return 0
end

-- Mirror InputMethodEngine.IsTextEndingWithDigit: both half- and
-- full-width digits arm the decimal-point follow-up.
local function ends_with_digit(text)
    if not text or text == "" then
        return false
    end
    local chars = utf_chars(text)
    local last = chars[#chars]
    return last:match("^[0-9]$") ~= nil or last:match("^\xEF\xBC[\x90-\x99]") ~= nil
end

-- Standalone modifier key events must not consume the armed decimal point.
local function is_modifier_repr(repr)
    return repr:match("^Shift") ~= nil or
        repr:match("^Control") ~= nil or
        repr:match("^Alt") ~= nil or
        repr:match("^Super") ~= nil or
        repr:match("^Meta") ~= nil or
        repr:match("^Caps_Lock$") ~= nil or
        repr:match("^Num_Lock$") ~= nil or
        repr:match("^ISO_Level") ~= nil or
        repr == "Mode_switch"
end

local function try_empty_code_commit(env, state, full_before, appended_letter)
    local context = env.engine.context
    -- Empty-code auto commit is part of 整句自动提前上屏; there is no
    -- separate switch, so the early-commit option gates it as well.
    if not context:get_option("tiger_sentence_early_commit") or state.suspended then
        state.empty_code_pending = nil
        save_transient_state(context, state, env)
        return false
    end
    if synchronize_model_state(state) then
        save_transient_state(context, state, env)
        return false
    end
    local generation = model_generation
    local pending = state.empty_code_pending or
        capture_empty_code_candidate(full_before, state.committed_text, active_lock(state))
    if generation ~= model_generation then
        synchronize_model_state(state)
        save_transient_state(context, state, env)
        return false
    end
    local full_raw = state.committed_raw .. live_input(context)
    -- push_input inserts at the caret. Even callers other than processor must
    -- not turn a middle insertion (or a reentrant edit) into an imagined append.
    if full_raw ~= full_before .. appended_letter or
        input_caret(context) ~= #live_input(context) then
        state.empty_code_pending = nil
        save_transient_state(context, state, env)
        return false
    end
    state.empty_code_pending = pending

    if not pending then
        save_transient_state(context, state, env)
        return false
    end

    if has_complete_candidate(full_raw, state.committed_text, nil, false, active_lock(state)) then
        state.empty_code_pending = nil
        save_transient_state(context, state, env)
        return false
    end
    if not pending or
        pending.committed_text ~= state.committed_text or
        pending.base_raw_length < 0 or
        pending.base_raw_length >= #full_raw or
        pending.last_segment_start < 0 or
        pending.last_segment_start >= #full_raw then
        state.empty_code_pending = nil
        save_transient_state(context, state, env)
        return false
    end

    local extended_last_segment = full_raw:sub(pending.last_segment_start + 1)
    if lexicon_state.proper_code_prefixes[extended_last_segment] then
        save_transient_state(context, state, env)
        return false
    end

    local required_retain = get_min_retained_raw_length(env)
    local pending_commit = pending.candidate_text:sub(#pending.committed_text + 1)
    local protected_boundary = competing_boundary_end(
        full_raw, #state.committed_raw, pending.base_raw_length, utf_length(pending_commit))
    if required_retain > 0 and #full_raw - protected_boundary < required_retain then
        save_transient_state(context, state, env)
        return false
    end

    if pending.requires_uniqueness_check and has_complete_candidate(
        full_raw:sub(1, pending.base_raw_length), pending.committed_text,
        pending.candidate_text, true, active_lock(state)) then
        state.empty_code_pending = nil
        save_transient_state(context, state, env)
        return false
    end
    local commit = pending.candidate_text:sub(#pending.committed_text + 1)
    local retained_raw = full_raw:sub(pending.base_raw_length + 1)
    -- Preserve the committed prefix as decoder context. Restarting from only
    -- retained_raw makes the following sentence decode locally and can
    -- stabilize a plausible continuation that disagrees with the text which
    -- has already been committed.
    state.committed_text = pending.candidate_text
    state.committed_raw = full_raw:sub(1, pending.base_raw_length)
    state.last_auto_commit_raw_length = pending.base_raw_length
    state.trackers = {}
    state.last_seen_raw = ""
    state.suspended = false
    state.empty_code_pending = nil
    state.continuation_after_auto_commit = true
    submit_early(env, state, {text=pending.candidate_text, path={raw_length=pending.base_raw_length}}, commit)
    if ends_with_digit(commit) then
        env._tiger_sentence_dot_armed = true
    end
    save_sentence_state(context, state, env)
    reset_decode_cache()
    restore_composition_input(context, retained_raw)
    return true
end

local function reset_early_evidence(state)
    state.trackers = {}
    state.last_seen_raw = ""
end

local function auto_commit_matches_visible_top(visible_top, text)
    return visible_top == nil or
        visible_top:sub(1, #text) == text
end

local function try_commit_mature_prefix(env, state, evidence_raw, visible_top)
    local configured = get_min_retained_raw_length(env)
    local retain = configured > 0
        and math.max(early_commit_retained_raw_length, configured)
        or early_commit_retained_raw_length
    local selected = nil
    for _, tracker in pairs(state.trackers) do
        if (tracker.evidence_count >= early_commit_required_evidence or
            tracker.strong_count >= early_commit_required_strong) and
            tracker.raw_length > #state.committed_raw and
            tracker.raw_length <= #evidence_raw and
            #evidence_raw - competing_boundary_end(
                evidence_raw, #state.committed_raw, tracker.raw_length,
                (tracker.text_char_count or utf_length(tracker.text)) -
                    utf_length(state.committed_text)) >= retain and
            #tracker.text > #state.committed_text and
            tracker.text:sub(1, #state.committed_text) == state.committed_text and
            auto_commit_matches_visible_top(visible_top, tracker.text) then
            if not selected or tracker_better(tracker, selected) then
                selected = tracker
            end
        end
    end
    if not selected or
        #evidence_raw - state.last_auto_commit_raw_length <
            early_commit_retained_raw_length then
        return false
    end
    local commit = selected.text:sub(#state.committed_text + 1)
    if utf_length(commit) < 1 then
        return false
    end
    local context = env.engine.context
    state.committed_text = selected.text
    state.committed_raw = evidence_raw:sub(1, selected.raw_length)
    state.last_auto_commit_raw_length = selected.raw_length
    -- Probabilistic early commit chooses a boundary from complete sentence
    -- paths that have already competed in the language model. Keep those
    -- paths eligible after committing their common prefix; the stricter
    -- first-rank-only continuation rule is only for empty-code commit.
    state.continuation_after_auto_commit = false
    reset_early_evidence(state)
    save_sentence_state(context, state, env)
    submit_early(env, state, {text=selected.text, path={raw_length=selected.raw_length}}, commit)
    if ends_with_digit(commit) then
        env._tiger_sentence_dot_armed = true
    end
    restore_composition_input(context, evidence_raw:sub(selected.raw_length + 1))
    return true
end

local function try_early_commit(env)
    local context = env.engine.context
    local state = sentence_state(context, env)
    local live_raw = live_input(context)

    if input_caret(context) ~= #live_raw or
        not context:get_option("tiger_sentence_early_commit") or state.suspended then
        reset_early_evidence(state)
        save_transient_state(context, state, env)
        return
    end

    -- The first four raw encoding keys are never counted as stable evidence.
    local full_raw = state.committed_raw .. live_raw
    if #full_raw <= 4 then
        reset_early_evidence(state)
        save_transient_state(context, state, env)
        return
    end

    local generation = model_generation
    local decoded = decode(full_raw, true, state.committed_text, active_lock(state))
    if generation ~= model_generation then
        synchronize_model_state(state)
        save_transient_state(context, state, env)
        return
    end
    local early_commit_evidence = decoded.early_commit_evidence or {}
    local truncated = early_commit_evidence.confidence_truncated or false
    -- Learning can affect which paths survive the Beam. If that same pool is
    -- truncated, even model-only BaseShare may be conditionally inflated.
    if decoded.learning_affected and truncated then
        reset_early_evidence(state)
        save_transient_state(context, state, env)
        return
    end
    -- The decode above ran synchronously for exactly this raw code, so the
    -- evidence generation always matches the live composition.
    local evidence_raw = full_raw
    -- Confidence intentionally excludes final-stage ranking priors. It can
    -- authorize a commit only when the committed text is still a prefix of
    -- the candidate displayed first after those priors rerank the menu. nil
    -- preserves merged incomplete-tail evidence with no display candidate.
    local visible_top = #decoded > 0 and decoded[1].text or nil

    if state.last_seen_raw == evidence_raw then
        try_commit_mature_prefix(env, state, evidence_raw, visible_top)
        return
    end

    local extends_previous_generation = state.last_seen_raw == "" or
        (#evidence_raw == #state.last_seen_raw + 1 and
         evidence_raw:sub(1, #state.last_seen_raw) == state.last_seen_raw)
    if not extends_previous_generation then
        state.trackers = {}
    end
    state.last_seen_raw = evidence_raw

    local prefixes = early_commit_evidence.prefixes or {}
    local merged_incomplete_tail = early_commit_evidence.merged_incomplete_tail or false
    local qualifying = {}
    for i = 1, #prefixes do
        local prefix = prefixes[i]
        local base_share = prefix.base_share or prefix.share or 0
        if prefix.text and prefix.text ~= "" and
            prefix.boundary_closed and
            prefix.share >= early_commit_minimum_share and
            (not truncated or base_share >= early_commit_strong_share) and
            prefix.raw_length > #state.committed_raw and
            #prefix.text > #state.committed_text and
            prefix.text:sub(1, #state.committed_text) == state.committed_text and
            auto_commit_matches_visible_top(visible_top, prefix.text) and
            (merged_incomplete_tail or prefix_belongs_to_visible(prefix, decoded)) then
            qualifying[prefix.text .. state_separator .. tostring(prefix.raw_length)] = prefix
        end
    end

    local retain_without_counting = next(qualifying) == nil and
        (early_commit_evidence.neutral_low_confidence or merged_incomplete_tail)
    if retain_without_counting then
        -- Comparison-only gap: keep supported trackers alive without letting
        -- them gain evidence, for at most three consecutive generations.
        state.trackers = retain_trackers_without_counting(
            state.trackers, prefixes, early_commit_evidence.neutral_low_confidence)
        save_transient_state(context, state, env)
        try_commit_mature_prefix(env, state, evidence_raw, visible_top)
        return
    end

    local next_trackers = {}
    for key, prefix in pairs(qualifying) do
        local tracker = state.trackers[key]
        if not tracker then
            tracker = {
                text = prefix.text,
                text_char_count = prefix.text_char_count or utf_length(prefix.text),
                raw_length = prefix.raw_length,
                evidence_count = 0,
                strong_count = 0,
                gap_count = 0,
                last_share = 0.0
            }
        end
        tracker.evidence_count = math.min(
            early_commit_required_evidence, tracker.evidence_count + 1)
        local base_share = prefix.base_share or prefix.share or 0
        tracker.strong_count = base_share >= early_commit_strong_share
            and math.min(early_commit_required_strong, tracker.strong_count + 1)
            or 0
        tracker.gap_count = 0
        tracker.last_share = prefix.share
        next_trackers[key] = tracker
    end
    state.trackers = next_trackers
    save_transient_state(context, state, env)
    try_commit_mature_prefix(env, state, evidence_raw, visible_top)
end

local function is_plain_char_key(key_event, repr)
    if key_event:ctrl() or key_event:alt() or key_event:super() then
        return nil
    end
    if #repr == 1 and repr:match("[a-z]") then
        return repr
    end
    if repr == "semicolon" then
        return ";"
    end
    if repr == "apostrophe" then
        return "'"
    end
    if repr:match("^[0-9]$") then
        return repr
    end
    local kp = repr:match("^KP_([0-9])$")
    if kp then
        return kp
    end
    return nil
end

-- Learning staging is processor-local. Only the immutable score index is
-- shared with the translator; pending confirmations never cross contexts.
local function learning_selection(env, state)
    local context = env.engine.context
    local raw = state.committed_raw .. live_input(context)
    local composition = context.composition
    local segment = composition and not composition:empty() and composition:back()
    local target = segment and segment.selected_index or 0
    local results = decode(raw, false, state.committed_text, active_lock(state))
    local first, selected, visible = nil, nil, 0
    local seen = {}
    for _, item in ipairs(results) do
        if implicit_rank_allowed(item, raw, state.continuation_after_auto_commit) and
            item.text:sub(1, #state.committed_text) == state.committed_text and #item.text > #state.committed_text then
            first = first or item
            if visible == target then
                selected = item
                selected._fusion_ahead = {}
                for i = 1, #seen do selected._fusion_ahead[i] = seen[i] end
            end
            seen[#seen + 1] = item
            visible = visible + 1
        end
    end
    if not selected and live_input(context) == "" and state.buffered_text ~= "" then
        selected = {text=state.committed_text, path={raw_length=#state.committed_raw}}
    end
    return selected, first, raw
end

local function learning_stage(env, state, selected, raw, submitted_first)
    local live = env._tiger_learning
    if not live or live.mode == "" or not selected then return end

    -- Cross-source learning is pairwise and never mutates either source's
    -- internal ordering. Selecting a lower Direct candidate over an earlier
    -- Composed candidate records only Direct > Composed (and vice versa).
    for _, ahead in ipairs(selected._fusion_ahead or {}) do
        local event
        if learning.candidate_is_direct(selected) and learning.candidate_is_composed_only(ahead) then
            event = learning.fusion_event(live.mode, raw, selected.text, ahead.text, true,
                selected.path and selected.path.raw_length or #raw)
        elseif learning.candidate_is_composed_only(selected) and learning.candidate_is_direct(ahead) then
            event = learning.fusion_event(live.mode, raw, ahead.text, selected.text, false,
                selected.path and selected.path.raw_length or #raw)
        end
        if event and #live.pending < 256 then live.pending[#live.pending + 1] = event end
    end

    local baseline = state.tab_pending and live.baseline or
        (not state.tab_pending and submitted_first)
    if baseline and learning.candidate_is_composed_only(baseline) and learning.candidate_is_composed_only(selected) then
        local lock = active_lock(state)
        local floor = math.max(#state.committed_raw, lock and #lock.raw or 0)
        local events = learning.diff(raw, baseline, selected, floor, live.mode)
        for _, e in ipairs(events) do if #live.pending < 256 then live.pending[#live.pending + 1] = e end end
    end
    live.baseline = nil
end

learning_submit = function(env, selected, actual, expected)
    local live = env._tiger_learning
    if not live then return end
    local events, remaining = {}, {}
    if selected and actual ~= "" and actual == expected and live.mode ~= "" then
        local fusion_mode = learning.fusion_mode(live.mode)
        for _, e in ipairs(live.pending) do
            if e.raw_end > selected.path.raw_length then remaining[#remaining + 1] = e
            elseif e.mode == fusion_mode then events[#events + 1] = e
            elseif e.mode == live.mode and e.text_start >= #selected.text - #expected and
                selected.text:sub(e.text_start + 1, e.text_end) == e.text then events[#events + 1] = e end
        end
    end
    -- Consume before persistence: repeated notifications cannot reinforce it.
    live.pending, live.baseline = remaining, nil
    if learning.confirm(live.store, events) then reset_decode_cache() end
end

local function prepare_learning(env, attach)
    local schema, context = env.engine.schema, env.engine.context
    local enabled = true
    if schema and schema.config then
        local ok, value = pcall(function() return schema.config:get_bool("tiger_sentence/tab_learning") end)
        if ok and value == false then enabled = false end
    end
    local mode = enabled and ("sentence-v2|rules=" .. (lexicon_state.learning_rules or "") ..
        "|optimal=" .. tostring(lexicon_state.high_freq_limit) .. "|dup=" .. (active_allow_duplicate_single and "1" or "0")) or ""
    local schema_id = schema and schema.schema_id or "tiger_sentence"
    if env._tiger_learning_schema_id ~= schema_id then
        env._tiger_learning_schema_id = schema_id
        env._tiger_learning_name = "tiger_sentence_learning_" .. learning.hash(schema_id)
    end
    local name = env._tiger_learning_name
    local live = env._tiger_learning
    if not live or live.mode ~= mode or live.name ~= name then
        if live and live.connection then live.connection:disconnect() end
        if live and live.update_connection then live.update_connection:disconnect() end
        if live and live.option_connection then live.option_connection:disconnect() end
        if live and live.buffer_commit_connection then live.buffer_commit_connection:disconnect() end
        live = {mode=mode, name=name, pending={}, hide_owned=live and live.hide_owned,
            store=enabled and learning.open(name) or nil}
        env._tiger_learning = live
        if attach and context.commit_notifier then
            -- Grouped slots run before Rime's ungrouped engine commit slot.
            -- Keep the menu suffix-only, then assemble ONE complete submission
            -- just before the host reads it (also covers taps and ASCII exits).
            live.buffer_commit_connection = context.commit_notifier:connect(function(ctx)
                local prefix = buffered_text(ctx)
                if prefix == "" then return end
                local candidate = ctx:get_selected_candidate()
                if candidate and candidate.type == "sentence_buffered" then
                    candidate.text = prefix .. candidate.text
                    candidate.type = "sentence_buffered_commit"
                end
            end, -100)
        end
        if attach and context.commit_notifier then
            live.connection = context.commit_notifier:connect(function(ctx)
                if live.mode == "" or not live.store or not live.store.db then return end
                -- The notifier confirms Rime submission, not application insertion.
                pcall(function()
                    local state = sentence_state(ctx, env)
                    local selected, first, raw = learning_selection(env, state)
                    if raw == "" or live.submitted_raw == raw then return end
                    live.submitted_raw = raw
                    -- Direct candidate taps have no preceding processor key.
                    -- Compare the submitted choice with this menu's first path.
                    learning_stage(env, state, selected, raw, first)
                    learning_submit(env, selected, ctx:get_commit_text(),
                        selected and state.buffered_text .. selected.text:sub(#state.committed_text + 1) or "")
                end)
            end)
        end
        if attach and context.update_notifier then
            live.update_connection = context.update_notifier:connect(function(ctx)
                if not ctx:is_composing() then
                    live.pending, live.baseline, live.submitted_raw = {}, nil, nil
                    if buffered_text(ctx) ~= "" then reset_sentence_state(ctx, env) end
                end
                local hide = buffered_text(ctx) ~= "" and live_input(ctx) == ""
                if hide or live.hide_owned then
                    live.hide_owned = hide
                    if ctx:get_option("_hide_candidate") ~= hide then
                        ctx:set_option("_hide_candidate", hide)
                    end
                end
            end)
        end
        if attach and context.option_update_notifier then
            live.option_connection = context.option_update_notifier:connect(function(ctx, name)
                if name == "ascii_mode" and ctx:get_option(name) and buffered_text(ctx) ~= "" then
                    ctx:confirm_current_selection()
                end
            end)
        end
    end
    if not context:is_composing() then learning.refresh_scores(live.store) end
    local index = live.store and live.store.db and live.store.index or nil
    if live.active_index ~= index then
        live.active_index = index
        local state = sentence_state(context, env)
        reset_early_evidence(state)
        state.empty_code_pending = nil
        save_transient_state(context, state, env)
    end
    if learning_index ~= index or learning_mode ~= mode then
        learning_index, learning_mode = index, mode
        reset_decode_cache()
    end
    return live
end

local function processor(key_event, env)
    if key_event:release() then
        return 2
    end
    if env._tiger_options then env._tiger_options.sync() end
    configure_memory(env)
    ensure_lexicon(env)
    local context = env.engine.context
    set_allow_duplicate_single(context)
    local learned = prepare_learning(env, true)
    learned.submitted_raw = nil
    local state = sentence_state(context, env)
    local repr = key_event:repr()
    if state.buffered_text ~= "" and live_input(context) == "" and
        (repr == "Tab" or repr == "ISO_Left_Tab" or repr == "Shift+Tab" or
         repr == "Up" or repr == "Down" or repr == "Page_Up" or repr == "Page_Down") then
        return 1
    end
    if state.buffered_text ~= "" and type(context.caret_pos) == "number" and context.caret_pos < 1 then
        context.caret_pos = 1
    end
    if not context:is_composing() then learned.pending, learned.baseline = {}, nil end
    -- Mirror InputMethodEngine._dotAfterDigitArmed: the period following a
    -- digit output becomes an ASCII decimal point; any non-modifier key
    -- consumes the arm.
    local dot_armed = env._tiger_sentence_dot_armed or false
    if not is_modifier_repr(repr) then
        env._tiger_sentence_dot_armed = false
    end
    local ch = is_plain_char_key(key_event, repr)
    if ch then
        if not context:is_composing() and
            (state.committed_raw ~= "" or state.last_seen_raw ~= "" or
             next(state.trackers or {}) ~= nil or state.suspended or
             state.continuation_after_auto_commit or active_lock(state) or state.tab_pending) then
            reset_sentence_state(context, env)
            state = sentence_state(context, env)
        end
        -- Semicolon and apostrophe are rank selectors only for an existing
        -- composition. At idle, leave them to punctuator so symbols.yaml can
        -- commit Chinese punctuation directly.
        if not context:is_composing() and (ch == ";" or ch == "'") then
            return 2
        end
        set_allow_duplicate_single(context)
        if #live_input(context) >= max_raw_length then
            return 1
        end
        -- Digits are rank suffixes only while composing. Idle digits commit
        -- directly (half-width; full-width in full_shape mode). Returning
        -- them to Rime instead would push them into the speller alphabet
        -- and leave an unresolved composition behind.
        if ch:match("%d") and not context:is_composing() then
            if context:get_option("full_shape") then
                local full = { "０", "１", "２", "３", "４", "５", "６", "７", "８", "９" }
                env.engine:commit_text(full[tonumber(ch) + 1])
            else
                env.engine:commit_text(ch)
            end
            env._tiger_sentence_dot_armed = true
            return 1
        end
        local is_letter = ch:match("^[a-z]$") ~= nil
        local live_before = live_input(context)
        local caret = input_caret(context)
        local full_before = state.committed_raw .. live_before
        if caret ~= #live_before then
            learned.pending, learned.baseline = {}, nil
            invalidate_edit_state(context, state, env,
                #state.committed_raw + caret, #full_before + #ch)
            -- Keep Rime's real insertion/caret semantics. This edit is not
            -- evidence for either append-only auto-commit path or a Tab lock.
            context:push_input(ch)
            return 1
        end
        local confirm = state.tab_pending and is_letter
        if confirm then
            local composition = context.composition
            local segment = composition and not composition:empty() and composition:back()
            local target = segment and segment.selected_index or 0
            local decoded = decode(full_before, false, state.committed_text, active_lock(state))
            local selected, visible, seen = nil, 0, {}
            for _, item in ipairs(decoded) do
                if implicit_rank_allowed(item, full_before, state.continuation_after_auto_commit) and
                    item.text:sub(1, #state.committed_text) == state.committed_text and
                    #item.text > #state.committed_text then
                    if visible == target then
                        selected = item
                        selected._fusion_ahead = {}
                        for i = 1, #seen do selected._fusion_ahead[i] = seen[i] end
                        break
                    end
                    seen[#seen + 1] = item
                    visible = visible + 1
                end
            end
            if selected and selected.path and selected.path.raw_length > #state.committed_raw then
                learning_stage(env, state, selected, full_before)
                state.tab_pending = false
                local boundaries, node = {}, selected.path
                while node and node.raw_length > 0 do
                    table.insert(boundaries, 1, tostring(node.raw_length) .. "," .. tostring(node.text_length) .. ";")
                    node = node.previous
                end
                state.locks[#state.locks + 1] = { raw = full_before:sub(1, selected.path.raw_length),
                    text = selected.text, boundaries = table.concat(boundaries) }
                local commit
                if context:get_option("tiger_sentence_early_commit") then
                    commit = selected.text:sub(#state.committed_text + 1)
                    state.committed_text = selected.text
                    state.committed_raw = full_before:sub(1, selected.path.raw_length)
                end
                reset_early_evidence(state)
                state.empty_code_pending = nil
                state.suspended = false
                state.continuation_after_auto_commit = false
                save_sentence_state(context, state, env)
                if commit then
                    submit_early(env, state, selected, commit)
                end
                restore_composition_input(context, full_before:sub(#state.committed_raw + 1) .. ch)
                return 1
            end
        end
        state.tab_pending = false
        learned.baseline = nil
        if not is_letter then
            state.empty_code_pending = nil
            save_transient_state(context, state, env)
        end
        context:push_input(ch)
        if is_letter and try_empty_code_commit(env, state, full_before, ch) then
            return 1
        end
        try_early_commit(env)
        return 1
    end
    if not context:is_composing() then
        if dot_armed and (repr == "period" or repr == "KP_Decimal") and
            not key_event:shift() and not key_event:ctrl() and
            not key_event:alt() and not key_event:super() then
            env.engine:commit_text(".")
            return 1
        end
        return 2
    end
    local codepoint = key_event.keycode
    if context:has_menu() and type(codepoint) == "number" and
        codepoint >= 33 and codepoint <= 126 and
        string.char(codepoint):match("%p") and
        not key_event:ctrl() and not key_event:alt() and not key_event:super() then
        -- Letters and rank selectors were handled above. Submit while the
        -- sentence menu/raw input still identifies the corrected path. Once
        -- punctuator appends its segment, learning_selection cannot decode
        -- that input (e.g. zhhbi,) or recover the sentence's selected index.
        -- Keep punctuation handling in the configured Rime punctuator.
        local selected, _, raw = learning_selection(env, state)
        learning_stage(env, state, selected, raw)
        context:confirm_current_selection()
        return 2
    end
    if repr == "Return" or repr == "KP_Enter" then
        learned.pending, learned.baseline = {}, nil
        env.engine:commit_text(state.buffered_text .. live_input(context))
        context:clear()
        reset_sentence_state(context, env)
        return 1
    end
    if repr == "Escape" then
        learned.pending, learned.baseline = {}, nil
        context:clear()
        reset_sentence_state(context, env)
        return 1
    end
    if repr == "BackSpace" or repr == "Delete" then
        -- Conservatively discard staged corrections on manual edits; a new
        -- Tab correction can be recorded after the edit has been decoded.
        learned.pending, learned.baseline = {}, nil
        state.tab_pending = false
        reset_early_evidence(state)
        state.empty_code_pending = nil
        if state.buffered_text ~= "" then
            local raw = live_input(context)
            local caret = input_caret(context)
            if repr == "BackSpace" and raw == "" then
                local letters = utf_chars(state.buffered_text)
                local removed = table.remove(letters)
                state.buffered_text = table.concat(letters)
                state.committed_text = state.committed_text:sub(1, #state.committed_text - #removed)
                if state.buffered_text == "" then
                    reset_sentence_state(context, env)
                else
                    state.locks = {{raw=state.committed_raw, text=state.committed_text,
                        boundaries=tostring(#state.committed_raw)..","..tostring(#state.committed_text)..";"}}
                    save_sentence_state(context, state, env)
                end
                reset_decode_cache()
                restore_composition_input(context, raw)
                return 1
            end
            local first = repr == "BackSpace" and caret - 1 or caret
            if first < 0 or first >= #raw then return 1 end
            local remaining = raw:sub(1, first) .. raw:sub(first + 2)
            invalidate_edit_state(context, state, env,
                #state.committed_raw + first, #state.committed_raw + #remaining,
                first == #raw - 1 and raw:sub(-1) or nil)
            restore_composition_input(context, remaining)
            if type(context.caret_pos) == "number" then context.caret_pos = first + 1 end
            return 1
        end
        if active_lock(state) then
            local raw = live_input(context)
            local caret = input_caret(context)
            local first = repr == "BackSpace" and caret - 1 or caret
            if first < 0 or first >= #raw then
                save_transient_state(context, state, env)
                return 2
            end
            local remaining = raw:sub(1, first) .. raw:sub(first + 2)
            invalidate_edit_state(context, state, env,
                #state.committed_raw + first, #state.committed_raw + #remaining,
                first == #raw - 1 and raw:sub(-1) or nil)
            if remaining == "" then
                context:clear()
                reset_sentence_state(context, env)
            else
                local edit = repr == "BackSpace" and context.pop_input or context.delete_input
                if type(edit) == "function" then
                    edit(context, 1)
                else
                    restore_composition_input(context, remaining)
                    if type(context.caret_pos) == "number" then context.caret_pos = first end
                end
            end
            return 1
        end
        save_transient_state(context, state, env)
        return 2
    end
    if repr == "Left" or repr == "Right" or repr == "Home" or repr == "End" then
        learned.pending, learned.baseline = {}, nil
        -- Let navigator move the caret; old append evidence and a pending Tab
        -- confirmation do not survive manual cursor navigation.
        state.tab_pending = false
        reset_early_evidence(state)
        state.empty_code_pending = nil
        save_transient_state(context, state, env)
        if state.buffered_text ~= "" and (repr == "Home" or (repr == "Left" and input_caret(context) == 0)) then
            context.caret_pos = 1
            return 1
        end
        return 2
    end
    if repr == "Tab" or repr == "ISO_Left_Tab" or repr == "Shift+Tab" then
        if not state.tab_pending and learned.store and learned.store.db then
            local _, first = learning_selection(env, state)
            learned.baseline = first
        end
        reset_early_evidence(state)
        state.suspended = true
        state.empty_code_pending = nil
        save_transient_state(context, state, env)
        if cycle_candidate_highlight(context, repr == "Tab" and 1 or -1) then
            state.tab_pending = true
            save_transient_state(context, state, env)
            return 1
        end
        -- Without a usable menu, leave the key to the schema's Down/Up
        -- bindings and the standard navigator.
        return 2
    end
    if repr == "Up" or repr == "Down" or repr == "Page_Up" or repr == "Page_Down" then
        reset_early_evidence(state)
        state.suspended = true
        state.empty_code_pending = nil
        save_transient_state(context, state, env)
        return 2
    end
    if repr == "space" then
        if context:has_menu() then
            local selected, _, raw = learning_selection(env, state)
            learning_stage(env, state, selected, raw)
            context:confirm_current_selection()
        end
        learned.pending, learned.baseline = {}, nil
        reset_sentence_state(context, env)
        return 1
    end
    return 2
end

local function translator(input, seg, env)
    -- 拼音反查是以反引号 ` 开头的输入，或者带有 rvlk 标签的段落，不进行普通翻译。
    if seg:has_tag("rvlk") or input:sub(1, 1) == "`" then
        return
    end

    configure_memory(env)
    ensure_lexicon(env)
    local context = env.engine.context
    local state = sentence_state(context, env)
    set_allow_duplicate_single(context)
    prepare_learning(env)
    local committed_text = state.committed_text
    local committed_raw = state.committed_raw
    local buffered = state.buffered_text
    if buffered ~= "" then
        -- Never translate the full context into a later punctuation segment.
        if seg.start ~= 0 or input:sub(1, 1) ~= "~" then return end
        input = input:sub(2)
    end
    -- With no live code, the only visible value is the editable buffer.
    -- Replaying its entire locked history just to yield an empty suffix made
    -- repeated text-only Backspace unnecessarily expensive. Do not bypass
    -- decoding for an inconsistent/foreign lock or a nonempty suffix.
    local lock = active_lock(state)
    if buffered ~= "" and input == "" and lock and
        lock.raw == committed_raw and lock.text == committed_text then
        local cand = Candidate("sentence_buffered", seg.start, seg._end, "", "")
        cand.quality = 1000
        cand.preedit = buffered
        yield(cand)
        return
    end
    local raw = committed_raw .. input
    local results = decode(raw, false, committed_text, lock)
    local yielded = 0
    for i = 1, #results do
        local item = results[i]
        if implicit_rank_allowed(
                item, raw, state.continuation_after_auto_commit) and
            (committed_text == "" or
             item.text:sub(1, #committed_text) == committed_text) then
            local text = committed_text == "" and item.text or item.text:sub(#committed_text + 1)
            local preedit = item.segmented
            if committed_raw ~= "" then
                -- Same-generation menu refreshes (including text-only
                -- Backspace) reuse the suffix but prepend the current buffer.
                if item._display_floor ~= #committed_raw then
                    item._display_floor = #committed_raw
                    item._display_suffix = trim_segmented_after_raw_prefix(preedit, #committed_raw)
                end
                preedit = item._display_suffix
            end
            if text ~= "" or buffered ~= "" then
                local cand = Candidate(buffered ~= "" and "sentence_buffered" or "sentence",
                    seg.start, seg._end, text, "")
                if buffered ~= "" then cand.quality = 1000 end
                cand.preedit = buffered .. (buffered ~= "" and preedit ~= "" and " " or "") .. preedit
                yield(cand)
                yielded = yielded + 1
                if yielded >= candidate_limit then return end
            end
        end
    end
    if yielded == 0 and buffered ~= "" then
        local cand = Candidate("sentence_buffered", seg.start, seg._end, input, "")
        cand.quality = 1000
        cand.preedit = buffered .. (input ~= "" and " " or "") .. input
        yield(cand)
    end
end

local M = {}
M.decode = decode
M.decode_full = decode_full
M.ensure_lexicon = ensure_lexicon
M.data_status = data_status
M.apply_high_freq_limit = function(limit)
    if limit == nil then return end
    local value = math.floor(tonumber(limit) or 0)
    if value < 0 then
        value = 0
    end
    rebuild_lexicon(value)
end
M.reset_decode_cache = reset_decode_cache
M.results_equal = results_equal
M.model_status = model_status
M.load_ngram_model = kn_reader.load
M.supplement_status = function()
    return {
        path = supplement_matcher.path,
        count = supplement_matcher.count or 0,
        error = supplement_matcher.error
    }
end
M.lexical_status = function()
    return {
        loaded = ranking_prior.lexical_model ~= nil,
        path = ranking_prior.lexical_model and ranking_prior.lexical_model.path or nil,
        error = ranking_prior.lexical_load_error,
        entries = ranking_prior.lexical_model and ranking_prior.lexical_model.entry_count or 0,
        bytes = ranking_prior.lexical_model and ranking_prior.lexical_model.bytes or 0,
        minimum_length = ranking_prior.lexical_model and
            ranking_prior.lexical_model.minimum_length or nil,
        maximum_length = ranking_prior.lexical_model and
            ranking_prior.lexical_model.maximum_length or nil
    }
end
M.find_raw_length_for_text = find_raw_length_for_text
M.lexicon_probe = function(code)
    local candidates = lexicon_state.codes[code]
    if not candidates then
        return nil
    end
    local copy = {}
    for index = 1, #candidates do
        copy[index] = {
            t = candidates[index].t,
            r = candidates[index].r,
            optimal_single = candidates[index].optimal_single or false,
            primary_single = candidates[index].primary_single or false
        }
    end
    return copy
end
M.lexicon_lengths = function()
    local copy = {}
    for index = 1, #lexicon_state.lengths do
        copy[index] = lexicon_state.lengths[index]
    end
    return copy
end
-- Read-only view for benchmarks and diagnostics; callers must not mutate.
M.lexicon_data_view = function()
    ensure_lexicon(nil)
    return {
        codes = lexicon_state.codes,
        lengths = lexicon_state.lengths
    }
end
M.capture_empty_code_candidate = capture_empty_code_candidate
-- Independent full-text oracle for regression tests of lazy path scoring.
M.reference_isolation_penalty = isolation_penalty
M.reference_path_isolation_penalty = ranking_prior.reference_path_isolation_penalty
M.path_isolation_penalty = path_isolation_penalty
M.has_complete_candidate = has_complete_candidate
M.set_allow_duplicate_single = set_allow_duplicate_single
M.build_prefix_evidence = build_prefix_evidence
M.find_prefix_evidence = find_prefix_evidence
M.common_text_prefix = common_text_prefix
M.strong_empty_code_candidate = strong_empty_code_candidate
M.set_model_enabled = function(enabled)
    local disabled = enabled == false
    if disabled == model_disabled then
        return
    end
    model_disabled = disabled
    close_model()
    model_generation = model_generation + 1
    kn_model = false
    kn_load_error = nil
    clear_model_dependent_caches()
end
M.prefix_extends = prefix_extends
M.prefix_contradicted = prefix_contradicted
M.retain_trackers_without_counting = retain_trackers_without_counting
M.auto_commit_matches_visible_top = auto_commit_matches_visible_top
M.competing_boundary_end = competing_boundary_end
M.performance_status = function()
    return {
        current = {
            decode_calls = performance.decode_calls,
            decode_total_ms = performance.decode_total_ms,
            decode_max_ms = performance.decode_max_ms,
            page_misses = performance.page_misses,
            page_bytes = performance.page_bytes,
            early_evidence_builds = performance.early_evidence_builds,
            isolation_hits = performance.isolation_hits,
            isolation_misses = performance.isolation_misses
        },
        last = performance.last
    }
end
-- Does not load the model, advance a learning epoch, or force a collection.
M.memory_status = function()
    return {profile=active_memory_profile, lua_kib=collectgarbage("count"),
        logp_entries=#logp_cache_keys, logp_limit=logp_cache_limit,
        observed_entries=#observed_cache_keys, observed_limit=observed_cache_limit,
        isolation_entries=#isolation_cache_keys, isolation_limit=ISOLATION_CACHE_ENTRIES,
        lexical_bytes=ranking_prior.lexical_model and ranking_prior.lexical_model.bytes or 0,
        model=kn_model and kn_model.cache_status and kn_model.cache_status() or nil}
end
M.set_memory_profile = set_memory_profile
M.configure_memory = configure_memory
-- Offline evaluation hook.  Production entry points keep the compiled
-- defaults; the benchmark tool can vary one parameter at a time without
-- source rewriting.  Resetting both lookup and lattice caches is required
-- because isolation values and path ordering are parameter-dependent.
M.set_decoder_parameters_for_test = function(values)
    values = values or {}
    local function bounded(name, current, minimum, maximum, integer)
        local value = values[name]
        if value == nil then return current end
        value = tonumber(value)
        if not value or value ~= value or math.abs(value) == math.huge or
            value < minimum or value > maximum then
            error(string.format("invalid decoder parameter %s", name))
        end
        return integer and math.floor(value) or value
    end
    beam_width = bounded("beam_width", beam_width, 1, 5000, true)
    long_input_full_beam_length = bounded(
        "long_input_full_beam_length", long_input_full_beam_length, 0, max_raw_length, true)
    long_input_beam_width = bounded(
        "long_input_beam_width", long_input_beam_width, 1, 5000, true)
    rank_penalty = bounded("rank_penalty", rank_penalty, 0, 10, false)
    emitted_character_reward = bounded(
        "emitted_character_reward", emitted_character_reward, -10, 10, false)
    ranking_prior.canonical_code_reward = bounded(
        "canonical_code_reward", ranking_prior.canonical_code_reward, 0, 10, false)
    ranking_prior.lexical_prior_weight = bounded(
        "lexical_prior_weight", ranking_prior.lexical_prior_weight, 0, 10, false)
    isolation_threshold = bounded(
        "isolation_threshold", isolation_threshold, 0, 1000000, true)
    isolation_lambda = bounded("isolation_lambda", isolation_lambda, 0, 20, false)
    ranking_prior.canonical_isolation_factor = bounded(
        "canonical_isolation_factor", ranking_prior.canonical_isolation_factor, 0, 1, false)
    ranking_prior.canonical_isolation_min_code_length = bounded(
        "canonical_isolation_min_code_length",
        ranking_prior.canonical_isolation_min_code_length, 2, 16, true)
    clear_lookup_caches()
    reset_decode_cache()
end
M.decoder_parameters = function()
    return {
        beam_width = beam_width,
        long_input_full_beam_length = long_input_full_beam_length,
        long_input_beam_width = long_input_beam_width,
        rank_penalty = rank_penalty,
        emitted_character_reward = emitted_character_reward,
        canonical_code_reward = ranking_prior.canonical_code_reward,
        lexical_prior_weight = ranking_prior.lexical_prior_weight,
        isolation_threshold = isolation_threshold,
        isolation_lambda = isolation_lambda,
        canonical_isolation_factor = ranking_prior.canonical_isolation_factor,
        canonical_isolation_min_code_length = ranking_prior.canonical_isolation_min_code_length
    }
end
-- Host opt-in hook; call between key events on the owning Lua thread. Do not
-- close the model or drop active Beam/locks/evidence/learning transactions.
-- A full collection is deliberately explicit, never performed on every key.
M.trim_memory = function()
    clear_lookup_caches()
    if kn_model and kn_model.trim_caches then kn_model.trim_caches() end
    learning.trim_caches(learning_index)
    collectgarbage("collect")
    return M.memory_status()
end
M.processor = processor
M.translator = translator
M.buffer_filter = function(input, env)
    local buffered = buffered_text(env.engine.context) ~= ""
    for candidate in input:iter() do
        if not buffered or candidate.type == "sentence_buffered" then yield(candidate) end
    end
end
M.learning = learning
M.apply_fusion_ordering_for_test = learning.apply_fusion_ordering
M.set_learning_for_test = function(index, mode)
    learning_index, learning_mode = index, mode or ""
    reset_decode_cache()
end
M.processor_component = {
    init = function(env) configure_memory(env); M.options.init(env) end,
    func = processor,
    fini = function(env)
        M.options.fini(env)
        local live = env._tiger_learning
        if live and live.connection then live.connection:disconnect() end
        if live and live.update_connection then live.update_connection:disconnect() end
        if live and live.option_connection then live.option_connection:disconnect() end
        if live and live.buffer_commit_connection then live.buffer_commit_connection:disconnect() end
        if live and live.hide_owned then env.engine.context:set_option("_hide_candidate", false) end
        -- A schema change cancels text still owned by this composition.
        if buffered_text(env.engine.context) ~= "" then
            env.engine.context:clear()
            reset_sentence_state(env.engine.context, env)
        end
        env._tiger_learning = nil
    end
}
-- These are user preferences, not per-application composition state. Keep a
-- separate small Rime Config so API/mobile toggles persist too (switcher's
-- save_options only saves switcher commands). Never rewrite user.yaml or the
-- user's default.custom.yaml. Disk I/O occurs on load/toggle, never each key.
M.options = {}
do
    local defaults = {
        tiger_sentence_early_commit = true,
        tiger_sentence_allow_duplicate_single = true,
        tiger_sentence_early_commit_to_preedit = false
    }
    local stores = {}
    local function open_store()
        if type(Config) ~= "function" or not rime_api or
            type(rime_api.get_user_data_dir) ~= "function" then return nil end
        local directory = rime_api.get_user_data_dir()
        if not directory or directory == "" then return nil end
        local path = directory .. "/tiger_sentence.options.yaml"
        if stores[path] then return stores[path] end
        local config = Config()
        if file_exists(path) then config:load_from_file(path) end
        local legacy = Config()
        if file_exists(directory .. "/user.yaml") then legacy:load_from_file(directory .. "/user.yaml") end
        local store = {config=config, path=path, values={}, revision=0}
        for name in pairs(defaults) do
            local value = config:get_bool("options/" .. name)
            if value == nil then value = legacy:get_bool("var/option/" .. name) end
            store.values[name] = value
        end
        stores[path] = store
        return store
    end
    function M.options.sync(env)
        local live = env._tiger_options
        if not live or live.syncing or live.revision == live.store.revision then return end
        live.syncing = true
        local context = env.engine.context
        for name, fallback in pairs(live.defaults) do
            local value = live.store.values[name]
            if value == nil then value = fallback end
            if context:get_option(name) ~= value then context:set_option(name, value) end
        end
        live.revision = live.store.revision
        live.syncing = false
    end
    function M.options.init(env)
        local ok, store = pcall(open_store)
        if not ok or not store then return end
        local context = env.engine.context
        local live = {store=store, defaults={}, revision=-1}
        live.sync = function() M.options.sync(env) end
        env._tiger_options = live
        for name, fallback in pairs(defaults) do
            local value = env.engine.schema.config:get_bool("tiger_sentence/option_defaults/" .. name)
            if value == nil then value = fallback end
            live.defaults[name] = value
        end
        M.options.sync(env)
        live.connection = context.option_update_notifier:connect(function(ctx, name)
            if live.syncing or defaults[name] == nil then return end
            local value = ctx:get_option(name)
            if store.values[name] == value then return end
            store.values[name] = value
            store.revision = store.revision + 1
            -- Leave this session's revision stale: other options may have
            -- changed in another application since this one was last used.
            local saved, accepted = pcall(function()
                for option, choice in pairs(store.values) do store.config:set_bool("options/" .. option, choice) end
                return store.config:save_to_file(store.path)
            end)
            set_property_if_changed(ctx, "tiger_sentence_options_error",
                saved and accepted and "" or "Unable to save tiger_sentence.options.yaml")
        end)
    end
    function M.options.fini(env)
        local live = env._tiger_options
        if live and live.connection then live.connection:disconnect() end
        env._tiger_options = nil
    end
end
-- Retain Rime's native modifier timing and bindings. Only while a buffered
-- composition exists, raw-code/inline-ASCII exits must submit its displayed
-- candidate instead of the private transport marker. The schema is private;
-- neither the user's configuration nor ordinary-mode bindings are changed.
M.ascii_component = {
    func = function(key, env)
        local buffered = buffered_text(env.engine.context) ~= ""
        if not env.native or env.buffered ~= buffered then
            env.buffered = buffered
            local schema = env.engine.schema
            if buffered then
                local default_schema = Schema(".default")
                local defaults = default_schema.config
                local source = schema.config:get_map("ascii_composer/switch_key") and schema.config or defaults
                local private = Schema("tiger_sentence_ascii")
                local caps = schema.config:get_bool("ascii_composer/good_old_caps_lock")
                if caps == nil then caps = defaults:get_bool("ascii_composer/good_old_caps_lock") end
                private.config:set_bool("ascii_composer/good_old_caps_lock", caps or false)
                for _, name in ipairs({"Shift_L", "Shift_R", "Control_L", "Control_R",
                    "Alt_L", "Alt_R", "Super_L", "Super_R", "Caps_Lock", "Eisu_toggle"}) do
                    local path = "ascii_composer/switch_key/" .. name
                    local style = source:get_string(path) or "noop"
                    if style == "commit_code" or style == "inline_ascii" then style = "commit_text" end
                    private.config:set_string(path, style)
                end
                schema = private
            end
            env.native_schema = schema
            env.native = Component.Processor(env.engine, schema, "", "ascii_composer")
        end
        return env.native:process_key_event(key)
    end,
    fini = function(env) env.native = nil; env.native_schema = nil end
}
return M
