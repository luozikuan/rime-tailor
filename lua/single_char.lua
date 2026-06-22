--- 单字模式
function single_char(input, env)
	local single_option = env.engine.context:get_option("single_char")
	local input_text = env.engine.context.input
	for cand in input:iter() do
		if (not single_option or utf8.len(cand.text) == 1 or input_text:find("`")
		    or cand.text == "……" or cand.text == "——")
		then
			yield(cand)
		end
	end
end

return single_char
