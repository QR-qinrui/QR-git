---
name: novel-crawler
description: 小说正文自适应提取插件。对任意能拿到正文的网页/软件/文件执行「来源检测→正文捕获→加密检测→字体解密/文本修复→清洗输出」全自动管线，内置自定义字体混淆（PUA映射）通用解密器，输出标准化 txt。当用户要求爬取/提取小说正文、批量抓章、处理乱码或加密小说文本时使用。
---

# novel-crawler 小说正文自适应提取

## 铁律

1. 只提取用户拥有访问权的内容；尊重站点条款与限流（并发≤5，失败重试≤3，间隔≥300ms）。
2. 先试最简路径（明文→直接清洗），再逐级升级（简单编码修复→字体解密→人工上下文修复）。不写站点专用死代码，站点适配器只作模板。
3. 任何一步证据不足就停下问用户，不臆造正文。
4. 输出前必须通过质检门禁（占位符=0、章节数≥预期、抽查≥3处通顺）。

## 管线（自适应五步）

### 1. 来源检测
| 来源 | 判定 | 捕获方式 |
|---|---|---|
| 网页 URL | 浏览器打开阅读页/目录页 | 见步骤2 |
| 软件/APP | 无法直接自动化 | 让用户复制粘贴/导出文本文件，或从本地文件读取 |
| 本地文件 | .txt/.html/.json/.epub 路径存在 | 直接读取 |

浏览器检查清单：
- 正文 DOM：`document.querySelector` 找正文容器（内文长度显著大于页面上其他块）
- 网络 API：performance 资源列表 / DevTools 中找 `/reader`、`/chapter`、`/content`、`/book` 类请求；有 API 优先用 API（页面内 `fetch` 同源直调，自动带 cookie）
- 目录：目录接口返回章节 id 列表；否则解析目录页链接（`/reader/`、`/chapter/` 等）
- 若页面需登录：提示用户在已打开的 ego 浏览器窗口手动登录后继续

### 2. 正文捕获
- API 模式：页面内 `fetch(api_url)` 并发抓取章节正文+标题，重试3次，按目录顺序写入内存
- DOM 模式：遍历章节链接打开正文页，提取正文容器 `innerText`
- 分批传递：每批 ≤10 章从页面传回 node 侧落盘（`fs.appendFileSync`），避免大 JSON 撑爆工具输出
- 记录失败章节 id，全部完成后单独补抓

### 3. 加密检测（按序试探）
a. **明文**：正文汉字占比>70%且无连续生僻乱码 → 跳过解密
b. **PUA 字体混淆**：正文含大量 `U+E000–U+F8FF` 私有区字符，或页面存在 `@font-face` 自定义字体（尤其 `awesome-font`/`confuse`/`anti` 字样的 woff2）、`window.confuseFontMap` 类全局对象 → 走步骤4字体解密
c. **其他乱码**：base64/倒序/异或/GBK乱码等 → 用 `scripts/text_repair.py probe` 自动探测，命中即修复
d. 都未命中且文本不可读 → 问用户

### 4. 字体解密（scripts/font_decoder.py）
```bash
# 0) 下载参考字体（仅首次）
python scripts/ref_fonts.py
# 1) 获取混淆字体文件（页面 @font-face src 或 confuseFontMap 中的 f=xxx.woff2）
# 2) 双参考字体轮廓匹配，输出映射表与置信度
python scripts/font_decoder.py <混淆字体.woff2> --out char_map.json --scores scores.json
```
- 原理：混淆字体 cmap 仅含 PUA→字形；字形取自思源黑体等开源字体，故与参考字体做像素级匹配即可还原真实字符
- 双字体交叉验证（Adobe 思源黑体 SC + Google Noto Sans CJK SC），同形字优先取 ASCII/统一表意文字
- `weak.json` 里是低置信字符 → 进入上下文修复
- **字体映射全书通用**：同一本书各章字体相同（f 值相同），只解一次，可缓存复用

### 5. 清洗输出（scripts/decode_text.py）
```bash
python scripts/decode_text.py <原始.txt> <char_map.json> --strip-html --out <输出.txt>
```
- 去标签、统一换行、保留章节标题、未解字符输出 `<hex>` 占位并统计
- 弱置信字符：打印其上下文（前后±15字）→ agent 人工读上下文定字 → 更新 char_map.json 重跑
- 输出文件名：`《书名》.txt`，头部含 书名/作者/来源/章数

### 质检门禁（全部通过才算完成）
1. 占位符数量 = 0
2. 章节数与目录一致（或达到用户要求）
3. 抽查开头/中间/结尾 ≥3 段，语义通顺
4. 常见词探针（书中人名/地名词）计数 >0

## 已知站点模板
- 番茄小说：见 `scripts/fanqie_crawler.py`（API 端点 + 字体混淆流程完整示例）
- 其他站点：按本流程套用，站点专属细节写成 adapter 注释，不硬编码进核心脚本

## 文件结构
```
SKILL.md              本文件（agent 工作流）
README.md             使用文档
LICENSE               MIT
scripts/
  font_decoder.py     通用字体混淆解密器（核心）
  decode_text.py      映射应用 + 清洗 + 质检
  ref_fonts.py        参考字体下载
  text_repair.py      常见编码修复探测
  fanqie_crawler.py   番茄适配器模板
  requirements.txt     fontTools brotli Pillow
```
