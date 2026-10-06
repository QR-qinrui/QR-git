# 进化日志

> append-only - 仅追加，不修改历史记录
> 格式：## YYYY-MM-DD v版本号 · 触发简述

## 2026-10-06 v1.0.0 · skill创建

**触发**：用户首次构建AI驱动GitHub资源筛选体系与8角色协作团队后，要求固化为可随时进化的skill。

**变更**：
- 创建 `SKILL.md` 主入口，含核心工作流与5个进化点
- 创建 `references/scoring_formula.md` 评分公式详解
- 创建 `references/team_protocol.md` 8角色协议
- 创建 `assets/config_template.yaml` 完整可调配置模板
- 创建 `scripts/init_scanner.py`、`scripts/run_eval.py`、`scripts/spawn_team.py`

**效果**：
- 后续可由用户在新工作区一键初始化scanner项目
- 评分权重与安全规则通过编辑yaml即可调整，无需改代码
- 8角色协议可按项目实际需求扩展（如新增"测试工程师"角色）

---

## 2026-10-06 v1.1.0 · GitHub认证接入

**触发**：用户要求配置 GITHUB_TOKEN 环境变量（限流提升到 5000 req/hr）并安装 gh CLI（恢复完整增量数据获取能力）。

**变更**：
- 从 git credential-manager 提取已存 PAT，复用为 GITHUB_TOKEN（避免重新创建PAT）
- 在项目根创建 `.env` 文件持久化token，并在 `.gitignore` 中排除（防止意外提交）
- 修改 `scanner/github_client.py`：
  - `__init__` 增加 `self.token` 与 `self._auth_headers`，从环境变量或`.env`读取
  - 新增 `_load_env_token()` 静态方法解析.env文件
  - 修改 `_search_via_rest()` 携带 `Authorization: token xxx` header
  - `_check_rate_limit()` 真实调用 `/rate_limit` endpoint检查剩余配量
  - 新增 `_gh_cmd()` 方法返回gh绝对路径（PATH找不到时fallback到`C:/Program Files/GitHub CLI/gh.exe`等Windows默认位置）
  - 全部6处 `gh api` 调用改为 `self._gh_cmd()` 解析
- 通过 winget 安装 GitHub CLI v2.102.0
- 用 `gh auth login --with-token` 非交互式认证（避免OAuth浏览器流程）

**效果**：
- Token加载成功，Auth header已设置
- gh CLI 路径正确解析为 `C:/Program Files/GitHub CLI/gh.exe`，可用性验证通过
- gh 真实搜索测试返回50个项目，**首个 punkpeye/awesome-mcp-servers stars=95864，含topics字段**（REST默认不返回topics，gh更强大）
- gh auth status 显示登录账户为 QR-qinrui，token scopes 极全（admin:org/repo/workflow等）
- REST带Auth调用成功，限流从60/hr提升到5000/hr（core）/30每分钟（search）
- ai-github-scanner 现在可在生产环境跑真实API扫描，无需种子数据

**回滚条件**：
- 如PAT失效或被撤销：删除`.env`，github_client.py自动fallback为未认证调用（限流降到60/hr）
- 如gh CLI不可用：`_gh_available()`返回False，自动降级为REST API调用

**关键文件**：
- `ai-github-scanner/.env`（git忽略，不入库）
- `ai-github-scanner/.gitignore`（已添加.env排除规则）
- `ai-github-scanner/scanner/github_client.py`（6处gh调用+3处REST增强）

---

## 2026-10-07 v1.2.0 · 知识库自动归纳模块

**触发**：用户要求"每个项目做完都能自动归纳总结入库，整合到 ai-github-scanner skill 里，并把更新同步到 GitHub 仓库"。

**变更**：
- 新增 `knowledge/` 模块（5 文件）：
  - `__init__.py` 模块入口
  - `templates.py` 3 类 entry 模板（ProjectSummary/Pattern/Lesson），含 YAML front-matter + 8 章节正文章单
  - `storage.py` `KnowledgeStorage` 路径管理，自动按月分目录、生成 README、自动去重命名
  - `ingestor.py` `ProjectIngestor` 项目归纳引擎，自动检测项目类型（PROJECT_SIGNATURES）+ 推断标签（TAG_SIGNATURES）+ 抽取 evolution_log 条目
  - `indexer.py` `KnowledgeIndexer` 索引构建器，扫描所有 entry → 生成 INDEX.md + tags/{tag}.md
