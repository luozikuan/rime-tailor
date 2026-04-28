「裁缝铺」输入方案，把不同来源“剪裁、拼接、定制”成一套适合自己的方案。

## 新世纪五笔
使用空山五笔的简码词库、字根拆分及字体文件。全码词库由 CC-CEDICT 词库整理而来。
- 空山五笔链接：https://gitee.com/hi-coder/rime-wubi

1. 出简不出全
2. 使用 z 键拼音反查
3. 使用 ~ 键以形查音
4. 使用 ' 键分词，在关闭字根显示的情况下分词后的短语上屏后会自动造词
5. 使用 = 键触发计算器
6. 在 opencc/personal.txt 中添加个人隐私信息，例如手机号、地址等
7. 在 wubi.extended.dict.yaml 中添加个人常用词，例如人名，常打的特殊短语等
8. 特定时间相关词可在候选字中新增时间串，例如“明天”候选字中新增“2024-06-01”，以便快速输入日期
9. 挂载了英文词库，直接输入英文单词即可，英文权重低于中文

## 拼音
和地球拼音一样使用 CC-CEDICT 词库整理成简体字的版本，此词库带声调，可使用声调来降低重码率。
- 地球拼音链接：https://github.com/rime/rime-terra-pinyin
- CC-CEDICT 词库链接：https://www.mdbg.net/chinese/dictionary?page=cedict
- 兼容万象词库的拼音格式，开启方式为将词库的 dicts 文件夹放到方案目录下，然后在 pinyin.schema.yaml 中设置 `translator/dictionary: wanxiang`

1. 声调使用 7890 输入，声调可连续输入，以最后输入的声调为准。
2. 使用 ' 键分词

#### 小鹤双拼
在拼音方案的基础上使用小鹤双拼的拼写运算
- 小鹤双拼链接：https://flypy.cc/

#### t9
在拼音方案的基础上使用 t9 的拼写运算

1. 使用 -/<\ 键输入声调（不过声调在9键上体验还不太好，需要在左侧选完拼音后再输入声调）

#### 西戈码
在拼音方案的基础上使用西戈码的拼写运算
- 西戈码链接：https://www.bilibili.com/video/BV1aipxzPEj5/?t=705.3

#### 乱序17键
在拼音方案的基础上使用乱序17键的拼写运算

## 英文
1. 使用 easy_en 的英文词库
2. 可切换为万象英文词库，开启方式为将万象词库的 dicts 文件夹放到方案目录下，然后在 easy_en.schema.yaml 中设置 `translator/dictionary: wanxiang_english`
