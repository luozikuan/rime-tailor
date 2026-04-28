-- tone_fallback.lua
-- 声调回退处理器：连续输入声调数字(7890)时，自动替换为最后一个，而非追加
-- 用法: 在 schema.yaml 中 engine/processors 列表添加:
--   - lua_processor@*tone_fallback
--
-- 可选配置 (schema.yaml):
--   tone_fallback:
--     tone_chars: "7890"         # 声调字符集合（按键字符），默认 7890
--     exclude_patterns:           # 排除模式(匹配到则不触发回退)
--       - "`"                     # 反查键，含此字符时跳过
--
-- 工作原理:
--   输入 ni9 后直接输入 0 → 输入变为 ni90 → 自动压缩为 ni0
--   即：连续的声调数字只保留最后一个

local M = {}

local K_REJECT, K_ACCEPT, K_NOOP = 0, 1, 2
local DEFAULT_TONE_CHARS = "7890"

local function normalize_namespace(ns)
    if not ns or ns == "" then
        return "tone_fallback"
    end
    return ns:gsub("^%*", "")
end

-- 由字符集合构建键码查找表（仅支持单字节按键字符）
local function build_tone_keycode_set(chars)
    local keycodes = {}
    local charset = {}
    for i = 1, #chars do
        local c = chars:sub(i, i)
        keycodes[string.byte(c)] = true
        charset[c] = true
    end
    return keycodes, charset
end

-- 读取声调字符配置：支持字符串或列表，空值时回退默认值
local function load_tone_chars(config, path)
    local direct = config:get_string(path)
    if direct and direct ~= "" then
        return direct
    end

    local list = config:get_list(path)
    if not list then
        return DEFAULT_TONE_CHARS
    end

    local chars = {}
    for i = 0, list.size - 1 do
        local val = config:get_string(path .. "/@" .. i)
        if val and val ~= "" then
            table.insert(chars, val)
        end
    end

    local merged = table.concat(chars, "")
    if merged == "" then
        return DEFAULT_TONE_CHARS
    end
    return merged
end

function M.init(env)
    local config = env.engine.schema.config
    local ns = normalize_namespace(env.name_space)

    -- 声调字符集合，默认 7890
    env.tone_chars = load_tone_chars(config, ns .. "/tone_chars")
    env.tone_keycodes, env.tone_charset = build_tone_keycode_set(env.tone_chars)

    -- 排除模式列表
    env.exclude_strings = {}
    local exc_path = ns .. "/exclude_patterns"
    local exc_list = config:get_list(exc_path)
    if exc_list then
        for i = 0, exc_list.size - 1 do
            local val = config:get_string(exc_path .. "/@" .. i)
            if val then table.insert(env.exclude_strings, val) end
        end
    else
        -- 默认排除反查键
        table.insert(env.exclude_strings, "`")
    end

end

function M.fini(env)
end

function M.func(key, env)
    -- 释放事件忽略
    if key:release() then return K_NOOP end

    -- 修饰键忽略
    if key:ctrl() or key:alt() or key:super() then
        return K_NOOP
    end

    local ctx = env.engine.context
    local kc = key.keycode

    -- 只处理配置中的声调键
    if not env.tone_keycodes[kc] then
        return K_NOOP
    end

    -- 必须在输入状态中
    local input = ctx.input or ""
    if input == "" or not ctx:is_composing() then
        return K_NOOP
    end

    -- 检查排除模式 (如反查模式)
    for _, s in ipairs(env.exclude_strings) do
        if input:find(s, 1, true) then
            return K_NOOP
        end
    end

    local caret = ctx.caret_pos
    if caret == nil then caret = #input end
    if caret < 0 then caret = 0 end
    if caret > #input then caret = #input end
    local left = (caret > 0) and input:sub(1, caret) or ""

    local last_char = left:sub(-1)
    if env.tone_charset[last_char] then
        -- 在新声调进入前删掉左侧相邻旧声调，最终保留最后输入的那个。
        ctx:pop_input(1)
    end

    return K_NOOP
end

return M
