--[[
组件名称：时间转换器（Filter）
描述：在日期关键词候选的 preedit 后面追加日期显示
--]]

local date_offsets = {
    ["日期"] = 0,
    ["今天"] = 0,
    ["明天"] = 1,
    ["后天"] = 2,
    ["昨天"] = -1,
    ["前天"] = -2,
    ["下周"] = 7,
    ["上周"] = -7,
}

local function filter(input, env)
    for cand in input:iter() do
        local offset = date_offsets[cand.text]
        if offset then
            local target_time = os.time() + offset * 86400
            local date_str = os.date("%Y%m%d", target_time)
            local genuine = cand:get_genuine()
            genuine.preedit = genuine.preedit .. "〔" .. date_str .. " 📅〕"
        end
        yield(cand)
    end
end

return filter
