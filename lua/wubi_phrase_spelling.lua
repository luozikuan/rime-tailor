-- wubi_phrase_spelling.lua
-- 五笔词组字根显示处理：从 opencc comment 中提取编码，按五笔词组规则合并
-- 适配 opencc wubi_spelling 格式

-- 从 comment 中提取字根和编码
-- comment 格式示例（经过 comment_format 处理后）：
-- 词组: 医院〔一匚大丨〕 agsu 〔阝宀几丶〕 botq
local function extract_codes(comment)
    local radicals = {}
    local codes = {}
    -- 匹配 〔...〕 后面的编码（支持字母和分号）
    for radical, code in comment:gmatch("〔(.-)〕%s*([a-y;]+)") do
	    table.insert(radicals, radical)
        table.insert(codes, code)
    end
    return radicals, codes
end

-- 按五笔词组规则合并编码
-- 二字词: 1码12 + 2码12 → 取每字前两码
-- 三字词: 1码1 + 2码1 + 3码12 → 前两字各取第1码，第3字取前两码
-- 四字及以上: 1码1 + 2码1 + 3码1 + 末码1 → 各取第1码
local function merge_codes(codes, char_bytes)
    if #codes < 2 then
        return codes[1]  -- 不处理，返回第一个编码
    end

    local result = ""

    if #codes == 2 then
        -- 二字词：每字取前2码
        result = codes[1]:sub(1, 2*char_bytes) ..
                 codes[2]:sub(1, 2*char_bytes)
    elseif #codes == 3 then
        -- 三字词：前两字各取第1码，第3字取前2码
        result = codes[1]:sub(1, 1*char_bytes) ..
                 codes[2]:sub(1, 1*char_bytes) ..
                 codes[3]:sub(1, 2*char_bytes)
    else
        -- 四字及以上：取第1、2、3、末字的第1码
        result = codes[1]:sub(1, 1*char_bytes) ..
                 codes[2]:sub(1, 1*char_bytes) ..
                 codes[3]:sub(1, 1*char_bytes) ..
                 codes[#codes]:sub(1, 1*char_bytes)
    end

    return result
end

-- 主过滤函数
local function wubi_phrase_spelling(input, env)
    for cand in input:iter() do
        local comment = cand.comment

        -- 只处理有字根注释的情况
        if comment and comment ~= "" and comment:find("〕") then
            local text = cand.text
            local char_count = utf8.len(text)
            local radicals, codes = extract_codes(comment)

            -- 如果提取到的编码数量与字数匹配
            if #radicals == char_count and #codes == char_count then
                local merged_radicals = merge_codes(radicals, 3)
                local merged_codes = merge_codes(codes, 1)
                local new_comment = "〔" .. merged_radicals .. "〕"

                -- 获取用户输入码
                local input_code = env.engine.context.input or ""
                -- 判断是否需要显示 merged_codes：
                -- 1. merged_codes 不以 input_code 开头（触发了容错码）
                -- 2. 输入码包含 z（启用了反查或通配）
                if (#input_code > 1 and merged_codes:sub(1, #input_code) ~= input_code) or input_code:find("z") then
                    new_comment = new_comment .. merged_codes
                end

                yield(cand:to_shadow_candidate(cand.type, text, new_comment))
            else
                yield(cand:to_shadow_candidate(cand.type, text, ""))
            end
        else
            yield(cand)
        end
    end
end

return wubi_phrase_spelling



