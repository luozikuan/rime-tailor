-- 反查注释：在候选注释里显示该字/词在虎整句中的编码（虎码）。
--
-- 为什么需要这个文件：反查词典 pinyin 里只有拼音，候选本身不带虎码，
-- 所以光靠词典查出来的候选显示不出编码。虎码只能从 tiger_sentence.codes.txt
-- 反向索引得到。
--
-- 取码规则与 tiger_sentence.lua 的 build_lexicon_index 对齐：
--   · 该表每行「文字<TAB>编码」，同一字可有多个码，行序即词频序（1 = 首选）。
--   · 表里出现过的字/词 → 取文件序第一的那条编码。
--   · 单字若首码是单字母简码（方案自己也不用它组句），改取「首选拼写」：
--     长度 ≥ 2 的码中，该字在该码里排第 1 的，取最短的那个；否则取最短的 ≥2 码。
--   · 表里没有的词（如「你好」）→ 按单字主码逐字拼接显示，用空格分隔。
local M = {}

local index = nil

local function data_directories()
    local directories = {}
    if rime_api then
        for _, name in ipairs({ "get_user_data_dir", "get_shared_data_dir" }) do
            local fn = rime_api[name]
            if type(fn) == "function" then
                local ok, path = pcall(fn)
                if ok and type(path) == "string" and path ~= "" then
                    directories[#directories + 1] = path
                end
            end
        end
    end
    return directories
end

local function read_codes()
    for _, directory in ipairs(data_directories()) do
        local ok, handle = pcall(io.open, directory .. "/tiger_sentence.codes.txt", "rb")
        if ok and handle then
            local content = handle:read("*a")
            handle:close()
            if content then return content end
        end
    end
    return nil
end

local function utf_chars(text)
    local chars = {}
    if utf8 then
        for _, codepoint in utf8.codes(text) do
            chars[#chars + 1] = utf8.char(codepoint)
        end
    end
    return chars
end

local function build_index(content)
    if content:sub(1, 3) == "\239\187\191" then content = content:sub(4) end

    local words_of_code = {}   -- code -> { word, ... }，文件序
    local codes_of_word = {}   -- word -> { code, ... }，文件序
    local seen = {}

    for line in content:gmatch("[^\r\n]+") do
        local trimmed = line:gsub("^%s+", ""):gsub("%s+$", "")
        if trimmed ~= "" and trimmed:sub(1, 1) ~= "#" then
            local word, code = trimmed:match("^(%S+)%s+(%S+)")
            if word and code and code:match("^[a-z]+$") then
                local key = word .. "\0" .. code
                if not seen[key] then
                    seen[key] = true
                    local wl = words_of_code[code]
                    if not wl then wl = {}; words_of_code[code] = wl end
                    wl[#wl + 1] = word
                    local cl = codes_of_word[word]
                    if not cl then cl = {}; codes_of_word[word] = cl end
                    cl[#cl + 1] = code
                end
            end
        end
    end

    -- 单字主码：与方案 primary[] 同规则。
    local primary = {}
    for word, codes in pairs(codes_of_word) do
        if #utf_chars(word) == 1 then
            local best_first, best_any, shortest
            for i = 1, #codes do
                local code = codes[i]
                if not shortest or #code < #shortest then shortest = code end
                if #code >= 2 then
                    if not best_any or #code < #best_any then best_any = code end
                    local wl = words_of_code[code]
                    if wl and wl[1] == word then
                        if not best_first or #code < #best_first then best_first = code end
                    end
                end
            end
            primary[word] = best_first or best_any or shortest
        end
    end

    return { codes_of_word = codes_of_word, primary = primary }
end

local function ensure_index()
    if not index then
        local content = read_codes()
        if content then index = build_index(content) end
    end
    return index
end

local function lookup(text)
    local idx = ensure_index()
    if not idx then return nil end

    -- 表里收录过：取文件序第一的码；单字母简码则换成主码。
    local codes = idx.codes_of_word[text]
    if codes then
        local code = codes[1]
        if #code >= 2 then return code end
        return idx.primary[text] or code
    end

    -- 表里没有的词：按单字主码逐字拼接。
    local chars = utf_chars(text)
    if #chars == 0 then return nil end
    local parts = {}
    for i = 1, #chars do
        local code = idx.primary[chars[i]]
        if not code then return nil end
        parts[#parts + 1] = code
    end
    return table.concat(parts, " ")
end

-- 只给反查出来的候选加注释，正常整句打字的候选不受影响。
local function is_reverse_lookup(env)
    local composition = env.engine.context.composition
    if not composition or composition:empty() then return false end
    local segment = composition:back()
    return segment:has_tag("rvlk")
end

local function filter(input, env)
    local annotate = is_reverse_lookup(env)
    for candidate in input:iter() do
        if annotate then
            local code = lookup(candidate.text)
            if code then candidate.comment = code end
        end
        yield(candidate)
    end
end

M.func = filter
return M
