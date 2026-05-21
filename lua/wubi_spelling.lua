-- wubi_spelling.lua
-- -- 纯 Lua 实现字根拆分显示，替代 opencc，因为 opencc 修改了 comment 之后会导致自造词失效
-- 直接加载 wubi_spelling.txt，按候选词逐字查表生成 comment

local spelling_table = nil

-- 加载 wubi_spelling.txt 到内存
local function load_spelling(env)
    if spelling_table then return end
    spelling_table = {}

    -- 查找 opencc 目录下的数据文件
    local path = rime_api.get_user_data_dir() .. "/lua/data/wubi_spelling.txt"
    local f = io.open(path, "r")
    if not f then
        log.warning("wubi_spelling: cannot open " .. path)
        return
    end

    for line in f:lines() do
        -- 格式: 字\t〔PUA字根〕编码
        local char, val = line:match("^([%z\1-\127\194-\244][\128-\191]*)\t(.+)$")
        if char and val then
            local radicals = val:match("〔(.-)〕")
            local code = val:match("〕([a-y;]+)")
            if radicals and code then
                spelling_table[char] = { radicals = radicals, code = code }
            end
        end
    end
    f:close()
end

-- UTF-8 逐字迭代
local function utf8_chars(s)
    local i = 1
    return function()
        if i > #s then return nil end
        local b = s:byte(i)
        local len = 1
        if b >= 0xF0 then len = 4
        elseif b >= 0xE0 then len = 3
        elseif b >= 0xC0 then len = 2
        end
        local char = s:sub(i, i + len - 1)
        i = i + len
        return char
    end
end

-- 按五笔词组规则合并编码/字根
-- char_bytes: 编码=1, PUA字根=3
local function merge_items(items, char_bytes)
    local n = #items
    if n < 2 then return items[1] end

    if n == 2 then
        return items[1]:sub(1, 2 * char_bytes) ..
               items[2]:sub(1, 2 * char_bytes)
    elseif n == 3 then
        return items[1]:sub(1, 1 * char_bytes) ..
               items[2]:sub(1, 1 * char_bytes) ..
               items[3]:sub(1, 2 * char_bytes)
    else
        return items[1]:sub(1, 1 * char_bytes) ..
               items[2]:sub(1, 1 * char_bytes) ..
               items[3]:sub(1, 1 * char_bytes) ..
               items[n]:sub(1, 1 * char_bytes)
    end
end

local function init(env)
    load_spelling(env)
end

-- 主过滤函数
local function filter(input, env)
    -- 检查 wubi_spelling 开关是否开启
    local ctx = env.engine.context
	local show_radical = ctx:get_option("wubi_spelling")

    local raw_input = ctx.input
    local input_len = #raw_input

    for cand in input:iter() do
		if string.sub(raw_input, 1, 1) ~= "~" then
			local text = cand.text
			local char_count = utf8.len(text)

			-- 仅处理纯中文候选（至少1个字符）
			if char_count and char_count >= 1 and spelling_table then
				local radicals_list = {}
				local codes_list = {}
				local all_found = true

				for ch in utf8_chars(text) do
					local entry = spelling_table[ch]
					if entry then
						table.insert(radicals_list, entry.radicals)
						table.insert(codes_list, entry.code)
					else
						all_found = false
						break
					end
				end

				if all_found and #codes_list == char_count then
					-- 显示正确编码
					local merged_codes = merge_items(codes_list, 1)
					if (input_len > 1 and merged_codes:sub(1, input_len) ~= raw_input)
						and string.sub(raw_input, 1, 1) ~= "z" then
						cand.comment = merged_codes .. cand.comment
					end

					-- 显示字根
					if show_radical then
						local merged_radicals = merge_items(radicals_list, 3)
						cand.comment = "〔" .. merged_radicals .. "〕" .. cand.comment
					end
				end
			end
        end
        yield(cand)
    end
end

return { init = init, func = filter }
