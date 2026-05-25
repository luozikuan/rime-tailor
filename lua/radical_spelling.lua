-- radical_spelling.lua
-- 使用反查词典按需查询字根/编码，避免启动时全量加载 txt 占用内存
local radical = require("radical")

local CODE_PATTERN = "[a-z ]+"

local function init(env)
	radical.init_lookup(env, { "lua_reverse_db/spelling" }, "radical_spelling")
end

-- 主过滤函数
local function filter(input, env)
	-- 检查 radical_spelling 开关是否开启
	local ctx = env.engine.context
	local show_radical = ctx:get_option("radical_spelling")

	local raw_input = ctx.input
	local input_len = #raw_input

	for cand in input:iter() do
		if string.sub(raw_input, 1, 1) ~= "~" then
			local text = cand.text
			local char_count = utf8.len(text)

			-- 仅处理纯中文候选（至少1个字符）
			if char_count and char_count >= 1 then
				local radicals_list = {}
				local codes_list = {}
				local all_found = true

				for ch in radical.utf8_chars(text) do
					local entry = radical.get_spelling_entry(env, ch, CODE_PATTERN)
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
					local merged_codes = radical.merge_items(codes_list)
					local radical_info = ""
					if string.sub(raw_input, 1, 1) == "`" then
						radical_info = cand.comment
						cand.comment = ""
					elseif show_radical or string.find(raw_input, "*") or merged_codes:sub(1, input_len) ~= raw_input then
						radical_info = merged_codes
					end

					-- 显示字根
					if show_radical then
						local merged_radicals = radical.merge_items(radicals_list)
						radical_info = merged_radicals .. "・" .. radical_info
					end

					if radical_info ~= "" then
						cand.comment = "〔" .. radical_info .. "〕" .. cand.comment
					end
				end
			end
		end
		yield(cand)
	end
end

local function fini(env)
	radical.fini_lookup(env)
end

return { init = init, func = filter, fini = fini }
