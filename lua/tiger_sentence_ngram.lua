-- KN model I/O only. The main module owns model lifetime and decode caches;
-- passing its counters here does not create per-processor/translator models.
local BOS, EOS = "\2", "\3"
local SHIFT = 2097152
local MOBILE_HEADER_SIZE = 104
local MOBILE_CACHE_BYTES = 8 * 1024 * 1024
local CONTEXT_CACHE_ENTRIES = 16384
local INDEX_PAGE_RECORDS = 256 -- 4 KiB of the existing 16-byte sparse index
local INDEX_CACHE_PAGES = 64
local memo = require("tiger_sentence_cache")
local M = {}
function M.new(performance)
local kn_reader = {
    BOS = BOS,
    EOS = EOS
}

local function file_exists(path)
    local file = io.open(path, "rb")
    if not file then
        return false
    end
    file:close()
    return true
end

function kn_reader.candidate_paths()
    local mobile_paths = {}
    local legacy_paths = {}
    if rime_api then
        local user_dir = rime_api.get_user_data_dir and rime_api.get_user_data_dir()
        local shared_dir = rime_api.get_shared_data_dir and rime_api.get_shared_data_dir()
        if user_dir and user_dir ~= "" then
            mobile_paths[#mobile_paths + 1] = user_dir .. "/models/sentence-ngram-mobile.bin"
            mobile_paths[#mobile_paths + 1] = user_dir .. "/sentence-ngram-mobile.bin"
            legacy_paths[#legacy_paths + 1] = user_dir .. "/models/sentence-ngram-v2.bin"
            legacy_paths[#legacy_paths + 1] = user_dir .. "/sentence-ngram-v2.bin"
        end
        if shared_dir and shared_dir ~= "" then
            mobile_paths[#mobile_paths + 1] = shared_dir .. "/models/sentence-ngram-mobile.bin"
            legacy_paths[#legacy_paths + 1] = shared_dir .. "/models/sentence-ngram-v2.bin"
        end
    end
    mobile_paths[#mobile_paths + 1] = "C:/Archive/tigerclaw_sentence_ml/runtime/rime/sentence-ngram-mobile.bin"
    mobile_paths[#mobile_paths + 1] = "/mnt/c/Archive/tigerclaw_sentence_ml/runtime/rime/sentence-ngram-mobile.bin"
    legacy_paths[#legacy_paths + 1] = "C:/Archive/tigerclaw_sentence_ml/runtime/sentence-ngram-v2.bin"
    legacy_paths[#legacy_paths + 1] = "/mnt/c/Archive/tigerclaw_sentence_ml/runtime/sentence-ngram-v2.bin"
    for _, path in ipairs(legacy_paths) do
        mobile_paths[#mobile_paths + 1] = path
    end
    return mobile_paths
end

local function scalar(token)
    if not token or token == "" then
        return 0
    end
    if token == BOS or token == EOS then
        return string.byte(token)
    end
    return utf8.codepoint(token)
end

local function pack2(first, second)
    -- Avoid parser-level bitwise syntax; model scoring still requires the
    -- string.unpack and utf8 APIs supplied by Lua 5.3+ Rime builds.
    return first * SHIFT + (second % SHIFT)
end

local function load_legacy(path)
    local file = assert(io.open(path, "rb"), "cannot open n-gram: " .. path)
    local data = file:read("*a")
    file:close()
    assert(data and #data > 32, "empty n-gram: " .. path)
    assert(data:sub(1, 8) == "TCSKNM01", "not a TCSKNM01 model: " .. path)

    local function i32(off)
        return (string.unpack("<i4", data, off + 1))
    end
    local function u64(off)
        return (string.unpack("<I8", data, off + 1))
    end
    local function f32(off)
        return (string.unpack("<f", data, off + 1))
    end

    assert(i32(8) == 1, "unsupported n-gram version")
    local uni_count = i32(12)
    local pos = 16
    local uni_off = pos
    pos = pos + uni_count * 8
    local bi_count = u64(pos)
    pos = pos + 8
    local bi_off = pos
    pos = pos + bi_count * 12
    local bi_ctx_count = i32(pos)
    pos = pos + 4
    local bi_ctx_off = pos
    pos = pos + bi_ctx_count * 8
    local tri_count = u64(pos)
    pos = pos + 8
    local tri_off = pos
    pos = pos + tri_count * 12
    local tri_ctx_count = u64(pos)
    pos = pos + 8
    local tri_ctx_off = pos
    local unknown = f32(uni_off + 4)

    local function lookup_i32(offset, count, key, fallback)
        local low, high = 0, count
        while low < high do
        local middle = low + math.floor((high - low) / 2)
            local value = i32(offset + middle * 8)
            if value < key then
                low = middle + 1
            else
                high = middle
            end
        end
        if low >= count then
            return fallback
        end
        local at = offset + low * 8
        if i32(at) == key then
            return f32(at + 4)
        end
        return fallback
    end

    local function lookup_u64(offset, count, key, fallback)
        local low, high = 0, count
        while low < high do
        local middle = low + math.floor((high - low) / 2)
            local value = u64(offset + middle * 12)
            if value < key then
                low = middle + 1
            else
                high = middle
            end
        end
        if low >= count then
            return fallback
        end
        local at = offset + low * 12
        if u64(at) == key then
            return f32(at + 8)
        end
        return fallback
    end

    local function pack3(first, second, third)
        return pack2(first, second) * SHIFT + (third % SHIFT)
    end

    local function logp(prev2, prev1, target)
        local first = scalar(prev2)
        local second = scalar(prev1)
        local third = scalar(target)
        local unigram = lookup_i32(uni_off, uni_count, third, unknown)
        local bigram = lookup_u64(bi_off, bi_count, pack2(second, third), 0.0)
        local bigram_lambda = lookup_i32(bi_ctx_off, bi_ctx_count, second, 1.0)
        bigram = bigram + bigram_lambda * unigram
        local trigram = lookup_u64(tri_off, tri_count, pack3(first, second, third), 0.0)
        local trigram_lambda = lookup_u64(tri_ctx_off, tri_ctx_count, pack2(first, second), 1.0)
        trigram = trigram + trigram_lambda * bigram
        if trigram < 1e-300 then
            trigram = 1e-300
        end
        return math.log(trigram)
    end

    local function has_observed_bigram(prev, target)
        local left = scalar(prev)
        local right = scalar(target)
        local key = pack2(left, right)
        local low, high = 0, bi_count
        while low < high do
        local middle = low + math.floor((high - low) / 2)
            local value = u64(bi_off + middle * 12)
            if value < key then
                low = middle + 1
            else
                high = middle
            end
        end
        return low < bi_count and u64(bi_off + low * 12) == key
    end

    return {
        path = path,
        bytes = #data,
        format = "TCSKNM01",
        logp = logp,
        has_observed_bigram = has_observed_bigram
    }
end

local function load_mobile(path, limits)
    local file = assert(io.open(path, "rb"), "cannot open n-gram: " .. path)
    local function read_model()
    local header = file:read(MOBILE_HEADER_SIZE)
    assert(header and #header == MOBILE_HEADER_SIZE, "truncated mobile n-gram: " .. path)
    assert(header:sub(1, 8) == "TCSKNM02", "not a TCSKNM02 model: " .. path)

    local version, header_size, file_size, index_stride, _, uni_count, _, uni_off,
        bi_ctx_count, bi_index_count, bi_blocks_off, bi_index_off, tri_ctx_count,
        tri_index_count, _, tri_blocks_off, tri_index_off =
        string.unpack("<I4I4I8I4I4I4I4I8I4I4I8I8I8I4I4I8I8", header, 9)
    assert(version == 1 and header_size == MOBILE_HEADER_SIZE, "unsupported mobile n-gram version")
    assert(index_stride >= 16 and bi_blocks_off < bi_index_off, "invalid mobile bigram layout")
    assert(bi_index_off < tri_blocks_off and tri_blocks_off < tri_index_off, "invalid mobile trigram layout")
    local actual_size = assert(file:seek("end"))
    assert(actual_size == file_size, "mobile n-gram size mismatch")

    local function read_at(offset, count)
        assert(file:seek("set", offset), "cannot seek n-gram")
        local value = file:read(count)
        assert(value and #value == count, "truncated mobile n-gram")
        return value
    end

    local page_limit = limits and limits.page_bytes or MOBILE_CACHE_BYTES
    local context_limit = limits and limits.context_entries or CONTEXT_CACHE_ENTRIES
    local bigram_limit = limits and limits.bigram_entries or 8192
    local index_limit = limits and limits.index_pages or INDEX_CACHE_PAGES
    local index_misses, index_bytes_read = 0, 0
    -- Keep only each index page's first key resident. On the production model
    -- this replaces a multi-MiB string with a small directory and bounded pages.
    -- No model conversion, quantization, key reordering or lost records.
    local function open_index(offset, count)
        local index = {offset=offset, count=count, pages=math.ceil(count / INDEX_PAGE_RECORDS),
            cache=memo.new(index_limit)}
        if count <= INDEX_PAGE_RECORDS then
            index.data = read_at(offset, count * 16)
        else
            local keys = {}
            for page = 0, index.pages - 1 do
                keys[#keys + 1] = read_at(offset + page * INDEX_PAGE_RECORDS * 16, 8)
            end
            index.directory = table.concat(keys)
        end
        return index
    end
    local function index_page(index, page)
        if index.data then return index.data end
        local data = index.cache.values[page]
        if data then return data end
        local first = page * INDEX_PAGE_RECORDS
        data = read_at(index.offset + first * 16, math.min(INDEX_PAGE_RECORDS, index.count - first) * 16)
        index_misses, index_bytes_read = index_misses + 1, index_bytes_read + #data
        return memo.put(index.cache, page, data)
    end
    local function index_offset(index, record)
        local page = math.floor(record / INDEX_PAGE_RECORDS)
        return string.unpack("<I8", index_page(index, page), (record % INDEX_PAGE_RECORDS) * 16 + 9)
    end
    local unigrams = read_at(uni_off, uni_count * 8)
    local bi_index = open_index(bi_index_off, bi_index_count)
    local tri_index = open_index(tri_index_off, tri_index_count)
    local unknown = string.unpack("<f", unigrams, 5)
    -- Small resident section: decode once instead of binary-searching and
    -- unpacking it for every uncached trigram probability.
    local unigram_values = {}
    for position = 1, #unigrams, 8 do
        local key, probability = string.unpack("<i4f", unigrams, position)
        unigram_values[key] = probability
    end

    local cache = {b={}, t={}}
    local cache_bytes = 0
    local lru_head = nil
    local lru_tail = nil
    local context_caches = {
        b = memo.new_columns(context_limit, 4),
        t = memo.new_columns(context_limit, 4)
    }

    local function unlink(entry)
        if entry.previous then
            entry.previous.next = entry.next
        else
            lru_head = entry.next
        end
        if entry.next then
            entry.next.previous = entry.previous
        else
            lru_tail = entry.previous
        end
    end

    local function touch(entry)
        if lru_head == entry then
            return
        end
        if entry.previous or entry.next or lru_tail == entry then
            unlink(entry)
        end
        entry.previous = nil
        entry.next = lru_head
        if lru_head then
            lru_head.previous = entry
        else
            lru_tail = entry
        end
        lru_head = entry
    end

    local function index_key(data, index)
        return string.unpack("<I8", data, index * 16 + 1)
    end

    local function find_page(index, count, key)
        local page = 0
        if index.directory then
            local low, high = 0, index.pages
            while low < high do
                local middle = low + math.floor((high - low) / 2)
                if string.unpack("<I8", index.directory, middle * 8 + 1) <= key then
                    low = middle + 1
                else high = middle end
            end
            if low == 0 then return -1 end
            page = low - 1
        end
        local first = page * INDEX_PAGE_RECORDS
        local data = index_page(index, page)
        local low, high = 0, math.min(INDEX_PAGE_RECORDS, count - first)
        while low < high do
            local middle = low + math.floor((high - low) / 2)
            if index_key(data, middle) <= key then low = middle + 1 else high = middle end
        end
        return first + low - 1
    end

    local function get_page(kind, index_data, index_count, page, section_end)
        local page_cache = cache[kind]
        local entry = page_cache[page]
        if entry then
            touch(entry)
            return entry.data
        end
        local offset = index_offset(index_data, page)
        local next_offset = section_end
        if page + 1 < index_count then
            next_offset = index_offset(index_data, page + 1)
        end
        local data = read_at(offset, next_offset - offset)
        performance.page_misses = performance.page_misses + 1
        performance.page_bytes = performance.page_bytes + #data
        entry = { kind = kind, page = page, data = data, bytes = #data }
        page_cache[page] = entry
        cache_bytes = cache_bytes + entry.bytes
        touch(entry)
        while cache_bytes > page_limit and lru_tail and lru_tail ~= entry do
            local victim = lru_tail
            unlink(victim)
            cache[victim.kind][victim.page] = nil
            cache_bytes = cache_bytes - victim.bytes
        end
        return data
    end

    local function lookup_unigram(key, fallback)
        return unigram_values[key] or fallback
    end

    local function lookup_successor(data, position, count, lambda, target)
        local low, high = 0, count
        while low < high do
            local middle = low + math.floor((high - low) / 2)
            local value = string.unpack("<I4", data, position + middle * 8)
            if value < target then low = middle + 1 else high = middle end
        end
        if low < count then
            local at = position + low * 8
            if string.unpack("<I4", data, at) == target then
                return lambda, string.unpack("<f", data, at + 4), true
            end
        end
        return lambda, 0.0, false
    end

    local function lookup_context(kind, index_data, index_count, context_count, section_end, key, target)
        local context_cache = context_caches[kind]
        local slot = context_cache.values[key]
        if slot then
            local columns = context_cache.columns
            local page = columns[1][slot]
            if page == false then return 1.0, 0.0, false end
            local data = get_page(kind, index_data, index_count, page, section_end)
            return lookup_successor(data, columns[2][slot], columns[3][slot], columns[4][slot], target)
        end

        local function remember(page, position, count, lambda)
            memo.put_columns(context_cache, key, page, position or 0, count or 0, lambda or 1.0)
        end

        local page = find_page(index_data, index_count, key)
        if page < 0 then
            remember(false)
            return 1.0, 0.0, false
        end
        local data = get_page(kind, index_data, index_count, page, section_end)
        local position = 1
        local remaining = math.min(index_stride, context_count - page * index_stride)
        for _ = 1, remaining do
            local context_key, lambda, successor_count
            context_key, lambda, successor_count, position = string.unpack("<I8fI4", data, position)
            if context_key == key then
                remember(page, position, successor_count, lambda)
                return lookup_successor(data, position, successor_count, lambda, target)
            end
            if context_key > key then
                remember(false)
                return 1.0, 0.0, false
            end
            position = position + successor_count * 8
        end
        remember(false)
        return 1.0, 0.0, false
    end

    -- A bigram query is shared by multiple trigram histories and by isolation
    -- checks. Keep raw float values and observed-ness distinct (zero can be an
    -- observed record). The 42-bit pair key is exact even on double-only Lua.
    local bigram_cache = memo.new_columns(bigram_limit, 3)
    local bigram_hits, bigram_misses = 0, 0
    local function lookup_bigram(context, target)
        local key = pack2(context, target)
        local cached = bigram_cache.values[key]
        if cached then
            bigram_hits = bigram_hits + 1
            local columns = bigram_cache.columns
            return columns[1][cached], columns[2][cached], columns[3][cached]
        end
        bigram_misses = bigram_misses + 1
        local lambda, probability, observed = lookup_context(
            "b", bi_index, bi_index_count, bi_ctx_count, bi_index_off, context, target)
        memo.put_columns(bigram_cache, key, lambda, probability, observed)
        return lambda, probability, observed
    end

    local function logp(prev2, prev1, target)
        local first = scalar(prev2)
        local second = scalar(prev1)
        local third = scalar(target)
        local unigram = lookup_unigram(third, unknown)
        local bigram_lambda, bigram_probability = lookup_bigram(second, third)
        local bigram = bigram_probability + bigram_lambda * unigram
        local trigram_lambda, trigram_probability = lookup_context(
            "t", tri_index, tri_index_count, tri_ctx_count, tri_index_off,
            pack2(first, second), third)
        local probability = trigram_probability + trigram_lambda * bigram
        return math.log(math.max(probability, 1e-300))
    end

    local function has_observed_bigram(prev, target)
        local _, _, observed = lookup_bigram(scalar(prev), scalar(target))
        return observed
    end

    local function trim_caches()
        cache, cache_bytes, lru_head, lru_tail = {b={}, t={}}, 0, nil, nil
        context_caches = {b=memo.new_columns(context_limit, 4), t=memo.new_columns(context_limit, 4)}
        bigram_cache = memo.new_columns(bigram_limit, 3)
        bi_index.cache, tri_index.cache = memo.new(index_limit), memo.new(index_limit)
    end
    local model
    local function configure_cache(values)
        local p, c, b, i = values.page_bytes, values.context_entries, values.bigram_entries, values.index_pages
        assert(p >= 1 and c >= 1 and b >= 1 and i >= 1, "invalid model cache limits")
        if page_limit == p and context_limit == c and bigram_limit == b and index_limit == i then return end
        page_limit, context_limit, bigram_limit, index_limit = p, c, b, i
        model.cache_limit_bytes = page_limit
        trim_caches()
    end
    local function resident_bytes(index)
        return #(index.data or index.directory)
    end
    local function cached_bytes(index)
        local bytes = 0
        for _, data in pairs(index.cache.values) do bytes = bytes + #data end
        return bytes
    end
    model = {
        path = path,
        bytes = file_size,
        format = "TCSKNM02",
        -- Packed index bytes exclude the decoded unigram Lua table and metadata.
        resident_index_bytes = resident_bytes(bi_index) + resident_bytes(tri_index),
        source_index_bytes = uni_count * 8 + bi_index_count * 16 + tri_index_count * 16,
        cache_limit_bytes = page_limit,
        cache_status = function()
            return {page_bytes=cache_bytes, page_limit=page_limit,
                resident_index_bytes=resident_bytes(bi_index) + resident_bytes(tri_index),
                index_cache_bytes=cached_bytes(bi_index) + cached_bytes(tri_index),
                index_cache_limit=2 * index_limit * INDEX_PAGE_RECORDS * 16,
                index_misses=index_misses, index_bytes_read=index_bytes_read,
                bigram_entries=#bigram_cache.keys, bigram_limit=bigram_limit,
                context_entries=#context_caches.b.keys + #context_caches.t.keys,
                context_limit=2 * context_limit, bigram_hits=bigram_hits, bigram_misses=bigram_misses}
        end,
        configure_cache = configure_cache,
        trim_caches = trim_caches,
        logp = logp,
        has_observed_bigram = has_observed_bigram,
        close = function()
            if file then file:close(); file = nil end
            trim_caches()
        end
    }
    return model
    end
    local ok, model = pcall(read_model)
    if not ok then
        if file then file:close() end
        error(model, 0)
    end
    return model
end

function kn_reader.load(path, limits)
    local file = assert(io.open(path, "rb"), "cannot open n-gram: " .. path)
    local magic = file:read(8)
    file:close()
    if magic == "TCSKNM02" then
        return load_mobile(path, limits)
    end
    return load_legacy(path)
end

function kn_reader.try_load(limits)
    local failures = {}
    for _, path in ipairs(kn_reader.candidate_paths()) do
        if file_exists(path) then
            local ok, model = pcall(kn_reader.load, path, limits)
            if ok then
                return model, nil
            end
            failures[#failures + 1] = path .. ": " .. tostring(model)
        end
    end
    if #failures > 0 then
        return nil, table.concat(failures, " | ")
    end
    return nil, "no sentence n-gram model found"
end
return kn_reader
end
return M
