local M = {}

-- 硬编码的拼音映射数据，格式为 "pinyin[可用声调]"
local preedit_raw = {
  bb = {"bao[12345]"},
  bc = {"biang[2]"},
  bd = {"bu[12345]"},
  bg = {"bei[1345]"},
  bh = {"ba[12345]"},
  bj = {"bi[12345]"},
  bl = {"bai[12345]"},
  bm = {"bie[1234]"},
  bn = {"ban[1345]"},
  bq = {"bian[1345]"},
  bs = {"ben[134]", "bin[14]"},
  bx = {"bo[12345]"},
  by = {"bing[1345]", "beng[1234]"},
  bz = {"biao[1234]", "bang[1345]"},
  cb = {"chao[12345]"},
  cc = {"chui[124]"},
  cd = {"chu[12345]"},
  cf = {"chou[12345]"},
  cg = {"chun[123]"},
  ch = {"cha[12345]", "chua[1]"},
  cj = {"chi[12345]"},
  cl = {"chai[12345]"},
  cm = {"chuo[145]"},
  cn = {"chan[12345]"},
  cq = {"chuang[1234]"},
  cs = {"chen[12345]"},
  ct = {"chong[12345]"},
  cw = {"che[1345]"},
  cx = {"chuan[1234]", "chuai[1234]"},
  cy = {"cheng[12345]"},
  cz = {"chang[12345]"},
  db = {"dao[12345]"},
  dc = {"dui[134]"},
  dd = {"du[12345]"},
  df = {"dou[1345]", "diu[1]"},
  dg = {"dun[134]", "dei[3]"},
  dh = {"da[12345]", "dia[3]"},
  dj = {"di[12345]"},
  dl = {"dai[1345]"},
  dm = {"duo[12345]", "die[125]"},
  dn = {"dan[1345]"},
  dq = {"dian[1345]"},
  ds = {"den[4]"},
  dt = {"dong[1345]"},
  dw = {"de[1245]"},
  dx = {"duan[134]"},
  dy = {"ding[1345]", "deng[134]"},
  dz = {"dang[1345]", "diao[134]"},
  fb = {"cao[1234]"},
  fc = {"cui[134]"},
  fd = {"fu[12345]", "cu[1234]"},
  ff = {"fou[23]", "cou[4]"},
  fg = {"fei[1234]", "cun[12345]"},
  fh = {"fa[12345]", "ca[13]"},
  fj = {"ci[1234]"},
  fl = {"cai[12345]"},
  fm = {"cuo[12345]"},
  fn = {"fan[12345]", "can[1234]"},
  fs = {"fen[12345]", "cen[12]"},
  ft = {"cong[12]"},
  fw = {"ce[4]"},
  fx = {"fo[2]", "cuan[124]"},
  fy = {"feng[12345]", "ceng[1245]"},
  fz = {"fang[12345]", "cang[12]", "fiao[4]"},
  gb = {"gao[1345]"},
  gc = {"gui[1345]"},
  gd = {"gu[1345]"},
  gf = {"gou[134]"},
  gg = {"gei[13]", "gun[34]"},
  gh = {"gua[1345]", "ga[12345]"},
  gl = {"gai[1345]"},
  gm = {"guo[12345]"},
  gn = {"gan[134]"},
  gq = {"guang[1345]"},
  gs = {"gen[1234]"},
  gt = {"gong[1345]"},
  gw = {"ge[12345]"},
  gx = {"guan[134]", "guai[1345]"},
  gy = {"geng[134]"},
  gz = {"gang[12345]"},
  hb = {"hao[12345]", "pao[12345]"},
  hc = {"hui[12345]"},
  hd = {"hu[12345]", "pu[1234]"},
  hf = {"hou[12345]", "pou[123]"},
  hg = {"pei[124]", "hun[1245]", "hei[1]"},
  hh = {"hua[1245]", "pa[1245]", "ha[12345]"},
  hj = {"pi[12345]"},
  hl = {"hai[12345]", "pai[12345]"},
  hm = {"huo[12345]", "pie[13]"},
  hn = {"han[12345]", "pan[124]"},
  hq = {"pian[1234]", "huang[12345]"},
  hs = {"pin[1234]", "hen[234]", "pen[1245]"},
  ht = {"hong[1234]"},
  hw = {"he[1245]"},
  hx = {"huan[12345]", "po[12345]", "huai[24]"},
  hy = {"ping[12]", "peng[12345]", "heng[124]"},
  hz = {"hang[124]", "piao[1234]", "pang[12345]"},
  jb = {"kao[134]", "jiong[13]"},
  jc = {"jiang[1345]", "kui[1234]"},
  jd = {"ju[12345]", "ku[1345]"},
  jf = {"jiu[1345]", "kou[1345]"},
  jg = {"jun[14]", "kun[134]", "kei[1]"},
  jh = {"jia[12345]", "ka[13]", "kua[134]"},
  jj = {"ji[12345]"},
  jl = {"kai[1345]", "jue[1234]"},
  jm = {"jie[12345]", "kuo[4]"},
  jn = {"kan[1345]"},
  jq = {"jian[1345]", "kuang[12345]"},
  js = {"jin[134]", "ken[34]"},
  jt = {"kong[134]"},
  jw = {"ke[12345]"},
  jx = {"kuai[345]", "kuan[13]", "juan[134]"},
  jy = {"jing[1345]", "keng[15]"},
  jz = {"jiao[12345]", "kang[124]"},
  lb = {"lao[12345]"},
  lc = {"liang[2345]"},
  ld = {"lu[12345]"},
  lf = {"liu[12345]", "lou[12345]"},
  lg = {"lei[12345]", "lun[124]"},
  lh = {"la[12345]", "lia[3]"},
  lj = {"li[12345]"},
  ll = {"lai[245]"},
  lm = {"luo[12345]", "lie[1345]"},
  ln = {"lan[2345]"},
  lq = {"lian[2345]"},
  ls = {"lin[1234]"},
  lt = {"long[12345]"},
  lw = {"le[45]"},
  lx = {"lv[234]", "luan[234]", "lo[5]"},
  ly = {"ling[12345]", "leng[12345]"},
  lz = {"liao[12345]", "lang[12345]"},
  mb = {"mao[12345]", "sao[1345]"},
  mc = {"sui[12345]"},
  md = {"mu[2345]", "su[1245]"},
  mf = {"mou[123]", "sou[1345]", "miu[4]"},
  mg = {"mei[2345]", "sun[13]", "sei[2]"},
  mh = {"ma[12345]", "sa[1345]"},
  mj = {"si[1345]", "mi[12345]"},
  ml = {"mai[2345]", "sai[14]"},
  mm = {"suo[135]", "mie[14]"},
  mn = {"san[1345]", "man[12345]"},
  mq = {"mian[2345]"},
  ms = {"men[1245]", "min[23]", "sen[1]"},
  mt = {"song[12345]"},
  mw = {"me[5]", "se[45]"},
  mx = {"mo[12345]", "suan[134]"},
  my = {"ming[2345]", "meng[1234]", "seng[1]"},
  mz = {"miao[1234]", "mang[1235]", "sang[1345]"},
  nb = {"nao[12345]", "rao[234]"},
  nc = {"rui[234]", "niang[245]"},
  nd = {"ru[234]", "nu[234]"},
  nf = {"niu[12345]", "rou[24]", "nou[4]"},
  ng = {"nei[345]", "run[24]", "nun[2]"},
  nh = {"na[12345]", "rua[2]"},
  nj = {"ni[1234]", "ri[4]"},
  nl = {"nai[345]"},
  nm = {"nuo[234]", "ruo[24]", "nie[1245]"},
  nn = {"ran[23]", "nan[12345]"},
  nq = {"nian[12345]"},
  ns = {"ren[2345]", "nin[2]", "nen[45]"},
  nt = {"rong[23]", "nong[245]"},
  nw = {"re[34]", "ne[245]"},
  nx = {"nv[345]", "ruan[23]", "nuan[3]"},
  ny = {"neng[2]", "ning[234]", "reng[124]"},
  nz = {"rang[12345]", "niao[34]", "nang[12345]"},
  qb = {"ao[1234]", "qiong[12]"},
  qc = {"qiang[1234]"},
  qd = {"qu[12345]"},
  qf = {"qiu[1235]", "ou[1234]"},
  qg = {"qun[12]", "ei[1234]"},
  qh = {"a[12345]", "qia[1234]"},
  qj = {"qi[12345]"},
  ql = {"que[124]", "ai[12345]"},
  qm = {"qie[12345]"},
  qn = {"an[1234]"},
  qq = {"qian[12345]"},
  qs = {"qin[12345]", "en[145]"},
  qt = {"er[2345]"},
  qw = {"e[1234]"},
  qx = {"quan[12345]", "o[12345]"},
  qy = {"qing[12345]", "eng[1]"},
  qz = {"qiao[12345]", "ang[124]"},
  sb = {"shao[12345]"},
  sc = {"shui[2345]"},
  sd = {"shu[12345]"},
  sf = {"shou[12345]"},
  sg = {"shun[34]", "shei[2]"},
  sh = {"sha[1234]", "shua[134]"},
  sj = {"shi[12345]"},
  sl = {"shai[134]"},
  sm = {"shuo[145]"},
  sn = {"shan[1345]"},
  sq = {"shuang[13]"},
  ss = {"shen[12345]"},
  sw = {"she[12345]"},
  sx = {"shuai[134]", "shuan[14]"},
  sy = {"sheng[12345]"},
  sz = {"shang[1345]"},
  tb = {"tao[12345]"},
  tc = {"tui[1234]"},
  td = {"tu[12345]"},
  tf = {"tou[12345]"},
  tg = {"tun[12345]", "tei[1]"},
  th = {"ta[1345]"},
  tj = {"ti[12345]"},
  tl = {"tai[12345]"},
  tm = {"tuo[12345]", "tie[1345]"},
  tn = {"tan[12345]"},
  tq = {"tian[1234]"},
  tt = {"tong[12345]"},
  tw = {"te[4]"},
  tx = {"tuan[1234]"},
  ty = {"ting[1235]", "teng[125]"},
  tz = {"tiao[12345]", "tang[12345]"},
  wb = {"zao[12345]"},
  wc = {"zui[1345]"},
  wd = {"wu[12345]", "zu[123]"},
  wf = {"zou[134]"},
  wg = {"wei[12345]", "zun[134]", "zei[2]"},
  wh = {"za[1235]", "wa[12345]"},
  wj = {"zi[1345]"},
  wl = {"zai[1345]", "wai[1345]"},
  wm = {"zuo[12345]"},
  wn = {"wan[1234]", "zan[12345]"},
  ws = {"wen[12345]", "zen[34]"},
  wt = {"zong[134]"},
  ww = {"ze[24]"},
  wx = {"wo[1345]", "zuan[134]"},
  wy = {"zeng[14]", "weng[134]"},
  wz = {"wang[12345]", "zang[134]"},
  xb = {"xiong[1245]"},
  xc = {"xiang[12345]"},
  xd = {"xu[12345]"},
  xf = {"xiu[134]"},
  xg = {"xun[1245]"},
  xh = {"xia[1245]"},
  xj = {"xi[12345]"},
  xl = {"xue[1234]"},
  xm = {"xie[12345]"},
  xq = {"xian[12345]"},
  xs = {"xin[12345]"},
  xx = {"xuan[1234]"},
  xy = {"xing[12345]"},
  xz = {"xiao[1234]"},
  yb = {"yao[12345]"},
  yd = {"yu[12345]"},
  yf = {"you[12345]"},
  yg = {"yun[1234]"},
  yh = {"ya[12345]"},
  yj = {"yi[12345]"},
  yl = {"yue[1345]"},
  yn = {"yan[12345]"},
  ys = {"yin[12345]"},
  yt = {"yong[12345]"},
  yw = {"ye[12345]"},
  yx = {"yuan[1234]", "yo[15]"},
  yy = {"ying[12345]"},
  yz = {"yang[12345]"},
  zb = {"zhao[1234]"},
  zc = {"zhui[14]"},
  zd = {"zhu[12345]"},
  zf = {"zhou[12345]"},
  zg = {"zhun[13]", "zhei[4]"},
  zh = {"zha[12345]", "zhua[13]"},
  zj = {"zhi[12345]"},
  zl = {"zhai[1234]"},
  zm = {"zhuo[12]"},
  zn = {"zhan[1345]"},
  zq = {"zhuang[1345]"},
  zs = {"zhen[134]"},
  zt = {"zhong[1345]"},
  zw = {"zhe[12345]"},
  zx = {"zhuan[1345]", "zhuai[134]"},
  zy = {"zheng[1345]"},
  zz = {"zhang[1345]"},
}