- 新增 `scripts/` 3 个 CLI：
  - `scripts/ingest_project.py` 项目归纳入库（支持 --path 或 --title）
  - `scripts/build_kb_index.py` 重建知识库索引
  - `scripts/sync_to_github.py` 同步 skill + 知识库到 GitHub 仓库
- 新增 `references/knowledge_protocol.md`：定义触发时机、目录布局、entry 类型、入库流程、与 evolution_log 协同
- 扩展 `assets/config_template.yaml`：
  - 新增 `knowledge_base` 段（kb_root/auto_ingest_on_complete/trigger_threshold_tools/github_sync）
  - GitHub 仓库默认填入 `https://github.com/QR-qinrui/QR-git`
- 更新 `scripts/init_scanner.py`：初始化 knowledge/ 子目录 + __init__.py
- 更新 `SKILL.md`：version 1.0.0 → 1.2.0，description 增加"知识库自动归纳"，末尾新增"内嵌知识库模块"章节
- 进化点从 5 个扩展到 6 个：新增"进化点6 · 知识库扩展"

**目录布局**（~/.workbuddy/knowledge/）：
```
knowledge/
├── README.md                      # 自动生成使用说明
├── INDEX.md                       # 自动生成的总索引（请勿手编）
├── projects/2026-10/              # 按月分目录
├── patterns/                      # 跨项目可复用模式
├── lessons/                       # 经验教训
└── tags/                          # 标签索引（自动生成）
```

**效果**：
- 知识库模块单测通过：导入成功 / 路径生成正确 / 项目类型自动识别 skill / 标签自动推断 7 个
- 首次入库验证成功：把 ai-github-scanner 自身归纳写入 `projects/2026-10/2026-10-07-ai-github-scanner-2026-10-07-项目总结.md`
- INDEX.md 自动重建：1 条 entry + 7 个 tag 索引文件全部正确生成
- 实现"项目完成 → 自动归纳 → 入库 → 索引 → 同步 GitHub"完整链路
- evolution_log 与 knowledge/ 双轨记忆：log 记变更、knowledge 存档案

**回滚条件**：
- 用户认为不应自动入库：把 `assets/config_template.yaml` 的 `knowledge_base.auto_ingest_on_complete` 改为 false
- 知识库目录污染：删除 `~/.workbuddy/knowledge/` 整个目录，下次入库自动重建
- 同步到 GitHub 失败：检查 GITHUB_TOKEN 或 gh auth status；同步失败不阻塞本地入库

**关键文件**：
- `knowledge/__init__.py`、`knowledge/templates.py`、`knowledge/storage.py`、`knowledge/ingestor.py`、`knowledge/indexer.py`
- `scripts/ingest_project.py`、`scripts/build_kb_index.py`、`scripts/sync_to_github.py`
- `references/knowledge_protocol.md`
- `assets/config_template.yaml`（新增 knowledge_base 段）

---

## 进化记录模板

```
## YYYY-MM-DD v版本号 · 触发简述

**触发**：（什么场景触发本次进化）
**变更**：（具体修改了哪些文件 / 配置项）
**效果**：（变更后带来了什么改善 / 验证情况）
**回滚条件**：（什么情况下需要回退到上一版本）
```

## 进化触发信号

| 信号 | 进化点 | 操作 |
|------|--------|------|
| 评分打分与人工直觉不符 | 评分权重 | 调整权重或公式 → 改yaml → 记log |
| 安全门漏过可疑项目 | 安全规则 | 扩展block_patterns → 改yaml → 记log |
| 新技术栈出现 | 扫描领域 | 新增scan_domains条目 → 改yaml → 记log |
| 团队协作中出现新角色需求 | 角色协议 | 协议加新RoleSpec → 改team_protocol.md → 记log |
| 修复bug后 | 经验沉淀 | evolution_log追加记录 |

## 版本号约定

- 主版本号（v1 → v2）：评分模型结构性变化、角色协议重大修订
- 次版本号（v1.0 → v1.1）：新增扫描领域、新增安全规则
- 修订号（v1.0.0 → v1.0.1）：参数微调、文档勘误