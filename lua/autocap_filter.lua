--[[
	#302@abcdefg233  #305@Mirtle

	自动大写英文词汇：
	- 部分规则不做转换
	- 输入首字母大写，候选词转换为首字母大写： Hello → Hello
	- 输入至少前 2 个字母大写，候选词转换为全部大写： HEllo → HELLO

    大写时无法动态调整词频

    增强：当 table_translator 因大小写敏感无法产出英文候选时，
    通过 Memory API 以小写查询 easy_en 词典并转换大小写后输出。
--]]

local function init(env)
    -- 初始化 easy_en 词典 Memory 对象，用于大写输入时的小写回查
    local ok, mem = pcall(Memory, env.engine, env.engine.schema, "easy_en")
    if ok then
        env.easy_en_mem = mem
    end
end

local function autocap_filter(input, env)
    local code = env.engine.context.input -- 输入码
    local codeLen = #code
    local codeAllUCase = false
    local codeUCase = false
    -- 不转换：
    if codeLen == 1 or       -- 码长为 1
        code:find("^[%l%p]") -- 输入码首位为小写字母或标点
    then                     -- 输入码不满足条件不判断候选项
        for cand in input:iter() do
            yield(cand)
        end
        return
    ---- 输入码全大写
    -- elseif code == code:upper() then
    --     codeAllUCase = true
    -- 输入码前 2 - n 位大写
    elseif code:find("^%u%u+.*") then
        codeAllUCase = true
    -- 输入码首位大写
    elseif code:find("^%u.*") then
        codeUCase = true
    end

    local pureCode = code:gsub("[%s%p]", "")     -- 删除标点和空格的输入码
    local hasEnCand = false                       -- 是否已产生英文候选

    for cand in input:iter() do
        local text = cand.text                   -- 候选词
        local pureText = text:gsub("[%s%p]", "") -- 删除标点和空格的候选词
        -- 不转换：
        if
            text:find("[^%w%p%s]") or                 -- 候选词包含非字母和数字、非标点符号、非空格的字符
            text:find("%s") or                        -- 候选词中包含空格
            pureText:find("^" .. code) or             -- 输入码完全匹配候选词
            (cand.type ~= "completion" and            -- 单词与其对应的编码不一致
                pureCode:lower() ~= pureText:lower()) -- 例如 PS - Photoshop
        then
            yield(cand)
        -- 输入码前 2~10 位大写，候选词转换为全大写
        elseif codeAllUCase then
            hasEnCand = true
            text = text:upper()
            yield(Candidate(cand.type, 0, codeLen, text, cand.comment))
        -- 输入码首位大写，候选词转换为首位大写
        elseif codeUCase then
            hasEnCand = true
            text = text:gsub("^%a", string.upper)
            yield(Candidate(cand.type, 0, codeLen, text, cand.comment))
        else
            yield(cand)
        end
    end

    -- 大写输入无英文候选时，用小写查询 easy_en 词典并转为大写
    if not hasEnCand and (codeUCase or codeAllUCase) and env.easy_en_mem then
        local lower_code = pureCode:lower()
        if env.easy_en_mem:dict_lookup(lower_code, true, 50) then
            for entry in env.easy_en_mem:iter_dict() do
                local text = entry.text
                -- 只处理纯英文候选（跳过含中文或空格的条目）
                if text and not text:find("[^%w%p%s]") and not text:find("%s") then
                    if codeAllUCase then
                        text = text:upper()
                    elseif codeUCase then
                        text = text:gsub("^%a", string.upper)
                    end
                    yield(Candidate("completion", 0, codeLen, text, entry.comment or ""))
                end
            end
        end
    end
end

local function fini(env)
    env.easy_en_mem = nil
end

return { init = init, func = autocap_filter, fini = fini }