-- 解析 preedit_raw 为 preedit_map
local preedit_map = {}
for key, entries in pairs(preedit_raw) do
  local parts = {}
  for _, raw in ipairs(entries) do
    local py, tones_str = raw:match("^(.-)%[(.-)%]$")
    if py and tones_str then
      local tones = {}
      for t in tones_str:gmatch("%d") do
        tones[tonumber(t)] = true
      end
      parts[#parts + 1] = {pinyin = py, tones = tones}
    else
      parts[#parts + 1] = {pinyin = raw, tones = nil}
    end
  end
  preedit_map[key] = parts
end

local tone_map = {
  ["7"] = 1,
  ["8"] = 2,
  ["9"] = 3,
  ["0"] = 4,
}

-- 声调字符映射
local tone_chars = {
  a = {"ā", "á", "ǎ", "à"},
  e = {"ē", "é", "ě", "è"},
  o = {"ō", "ó", "ǒ", "ò"},
  i = {"ī", "í", "ǐ", "ì"},
  u = {"ū", "ú", "ǔ", "ù"},
  ["ü"] = {"ǖ", "ǘ", "ǚ", "ǜ"},
}

-- 给单个拼音加声调
local function apply_tone(pinyin, tone_num)
  if not tone_num then return pinyin end

  -- 声调标注规则：
  -- 1. 有 a 或 e 标在 a/e 上
  -- 2. 有 ou 标在 o 上
  -- 3. 否则标在最后一个元音上

  -- 先处理 ü
  local py = pinyin:gsub("v", "ü")

  -- 找标调位置
  local pos = nil
  -- 规则1: a 或 e
  pos = py:find("[ae]")
  if not pos then
    -- 规则2: ou
    local ou_pos = py:find("ou")
    if ou_pos then
      pos = ou_pos  -- 标在 o 上
    end
  end
  if not pos then
    -- 规则3: 最后一个元音
    for j = #py, 1, -1 do
      local c = py:sub(j, j)
      if c == "a" or c == "e" or c == "o" or c == "i" or c == "u" or c == "ü" then
        pos = j
        break
      end
    end
  end

  if not pos then return py end

  local vowel = py:sub(pos, pos)
  -- ü 是两字节 UTF-8
  if vowel == "\195" then
    vowel = py:sub(pos, pos + 1)
    if vowel == "ü" and tone_chars["ü"] then
      return py:sub(1, pos - 1) .. tone_chars["ü"][tone_num] .. py:sub(pos + 2)
    end
  end

  if tone_chars[vowel] then
    return py:sub(1, pos - 1) .. tone_chars[vowel][tone_num] .. py:sub(pos + 1)
  end
  return py
end

function M.init(env)
end

function M.func(input, env)
  local ctx = env.engine.context
  local raw_input = ctx.input

  -- 将原始输入解析为音节对（每2个字母 + 可选声调7890）
  local preedit_parts = {}
  local i = 1
  local len = #raw_input

  while i <= len do
    local ch = raw_input:sub(i, i)

    if ch == " " or ch == "'" then
      i = i + 1
    elseif ch:match("%l") and i + 1 <= len and raw_input:sub(i + 1, i + 1):match("%l") then
      local pair = raw_input:sub(i, i + 1)
      i = i + 2
      local tone_num = nil
      if i <= len and raw_input:sub(i, i):match("[7890]") then
        tone_num = tone_map[raw_input:sub(i, i)]
        i = i + 1
      end
      local entries = preedit_map[pair]
      if entries then
        if tone_num then
          -- 过滤掉不支持该声调的拼音
          local toned = {}
          for _, entry in ipairs(entries) do
            if not entry.tones or entry.tones[tone_num] then
              toned[#toned + 1] = apply_tone(entry.pinyin, tone_num)
            end
          end
          if #toned == 0 then
            preedit_parts[#preedit_parts + 1] = pair
          elseif #toned == 1 then
            preedit_parts[#preedit_parts + 1] = toned[1]
          else
            preedit_parts[#preedit_parts + 1] = table.concat(toned, "/")
          end
        else
          local names = {}
          for _, entry in ipairs(entries) do
            names[#names + 1] = entry.pinyin
          end
          if #names == 1 then
            preedit_parts[#preedit_parts + 1] = names[1]
          else
            preedit_parts[#preedit_parts + 1] = table.concat(names, "/")
          end
        end
      else
        preedit_parts[#preedit_parts + 1] = pair
      end
    else
      preedit_parts[#preedit_parts + 1] = ch
      i = i + 1
    end
  end

  local preedit_text = table.concat(preedit_parts, " ")

  for cand in input:iter() do
    cand.preedit = preedit_text
    yield(cand)
  end
end

return M
