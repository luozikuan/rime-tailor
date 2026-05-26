--- 单字模式
function single_char(input, env)
	local single_option = env.engine.context:get_option("single_char")
	local input_text = env.engine.context.input
	for cand in input:iter() do
        local is_all_english = cand.text:match("^[A-Za-z]+$") ~= nil
		if (not single_option or utf8.len(cand.text) == 1 or input_text:find("^`") or is_all_english) then
			yield(cand)
		end
	end
end

return single_char
