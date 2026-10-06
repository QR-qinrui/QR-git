# 知识库自动归纳协议（knowledge_protocol.md）

> 让 ai-github-scanner 在每个项目完成后，能自动归纳总结、入库存档，
> 与 evolution_log 形成"过程日志 + 项目档案"双轨记忆体系。

## 一、设计目标

| 维度 | evolution_log.md | knowledge/（本协议） |
|------|------------------|-----------------------|
| 粒度 | 单次进化事件 | 一个完整项目 |
| 写入时机 | 每次代码/配置变更 | 项目完成（用户确认或自动检测） |
| 内容 | 触发/变更/效果/回滚 | 项目概要/方案/问题/经验/教训 |
| 检索 | append-only 时间序 | 按类型/标签/月份索引 |
| 同步 | skill 仓库内 | skill 仓库 + GitHub 远程 |

## 二、何时触发自动归纳

满足以下任一条件即触发：

1. **用户显式触发**："把这个项目总结入库"、"归纳本项目到知识库"
2. **项目完成信号**（自动检测）：
   - 用户在对话中明确表示"做完了/完成了/搞定了 ××"
   - 项目刚执行过 `present_files`（视为交付完成）
   - 项目刚执行过 `git commit + push`（视为发布完成）
3. **任务自然结束**：完成超过 8 个工具调用的复杂任务，且产生了具体交付物

**禁止触发**：纯闲聊、单次查询、读文件无写入、未产生交付物。

## 三、知识库目录布局

```
~/.workbuddy/knowledge/                # 知识库根目录（storage.DEFAULT_KB_ROOT）
├── README.md                           # 使用说明（首次创建时自动生成）
├── INDEX.md                            # 自动生成的总索引（请勿手编）
├── projects/
│   └── YYYY-MM/                        # 按月份组织
│       └── YYYY-MM-DD-{slug}.md       # 一项目一文件
├── patterns/                           # 跨项目可复用模式
│   └── YYYY-MM-DD-{slug}.md
├── lessons/                            # 经验教训
│   └── YYYY-MM-DD-{slug}.md
└── tags/                               # 标签索引（自动生成）
    └── {tag}.md
```

文件命名约定：
- `{date}-{slug}.md`，slug 由标题生成（最多 60 字符，含中英文）
- 重名自动追加序号：`-2.md`、`-3.md`

## 四、Entry 类型与模板

三种 entry 类型，模板定义在 `knowledge/templates.py`：

### 4.1 `project_summary`（项目完成总结，默认）

YAML front-matter 必须含：`title` / `project_id` / `entry_type` / `created_at` / `tags`

正文 8 个章节：项目概要、技术方案、关键代码、问题与解决、可复用模式、教训、后续行动、关联资源。

`project_id` 格式：`proj-YYYYMMDD-{8位md5}`，由 ingestor 自动生成。

### 4.2 `pattern`（可复用模式）

字段：`pattern_id` / `category` / `when_to_use` / `solution` / `code_sample`

通过 `ingest_pattern()` 函数入库，通常由用户或后续任务从多个 project_summary 中提炼。

### 4.3 `lesson`（经验教训）

字段：`lesson_id` / `severity`（critical/major/minor）/ `symptom` / `root_cause` / `fix` / `prevention`

通过 `ingest_lesson()` 函数入库。

## 五、入库流程（ingestor 工作流）

```
1. 接收 project_path + goal + notes
2. 自动检测项目类型（基于文件特征 PROJECT_SIGNATURES）
3. 自动推断 tags（基于 TAG_SIGNATURES）
4. 生成 project_id（日期 + md5）
5. 从 references/evolution_log.md 抽取本次相关条目（用于"问题与解决"）
6. 扫描项目根目录，生成"关键代码 / 文件"清单
7. 调用 ProjectSummaryTemplate.render_with_meta 渲染 markdown
8. 写入 ~/.workbuddy/knowledge/projects/YYYY-MM/YYYY-MM-DD-{slug}.md
9. 调用 KnowledgeIndexer.rebuild() 重建 INDEX.md 与 tags/
10. 返回 IngestResult（路径 / project_id / 检测到的类型与标签）
```

## 六、检索方式

- **按时间**：`~/.workbuddy/knowledge/projects/YYYY-MM/` 浏览
- **按类型**：INDEX.md 中分块展示 project_summary / pattern / lesson
- **按标签**：`~/.workbuddy/knowledge/tags/{tag}.md`
- **按内容**：用 grep/ripgrep 全文搜索
- **未来扩展**：可考虑接入向量检索（暂未实现）

## 七、与 evolution_log.md 的协同

每次 ingest 时：
- ingestor 自动从 evolution_log.md 抽取项目相关条目，填入"问题与解决"章节
- ingest 完成后，在 evolution_log.md 追加一条 "知识库入库" 记录（可选）

含义分工：
- evolution_log：**变化记录**（什么时候改了什么）
- knowledge/：**项目档案**（这次做了什么、做成什么样、学到什么）

## 八、与 GitHub 同步

由 `scripts/sync_to_github.py` 负责把整 skill + 知识库 push 到用户指定仓库：
- 仓库地址通过配置或命令行参数传入
- 默认推送到 `main` 分支
- 支持 `--knowledge-only` 仅同步知识库

## 九、与 self-improving-agent 的关系

- `self-improving-agent`（已安装）：捕获错误并改进
- 本协议：把项目档案沉淀为可检索知识
- 互补：self-improving-agent 改"行为"，本协议改"记忆"

## 十、扩展点

| 扩展点 | 触发 | 操作 |
|--------|------|------|
| 新增项目类型识别规则 | 检测到未知类型频繁出现 | 扩展 `PROJECT_SIGNATURES` |
| 新增标签识别规则 | tags 索引需更细 | 扩展 `TAG_SIGNATURES` |
| 新增 entry 类型 | 需要新形态记录 | 继承 `_BaseTemplate` + 加入 storage.resolve 分支 |
| 索引策略升级 | 条目数量过大 | indexer 引入按月分索引或向量检索 |