---
name: ai-github-scanner
description: AI驱动的GitHub资源自动筛选体系 + 7角色自分工AI协作团队。自动扫描GitHub项目，按代码质量/活跃度/社区评价/实用性/安全信号五维评分，≥85分自动通过安全门后安装到~/.workbuddy/skills/。配套主导者/整体审查者/前端/后端/代码审查/信息寻找者/同步分发者/总结优化者8角色协作协议。当用户需要构建GitHub项目自动评估系统、搭建AI协作团队框架、批量筛选开源skill/plugin资源、定期扫描优质仓库并入体系时使用本skill。本skill设计为可随时进化：评分权重、安全规则、扫描领域、角色协议均通过 references/evolution_log.md 记录迭代历史，通过 assets/config_template.yaml 暴露所有可调参数。
version: 1.0.0
agent_created: true
follow_up_questions: 最后询问用户是否需要立即部署或调整评分阈值
---

# AI GitHub Scanner - AI驱动的GitHub资源筛选与协作团队skill

## 用途

构建一套「自动扫描GitHub优质项目 → 五维评分 → 安全门检查 → 自动安装到现有skills体系」的完整流水线，配套8角色自分工AI协作团队完成全生命周期。skill本身设计为**可随时进化**：所有可调参数集中在 `assets/config_template.yaml`，迭代历史记录在 `references/evolution_log.md`。

## 何时使用

触发场景：
- 用户要求构建GitHub项目/仓库/skill/plugin自动评估或筛选系统
- 用户要求搭建多角色AI协作团队（含主导者/审查者/开发/信息寻找者等角色）
- 用户要求定期/定时扫描GitHub并入现有skill体系
- 用户提及"AI驱动筛选"、"代码质量评估"、"自分工团队"等关键词
- 用户提供一个项目清单要求按质量自动排序或安装

## 核心工作流

### 阶段1 · 项目骨架搭建

1. 在用户工作区创建 `ai-github-scanner/` 根目录，含子目录 `scanner/ team/ data/{scanned,evaluated,reports,installed} docs/`
2. 复制 `assets/config_template.yaml` 为 `config.yaml`，按用户需求调整：扫描领域、评分权重、阈值、安全规则
3. 确认Python环境：用 `~/.workbuddy/binaries/python/versions/3.13.12/python.exe -m venv ./venv`，`./venv/Scripts/pip install PyYAML requests jinja2 python-dateutil`
4. GitHub认证：`gh auth login` 或 `GITHUB_TOKEN` 环境变量（无认证时降级使用种子数据集演示）

### 阶段2 · 5模块核心代码

按以下顺序生成（每个文件独立可运行）：

| 模块 | 文件 | 职责 |
|------|------|------|
| 扫描客户端 | `scanner/github_client.py` | gh CLI优先 + REST降级，6小时缓存，限流保护，`RepoCandidate` 数据类 |
| 评估引擎 | `scanner/evaluator.py` | 五维加权评分，决策输出 `auto_install/recommend/record/drop` |
| 安装与安全门 | `scanner/installer.py` | `SafetyGate` 静态扫描 + `Installer` git clone部署 |
| 报告生成 | `scanner/report.py` | HTML+JSON双格式，Top-N展示 |
| 种子数据 | `scanner/seed_data.py` | 无API环境下的真实优质项目快照 |

评分公式详见 `references/scoring_formula.md`，关键决策点：
- 5维权重总和必须=1.0
- `auto_install` 默认85分，可按用户风险偏好调整（70-90之间）
- `safety_gate.max_suspicious_score` 默认30，越严格越低

### 阶段3 · 7角色团队框架

生成两个文件：

| 文件 | 内容 |
|------|------|
| `team/roles.py` | 8个 `RoleSpec`：orchestrator/reviewer/frontend_dev/backend_dev/code_reviewer/researcher/synchronizer/optimizer |
| `team/protocol.py` | `TaskState` 枚举 + `TRANSITIONS` 状态机 + `MessageType` 协议 + `SCREENING_PLAYBOOK` 协作剧本 |

8角色按三层分组：
- **协调团队**：orchestrator（统筹）、reviewer（把关）、synchronizer（对齐）
- **执行团队**：frontend_dev、backend_dev、code_reviewer
- **支撑团队**：researcher（调研）、optimizer（复盘）

完整角色职责与消息协议见 `references/team_protocol.md`。

### 阶段4 · 团队演示运行

精简承担方案（3方8角色，适合快速演示）：
- `main` 承担 orchestrator + synchronizer + backend_dev代表
- spawn `researcher` teammate（后台调研生态补充）
- spawn `auditor` teammate（审查+复盘+skill沉淀）

扩展为完整8-agent并行部署见 `references/team_protocol.md` 第6节。

### 阶段5 · 自动化与文档

1. 用 `automation_update` 设置每日扫描：`FREQ=DAILY;BYHOUR=9;BYMINUTE=0`
2. 生成 `docs/ARCHITECTURE.md` 与 `docs/TEAM_DESIGN.md`
3. 通过 `present_files` 交付报告与文档

## 关键脚本入口

scripts目录提供3个可执行脚本：

