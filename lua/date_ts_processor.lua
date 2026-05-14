--[[
组件名称：日期快捷上屏（Processor）
描述：拦截 `,` `-` `/` 按键，当候选带日期标记时以对应格式上屏
  `,` → 20260514
  `-` → 2026-05-14
  `/` → 2026/05/14
--]]

local function processor(key, env)
    local context = env.engine.context
    if not context:has_menu() then return 2 end

    local ch = key:repr()
    local sep
    if ch == "comma" then
        sep = ""
    elseif ch == "minus" then
        sep = "-"
    elseif ch == "slash" then
        sep = "/"
    else
        return 2
    end

    local cand = context:get_selected_candidate()
    if not cand then return 2 end

    local preedit = cand.preedit or ""
    local y, m, d = preedit:match("〔(%d%d%d%d)(%d%d)(%d%d) 📅〕$")
    if not y then return 2 end

    local result
    if sep == "" then
        result = y .. m .. d
    else
        result = y .. sep .. m .. sep .. d
    end

    env.engine:commit_text(result)
    context:clear()
    return 1 -- kAccepted
end

return processor
