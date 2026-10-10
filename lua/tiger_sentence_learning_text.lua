-- Canonical, editable UTF-8 learning journal. No legacy database import.
local M = {}
M.header = '# 虎整句自学习记录（每条学习行代表一次人工纠正；等级上限10）\n' ..
    '# 操作\t时间(UTC)\t片段\t编码\t前文\t本次升级\t模式\t记录编号\t撤销目标\n'
M.limit = 16 * 1024 * 1024
local function escape(s)
    return (s:gsub('\\', '\\\\'):gsub('\t', '\\t'):gsub('\r', '\\r'):gsub('\n', '\\n'))
end
local function unescape(s)
    local out, i, codes = {}, 1, {t='\t',r='\r',n='\n',['\\']='\\'}
    while i <= #s do
        local c = s:sub(i,i)
        if c == '\\' then
            i = i + 1; c = codes[s:sub(i,i)]
            assert(c, '自学习文件有未知或未完成的转义')
        end
        out[#out+1] = c; i = i + 1
    end
    return table.concat(out)
end
local function timestamp(s)
    local y,m,d,h,n,t = s:match('^(%d%d%d%d)%-(%d%d)%-(%d%d)T(%d%d):(%d%d):(%d%d)Z$')
    assert(y, '自学习时间格式错误')
    y,m,d,h,n,t = tonumber(y),tonumber(m),tonumber(d),tonumber(h),tonumber(n),tonumber(t)
    assert(y >= 1970 and m >= 1 and m <= 12 and d >= 1 and d <= 31 and h < 24 and n < 60 and t < 60, '自学习时间无效')
    local adjusted = y - (m <= 2 and 1 or 0)
    local era = math.floor(adjusted/400)
    local year = adjusted - era*400
    local month = m + (m > 2 and -3 or 9)
    local days = era*146097 + year*365 + math.floor(year/4) - math.floor(year/100) + math.floor((153*month+2)/5) + d-1 - 719468
    local value = days*86400 + h*3600 + n*60 + t
    assert(os.date('!%Y-%m-%dT%H:%M:%SZ',value) == s, '自学习日期无效')
    return value
end
function M.encode(e)
    return table.concat({'学习',os.date('!%Y-%m-%dT%H:%M:%SZ',e.time),escape(e.text),escape(e.code),escape(e.context),
        tostring(e.levels or 1),escape(e.mode),e.id,''}, '\t') .. '\n'
end
function M.parse(data, valid, include)
    assert(#data <= M.limit, '自学习文件超过16 MiB')
    data = data:gsub('^\239\187\191','')
    local events, seen, removed, sequence = {}, {}, {}, 0
    for raw_line in (data .. '\n'):gmatch('(.-)\n') do
        local line = raw_line:gsub('\r$','')
        if line ~= '' and line:sub(1,1) ~= '#' then
            assert(#line <= 8192, '自学习记录行过长')
            local f = {}; for v in (line .. '\t'):gmatch('(.-)\t') do f[#f+1]=v end
            assert(#f == 9 and #f[8] > 0 and #f[8] <= 128, '自学习文件格式错误')
            local time = timestamp(f[2]); sequence = sequence + 1
            local seq = f[8]:match('^记录(%d+)$'); sequence = math.max(sequence, tonumber(seq) or 0)
            if not seen[f[8]] then
                if f[1] == '学习' then
                    local e = {time=time,text=unescape(f[3]),code=unescape(f[4]),context=unescape(f[5]),levels=tonumber(f[6]),mode=unescape(f[7]),id=f[8]}
                    assert(e.levels and valid(e) and f[9] == '', '自学习片段或升级值无效')
                    if not include or include(e) then events[#events+1] = e end
                elseif f[1] == '撤销' then
                    assert(#f[9] > 0 and #f[9] <= 128, '撤销目标无效'); removed[f[9]]=true
                elseif f[1] == '清空' then
                    assert(f[9] == '', '清空记录无效'); events,removed={},{}
                else error('未知自学习操作') end
                seen[f[8]] = true
            end
        end
    end
    local visible = {}
    for _,e in ipairs(events) do if not removed[e.id] then visible[#visible+1]=e end end
    while #visible > 10000 do table.remove(visible,1) end
    return visible,seen,sequence
end
function M.open(name)
    assert(type(name)=='string' and name~='' and not name:find('[/\\:%z]') and name:sub(1,1)~='.', '无效的自学习文件名')
    assert(type(LevelDb)=='function', '缺少跨进程学习文件锁')
    local root = rime_api and rime_api.get_user_data_dir and rime_api.get_user_data_dir()
    assert(root and root~='', '无法取得Rime用户目录')
    -- LevelDb owns only the process lock. Learning records live exclusively in
    -- the named text file; no opaque data database or exported mirror is read.
    local guard = LevelDb('自学习锁-' .. name)
    assert(guard and guard:open(), '自学习文件正在被其他进程使用')
    local path = root .. '/' .. name .. '.txt'
    local db = {path=path, guard=guard, expected=0, separate=false}
    function db:close() if self.guard then self.guard:close(); self.guard=nil end end
    function db:read()
        local f, err, code = io.open(self.path,'rb')
        if not f then if code == 2 then return '' end; error(err or '读取自学习文件失败') end
        local data = f:read(M.limit+1) or ''; f:close()
        assert(#data<=M.limit,'自学习文件超过16 MiB')
        self.expected=#data;self.separate=#data>0 and data:sub(-1)~='\n'
        return data
    end
    function db:update(_, value)
        local f = io.open(self.path,'ab'); if not f then return false end
        if f:seek('end') ~= self.expected then f:close(); return false end
        local addition = (self.expected==0 and M.header or self.separate and '\n' or '') .. value
        if self.expected + #addition > M.limit then f:close(); return false end
        local ok = f:write(addition) and f:flush()
        local closed = f:close()
        if not ok or not closed then return false end
        self.expected=self.expected+#addition;self.separate=false;return true
    end
    return db
end
return M
