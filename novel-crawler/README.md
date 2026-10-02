# novel-crawler · 小说正文自适应提取插件

对**任意能拿到正文的网页 / 软件 / 文件**执行全自动自适应提取管线：

```
来源检测 → 正文捕获 → 加密检测 → 字体解密 / 文本修复 → 清洗输出
```

核心能力：

| 能力 | 说明 |
|---|---|
| 自适应捕获 | 网页优先走阅读 API（浏览器内同源 fetch 自动带 cookie），无 API 走 DOM 提取；软件/APP 走复制粘贴或导出文件 |
| 通用字体解密 | 破解小说站常用的**自定义字体混淆**（正文被映射到 Unicode 私有区 PUA，靠 woff2 裁剪字体渲染）。自动解析 cmap → 像素级字形匹配（思源黑体 SC + Noto Sans CJK SC 双参考交叉验证）→ 输出映射表。同一本书的字体全书通用，只解一次 |
| 文本修复 | base64 / 倒序 / XOR / GBK 乱码 / 全角还原自动探测，按可读性打分选最优 |
| 人工兜底 | 低置信字符输出上下文供人工定字（上下文是最终裁判） |
| 质检门禁 | 占位符必须为 0、章节数核对、抽查通顺，全部通过才交付 |

## 目录结构

```
novel-crawler/
├── SKILL.md                # dsh 技能入口（agent 执行工作流）
├── README.md
├── LICENSE                 # MIT
└── scripts/
    ├── font_decoder.py     # 通用字体混淆解密器（核心）
    ├── decode_text.py      # 映射应用 + 清洗 + 质检
    ├── ref_fonts.py        # 参考字体下载（SIL OFL 开源字体）
    ├── text_repair.py      # 常见编码修复探测
    ├── fanqie_crawler.py   # 番茄小说适配器模板（站点示例）
    └── requirements.txt
```

## 快速开始

```bash
# 1. 安装依赖（Python 3.9+）
pip install -r scripts/requirements.txt

# 2. 下载参考字体（仅首次，约 25MB）
python scripts/ref_fonts.py

# 3. 拿到混淆字体文件（站点 @font-face 的 woff2，或页面全局对象
#    window.confuseFontMap 中的 f=xxx.woff2），生成字符映射表：
python scripts/font_decoder.py 混淆字体.woff2 --out char_map.json

# 4. 解码正文（原文里含 U+E000~U+F8FF 私有区字符）：
python scripts/decode_text.py 原文.txt char_map.json --strip-html --out 成品.txt

# 5. 若有低置信字符（weak.json 非空），打印上下文人工定字后补入
#    char_map.json 重跑第 4 步
python scripts/decode_text.py 原文.txt char_map.json --contexts
```

## 作为 dsh 技能使用

把本目录整体放入 dsh 技能目录（`dsh-home/skills/novel-crawler/`）。之后在会话中对 agent 说：

> 去 XX 网站把《某书》前 N 章提取成 txt 放到 input 文件夹

agent 会按 `SKILL.md` 的五步管线自动执行：浏览器捕获正文 → 检测加密 →
调用本插件脚本解密 → 清洗 → 质检交付。遇到登录墙会提示用户手动登录后继续。

## 已实战验证

- **番茄小说**：破解 awesome-font 字体混淆（362 个 PUA 码位全部还原），
  成功提取《隐忍十年，开局抽到武道之圣》前 100 章（22 万字，0 乱码）。

## 工作原理：字体混淆为何可解

站点把常见字符映射到 PUA 码位后，用一个**裁剪过的开源字体**渲染这些码位——
字体 cmap 只含 `PUA → 字形`，但字形轮廓与思源黑体等开源字体**完全一致**。
因此把 PUA 字形逐字渲染成位图，与参考字体候选字做像素匹配即可还原。
参考字体双份交叉验证 + 同形字规则 + 上下文人工兜底，把误判率压到零。

## 适用范围与边界

- 适用：网页小说站、带自定义字体的阅读页、APP 复制/导出的混淆文本、常见编码乱码
- 不适用：字形被重新绘制（非裁剪自开源字体）的混淆；需付费解锁的章节（尊重站点条款）
- 参考字体未覆盖的生僻字会进入 low-confidence 流程，由上下文人工定字兜底

## 许可

MIT。参考字体（思源黑体/Noto Sans CJK）为 SIL OFL 1.1 许可，本仓库不随附字体文件。
