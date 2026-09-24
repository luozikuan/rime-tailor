-- Compact final-stage lexical evidence for TigerSentence.
--
-- The on-disk TCSLEX01 format is a fixed-size Bloom filter.  It keeps tens of
-- thousands of useful 2--4 character words in roughly 150 KiB and loads as
-- one Lua string, avoiding the multi-megabyte table overhead of a trie.

local M = {}
local MAGIC = "TCSLEX01"
local HEADER_SIZE = 32
local MODULUS = 4294967291

local function u32le(data, offset)
    local a, b, c, d = data:byte(offset + 1, offset + 4)
    if not d then return nil end
    return a + b * 256 + c * 65536 + d * 16777216
end

local function character_at(text, index)
    local byte = text:byte(index)
    if not byte then return nil, index end
    local length = byte >= 0xF0 and 4 or byte >= 0xE0 and 3 or byte >= 0xC0 and 2 or 1
    return text:sub(index, index + length - 1), index + length
end

local function utf_chars(text)
    local chars = {}
    if utf8 and utf8.codes then
        for _, codepoint in utf8.codes(text) do chars[#chars + 1] = utf8.char(codepoint) end
        return chars
    end
    local index = 1
    while index <= #text do
        local ch
        ch, index = character_at(text, index)
        chars[#chars + 1] = ch
    end
    return chars
end

-- Integer intermediates stay below 2^53, so this is exact in both ordinary
-- Lua integer builds and LuaJIT's double-number build.  Parser-level bitwise
-- operators are intentionally avoided for Lua 5.1/LuaJIT compatibility.
local function hashes(text)
    local first, second = 2166136261, 16777619
    for index = 1, #text do
        local byte = text:byte(index)
        first = (first * 131 + byte + 17) % MODULUS
        second = (second * 137 + byte + 53) % MODULUS
    end
    if second == 0 then second = 1 end
    return first, second
end

local function contains(model, text, cache)
    if not model or not model.bits or text == "" then return false end
    if cache and cache[text] ~= nil then return cache[text] end
    local first, second = hashes(text)
    for index = 0, model.hash_count - 1 do
        local bit = (first + index * second + index * index * 97) % model.bit_count
        local byte = model.bits:byte(math.floor(bit / 8) + 1)
        local mask = 2 ^ (bit % 8)
        if math.floor(byte / mask) % 2 == 0 then
            if cache then cache[text] = false end
            return false
        end
    end
    if cache then cache[text] = true end
    return true
end

local function load(path)
    local handle, open_error = io.open(path, "rb")
    if not handle then return nil, open_error end
    local data = handle:read("*a") or ""
    handle:close()
    if #data < HEADER_SIZE or data:sub(1, 8) ~= MAGIC then
        return nil, "not a TCSLEX01 lexical model"
    end
    local version = u32le(data, 8)
    local entry_count = u32le(data, 12)
    local bit_count = u32le(data, 16)
    local hash_count = u32le(data, 20)
    local minimum_length = u32le(data, 24)
    local maximum_length = u32le(data, 28)
    if version ~= 1 or not entry_count or entry_count < 1 or
        not bit_count or bit_count < 8 or bit_count % 8 ~= 0 or
        not hash_count or hash_count < 1 or hash_count > 32 or
        not minimum_length or not maximum_length or
        minimum_length < 2 or maximum_length < minimum_length or maximum_length > 16 then
        return nil, "invalid TCSLEX01 header"
    end
    if #data ~= HEADER_SIZE + bit_count / 8 then
        return nil, "TCSLEX01 size does not match header"
    end
    return {
        path = path,
        bits = data:sub(HEADER_SIZE + 1),
        bit_count = bit_count,
        hash_count = hash_count,
        entry_count = entry_count,
        minimum_length = minimum_length,
        maximum_length = maximum_length,
        bytes = #data
    }
end

function M.load_first(paths)
    local first_error = nil
    for _, path in ipairs(paths or {}) do
        local handle = io.open(path, "rb")
        if handle then
            handle:close()
            local model, load_error = load(path)
            if model then return model end
            first_error = first_error or (path .. ": " .. tostring(load_error))
        end
    end
    return nil, first_error
end

function M.contains(model, text)
    local length = #utf_chars(text)
    return model and length >= model.minimum_length and length <= model.maximum_length and
        contains(model, text) or false
end

-- Maximum-weight non-overlapping word cover.  A longer dictionary word gets
-- a small bonus, but overlapping substrings cannot all collect rewards.
function M.score(model, text, lookup_cache)
    if not model or not text or text == "" then return 0.0 end
    local chars = utf_chars(text)
    local count = #chars
    local best = { [0] = 0.0 }
    for finish = 1, count do
        best[finish] = best[finish - 1]
        for length = model.minimum_length, model.maximum_length do
            local start = finish - length
            if start < 0 then break end
            local word = table.concat(chars, "", start + 1, finish)
            if contains(model, word, lookup_cache) then
                local value = best[start] + 1.0 + 0.2 * (length - 2)
                if value > best[finish] then best[finish] = value end
            end
        end
    end
    return best[count] or 0.0
end

M.load = load
M.hashes = hashes
M.magic = MAGIC
return M
