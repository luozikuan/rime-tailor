--[[
组件名称：Preedit Tips（Processor）
描述：从文件加载提示数据，在 preedit 区显示匹配提示，并支持按键直接上屏。
      数据文件格式（制表符分隔）：值<TAB>键
      当输入码或选中候选词匹配某个键时，在 segment prompt 显示对应值。

配置示例：
  preedit_tips:
    file: lua/data/tips_show.txt  # 数据文件路径，缺省为此值
    tips_key: "comma"             # 上屏按键，缺省为 comma
--]]

-- 全局 lookup 表：key → value（跨 schema 共享，避免重复加载）
local _db = {}
local _loaded_path = nil

local function resolve_path(relative)
    if not relative then return nil end
    local user_path = rime_api.get_user_data_dir() .. "/" .. relative
    local f = io.open(user_path, "r")
    if f then f:close(); return user_path end
    local shared_path = rime_api.get_shared_data_dir() .. "/" .. relative
    f = io.open(shared_path, "r")
    if f then f:close(); return shared_path end
    return nil
end

local function load_file(path)
    if _loaded_path == path then return end
    _db = {}
    local f = io.open(path, "r")
    if not f then return end
    for line in f:lines() do
        local value, key = line:match("([^\t]+)\t([^\t]+)")
        if key and value then
            _db[key] = value
        end
    end
    f:close()
    _loaded_path = path
end

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

local function get_tip(keys)
    for _, k in ipairs(keys) do
        if k and k ~= "" then
            local offset = date_offsets[k]
            if offset then
                local target_time = os.time() + offset * 86400
                local date_str = os.date("%Y%m%d", target_time)
                return "日期：" .. date_str
            else
                local v = _db[k]
                if v then return v end
            end
        end
    end
    return nil
end

---更新 segment prompt
local function update_prompt(context, env)
    env.current_tip = nil

    if not context.input or context.input == "" then return end

    local segment = context.composition:back()
    if not segment then return end

    local cand = context:get_selected_candidate() or {}
    local page_size = env.engine.schema.page_size

    -- 第一页同时匹配输入码和候选词，翻页后只匹配候选词
    local keys
    if segment.selected_index < page_size then
        keys = { context.input, cand.text }
    else
        keys = { cand.text }
    end

    env.current_tip = get_tip(keys)

    if env.current_tip and env.current_tip ~= "" then
        segment.prompt = "〔" .. env.current_tip .. "〕"
        env.last_prompt = segment.prompt
    elseif segment.prompt ~= "" and env.last_prompt == segment.prompt then
        segment.prompt = ""
        env.last_prompt = nil
    end
end

local P = {}

function P.init(env)
    local config = env.engine.schema.config

    -- 加载数据文件
    local file_rel = config:get_string("preedit_tips/file")
    if not file_rel or file_rel == "" then
        file_rel = "lua/data/tips_show.txt"
    end
    local path = resolve_path(file_rel)
    if path then
        load_file(path)
    end

    -- 上屏按键
    P.tips_key = config:get_string("preedit_tips/tips_key")
    if not P.tips_key or P.tips_key == "" then
        P.tips_key = "comma"
    end

    -- 监听输入变化以更新 prompt
    local context = env.engine.context
    env.tips_conn = context.update_notifier:connect(function(ctx)
        update_prompt(ctx, env)
    end)
end

function P.fini(env)
    if env.tips_conn then
        env.tips_conn:disconnect()
        env.tips_conn = nil
    end
end

local function proc_date(tip, ch)
    local sep
    if ch == P.tips_key then
        sep = ""
    elseif ch == "minus" then
        sep = "-"
    elseif ch == "slash" then
        sep = "/"
    else
        return nil
    end

    local y, m, d = tip:match("日期：(%d%d%d%d)(%d%d)(%d%d)$")
    if y then
        if sep == "" then
            return y .. m .. d
        else
            return y .. sep .. m .. sep .. d
        end
    end
    return nil
end

local function proc_other(tip, ch)
    if ch ~= P.tips_key then return nil end

    local text = tip:match("[^：]+：(.-)$")
    return text
end

function P.func(key, env)
    local context = env.engine.context

    if not env.current_tip
        or env.current_tip == ""
    then
        return 2  -- kNoop
    end

    local ch = key:repr()
    local tip = env.current_tip

    -- 提取冒号后面的实际内容进行上屏
    local commit_txt
    if tip:find("日期：") then
        commit_txt = proc_date(tip, ch)
    else
        commit_txt = proc_other(tip, ch)
    end
    if commit_txt and #commit_txt > 0 then
        env.engine:commit_text(commit_txt)
        context:clear()
        return 1  -- kAccepted
    end
    return 2  -- kNoop
end

return P
