「裁缝铺」输入方案，把不同来源“剪裁、拼接、定制”成一套适合自己的方案。

## 通用功能
后续描述的各个方案都支持以下功能（虎码整句版除外）：
1. 开头使用 = 键触发计算器
1. 在 opencc/personal.txt 中添加个人隐私信息，例如手机号、地址等
   - opencc/personal.example.txt 是格式示例文件
1. emoji 显示在 preedit 后，如“〔表情：☁〕”，按`,`键上屏表情
1. 特定时间相关词（例如“今天”、“明天”、“上周”等）可以用 `,` 上屏时间串，如 `20240601`，用`-`可上屏`2024-06-01`，`/`可上屏`2024/06/01`


## 虎码

#### 字词版
在秃版的基础上，修改词库为 CC-CEDICT 词库。
- 虎码链接：[官方网站](https://www.tiger-code.com/)
- 虎码秃版：[虎码网盘](https://huma.ysepan.com/) （路径为「03 虎码输入法下载 $\rightarrow$ ①Windows $\rightarrow$ 小狼毫 $\rightarrow$ 虎码秃版 小狼毫（Win）2026.03.01.7z」）
- CC-CEDICT 词库链接：https://www.mdbg.net/chinese/dictionary?page=cedict

1. 出简让全
1. 开头使用 ` 键拼音反查，反查时支持将 7890 作为声调输入
1. 开头使用 ` 键显示上一次的输入历史
1. 输入过程中使用 ` 键分词，分词的产生的短语上屏后会自动造词
1. 开头使用 ~ 键以形查音（只支持单字）
1. 输入过程中分号键次选上屏，单引号键三选上屏
1. 在 tiger.extended.dict.yaml 中添加个人常用词，例如人名，常打的特殊短语等

#### 整句版
在官方整句的基础上，加上拼音反查。模型文件需自行下载并将 `sentence-ngram-mobile.bin` 放到 `models/` 文件夹下
- 官方整句：[github](https://github.com/lvyww/tiger-sentense-rime)
- 模型链接：[github](https://github.com/lvyww/tiger-sentense-rime/releases/tag/model)

1. 连续输入每个单字的编码，中间不按空格
1. 一简字至少输入两码：“我”输入 `tu`
1. 前 1500 字使用最优码：最短且不选重
1. “的”字由 `un` 特设为 `ue`
1. 非首选字词组句时，必须嵌入选重键或数字： `hh2ah` $\rightarrow$ 慢慢来，`b;ot` $\rightarrow$ 如果是
1. 整句候选请用 Tab 或方向键切换，不能用数字键直接选择
1. 以下单字编码有变，建议集中练习：敌强层吐档羊首络仅汽施启存题者耆簇办谦近集匕审种轼射烁
1. 补充语料：`tiger_sentence.supplement.txt`
1. 开头使用 ` 键拼音反查，反查时支持将 7890 作为声调输入

## 拼音
和地球拼音一样使用 CC-CEDICT 词库整理成简体字的带声调版本，可使用声调来降低重码率，使用了万象方案中的词频。
- 地球拼音链接：https://github.com/rime/rime-terra-pinyin
- CC-CEDICT 词库链接：https://www.mdbg.net/chinese/dictionary?page=cedict
- 万象方案链接：https://github.com/amzxyz/rime_wanxiang

1. 兼容万象词库的拼音格式，开启方式为将词库的 dicts 文件夹放到方案目录下，然后在 pinyin.schema.yaml 中设置 `translator/dictionary: wanxiang`
1. 声调使用 7890 输入，声调可连续输入，以最后输入的声调为准。
1. 使用 ' 键分词

#### 小鹤双拼
在拼音方案的基础上使用小鹤双拼的拼写运算
- 小鹤双拼链接：https://flypy.cc/

#### t9（手机）
在拼音方案的基础上使用 t9 的拼写运算

1. 由于声调体验不好，故不支持声调

#### 西戈码（手机）
在拼音方案的基础上使用西戈码的拼写运算
- 西戈码链接：https://www.bilibili.com/video/BV1aipxzPEj5/?t=705.3

#### 乱序17键（手机）
在拼音方案的基础上使用乱序17键的拼写运算

## 英文
1. 使用 easy_en 的英文词库
2. 可切换为万象英文词库，开启方式为将万象词库的 dicts 文件夹放到方案目录下，然后在 easy_en.schema.yaml 中设置 `translator/dictionary: wanxiang_english`
