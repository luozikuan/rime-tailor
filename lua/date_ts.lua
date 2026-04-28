--[[
组件名称：时间转换器
描述：检测到输入内容有“今天”、“明天”、“后天”、“昨天”、“前天”等关键词时，自动生成对应的日期字符串作为候选项，方便用户快速输入当前或相对日期。
--]]

--------------------------------------------------------------------------------------

-- 日期偏移映射表（单位：天）
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

local function date_ts(input, env)
    for cand in input:iter() do
        yield(cand)

        local text = cand.text
        local offset = date_offsets[text]

        -- 如果候选词是日期关键词，追加对应的日期候选项
        if offset then
            local target_time = os.time() + offset * 24 * 60 * 60
            local date_str = os.date("%Y%m%d", target_time)
            local date_str2 = os.date("%Y-%m-%d", target_time)
            yield(Candidate("date", cand.start, cand._end, date_str, "〔" .. text .. "〕"))
            yield(Candidate("date", cand.start, cand._end, date_str2, "〔" .. text .. "〕"))
        end
    end
end

return date_ts



