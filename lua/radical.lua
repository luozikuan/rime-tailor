local radical = {}

function radical.parse_lookup_value(val, code_pattern)
	if not val or val == "" then return nil end
	local radicals = val:match("〔(.-)〕")
	local code = val:match("〕(" .. (code_pattern or "[a-z ]+") .. ")")
	if radicals and code then
		return { radicals = radicals, code = code }
	end
	return nil
end

function radical.get_spelling_entry(env, char, code_pattern)
	local cached = env.spelling_cache[char]
	if cached ~= nil then
		return cached or nil
	end

	if not env.spelling_lookup then
		env.spelling_cache[char] = false
		return nil
	end

	local ok, raw = pcall(function()
		return env.spelling_lookup:lookup(char)
	end)
	if not ok then
		env.spelling_cache[char] = false
		return nil
	end

	local entry = radical.parse_lookup_value(raw, code_pattern)
	env.spelling_cache[char] = entry or false
	return entry
end

function radical.utf8_chars(s)
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

local function spelling_substring(text, start, len)
    local chars = {}
    for _, code in utf8.codes(text) do
        table.insert(chars, utf8.char(code))
    end

    local total = #chars
    if not len then
        len = total - start + 1
    end

    local result = {}
    for i = start, start + len - 1 do
        if i >= 1 and i <= total then
            table.insert(result, chars[i])
        else
            -- 如果索引超出范围，插入占位符
            table.insert(result, "~")
        end
    end

    return table.concat(result)
end

function radical.merge_items(items)
	local n = #items
	if n < 2 then return items[1] end

	if n == 2 then
		return spelling_substring(items[1], 1, 2) ..
			   spelling_substring(items[2], 1, 2)
	elseif n == 3 then
		return spelling_substring(items[1], 1, 1) ..
			   spelling_substring(items[2], 1, 1) ..
			   spelling_substring(items[3], 1, 2)
	else
		return spelling_substring(items[1], 1, 1) ..
			   spelling_substring(items[2], 1, 1) ..
			   spelling_substring(items[3], 1, 1) ..
			   spelling_substring(items[n], 1, 1)
	end
end

function radical.init_lookup(env, keys, default_dict, log_tag)
	local config = env.engine.schema.config
	local spelling_dict
	for _, key in ipairs(keys or {}) do
		local v = config:get_string(key)
		if v and v ~= "" then
			spelling_dict = v
			break
		end
	end
	spelling_dict = spelling_dict or default_dict

	env.spelling_cache = {}
	local ok, lookup = pcall(ReverseLookup, spelling_dict)
	if ok then
		env.spelling_lookup = lookup
		return
	end

	env.spelling_lookup = nil
	log.warning((log_tag or "radical") .. ": cannot init ReverseLookup for " .. tostring(spelling_dict))
end

function radical.fini_lookup(env)
	env.spelling_lookup = nil
	env.spelling_cache = nil
end

return radical