- `scripts/init_scanner.py` - 在指定目录初始化一个新scanner项目（复制模板+配置）
- `scripts/run_eval.py` - 对一组RepoCandidate执行评分（独立可调用）
- `scripts/spawn_team.py` - 输出8角色teammate的spawn prompt到stdout

## 进化机制（核心特性）

本skill支持随时进化，5个进化点：

### 进化点1 · 评分权重调优
触发：用户反馈打分偏差、新增维度需求
操作：编辑 `assets/config_template.yaml` 的 `scoring_weights`，更新 `references/evolution_log.md`
约束：5维权重总和必须=1.0

### 进化点2 · 安全规则扩展
触发：发现新的供应链攻击模式、可疑脚本模式
操作：编辑 `assets/config_template.yaml` 的 `safety_gate.block_patterns/warn_patterns`
约束：每个pattern为正则，至少1条block_pattern

### 进化点3 · 扫描领域调整
触发：新兴技术栈出现、用户聚焦特定领域
操作：编辑 `assets/config_template.yaml` 的 `scan_domains`，新增/禁用条目
约束：每个领域必须有 `name/description/keywords/min_stars`

### 进化点4 · 角色协议演进
触发：协作中发现新角色需求、状态转移路径缺失
操作：更新 `references/team_protocol.md` + skill内 `team/protocol.py` 模板
约束：新增状态必须加入 `TRANSITIONS` 的key

### 进化点5 · 经验沉淀
触发：每次完成扫描任务后，或修复bug后
操作：在 `references/evolution_log.md` 追加一条记录（日期/触发/变更/效果）
约束：append-only，不修改历史记录

## 每次使用skill后的进化检查

完成一次任务后，必须执行以下进化检查：

1. **是否暴露了评分盲点？** → 调整公式或权重，记录到evolution_log
2. **是否发现新可疑模式？** → 扩展block_patterns，记录到evolution_log
3. **是否有新领域值得扫描？** → 扩展scan_domains，记录到evolution_log
4. **团队协作是否有阻塞？** → 更新协议，记录到evolution_log
5. **是否有可复用的修复模式？** → 提炼到evolution_log并考虑提到SKILL.md

## 配置参考

完整可调参数见 `assets/config_template.yaml`，含：
- 4个领域模板（mcp_skill_plugin/ai_agent_llm/dev_tools/trending_broad）
- 5维评分权重（默认25/25/20/20/10）
- 3档决策阈值（85/70/50）
- 7条block_patterns + 5条warn_patterns

## 决策树（何时使用本skill）

```
用户需求
├─ 构建GitHub项目筛选系统 → 使用本skill（assets/config_template.yaml + scripts）
├─ 搭建AI协作团队 → 使用本skill（references/team_protocol.md）
├─ 批量评估开源项目 → 使用本skill（scripts/run_eval.py独立调用）
├─ 定时扫描并入skill体系 → 使用本skill + automation_update
└─ 单个项目的代码审查 → 不用本skill，使用 ponytail-review 或类似工具
```

## 自判断自寻skill调用机制（核心内置能力）

本skill在执行过程中能自主识别能力缺口，并**主动调用其他已安装skill补齐缺口**，
不需要用户显式指定。完整协议见 `references/auto_dispatch_protocol.md`。

### 6个能力缺口检测点

| 阶段 | 缺口信号 | 自动调用的skill |
|------|----------|-------------------|
| 评估阶段 | 评分分布需要图表化 | smart-charts |
| 报告阶段 | 中文摘要需要降AI味 | humanizer-zh-pro |
| 审查阶段 | 评估结果需要PPT汇报 | ppt-generator |
| 安装阶段 | 涉及Office文件操作 | office-suite-assistant |
| 报告阶段 | 涉及金融/股票项目 | neodata-financial-search / westock-data |
| 复盘阶段 | 修复bug后积累经验 | self-improving-agent |
| 全程 | 命中已安装skill但未被调用 | auto-skill-dispatcher 兜底 |

### 调用决策算法

```
1. 用户是否显式指定了某skill？ → 尊重用户选择
2. 否则有可用已安装skill能补齐缺口？ → 主动调用，无需求询问
3. 否则能用通用代码补齐？ → 直接写代码
4. 否则用 AskUserQuestion 询问用户
```

### 关键约束

- 自判断**仅用于 skill调用决策**，不修改本skill自身的代码或评分逻辑
- skill调用失败：记录到 evolution_log，fallback为通用代码
- 推荐skill未安装：跳过并记录为"潜在skill依赖未满足"

### 与 auto-skill-dispatcher 的关系

- `auto-skill-dispatcher`（已安装）：识别**用户原始意图** → 调度全局skill
- 本机制：识别**任务执行过程中的能力需求** → 在scanner内部补齐
- 两者互补，不冲突

## 扩展能力（其他skill自动调用清单）

完整清单见 `references/auto_dispatch_protocol.md`，常见命中：

| 命中场景 | 自动调用 |
|----------|----------|
| 生成图表 | smart-charts |
| 降AI味中文 | humanizer-zh-pro |
| 生成PPT | ppt-generator |
| Office文件处理 | office-suite-assistant |
| 创建新skill | skill-creator |
| 装skill | marketplace-skill-installer |
| 修bug | systematic-debugging |
| 提交代码 | github |