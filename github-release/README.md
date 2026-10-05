# AI GitHub Scanner

> AI 驱动的 GitHub 资源自动筛选体系 + 8 角色自分工 AI 协作团队 + 自判断自寻 skill 调度机制

[![Skill Version](https://img.shields.io/badge/skill-v1.0.0-blue)]()
[![License](https://img.shields.io/badge/license-MIT-green)]()
[![Python](https://img.shields.io/badge/python-3.12+-blue)]()
[![WorkBuddy](https://img.shields.io/badge/WorkBuddy-skill-orange)]()

## 这是什么

一套可随时进化的 **AI 驱动 GitHub 资源自动筛选 skill**，配套 8 角色自分工 AI 协作团队，并内置自判断自寻 skill 调度机制。

- **筛选体系**：4 大领域并行扫描 → 五维加权评分 → 安全门检查 → 自动安装到 `~/.workbuddy/skills/`
- **协作团队**：8 角色（主导者 / 整体审查者 / 前端 / 后端 / 代码审查 / 信息寻找者 / 同步分发者 / 总结优化者），含完整任务状态机与消息协议
- **自判断调度**：6 个能力缺口检测点自动命中已安装 skill 并主动调用，无需用户指定
- **随时进化**：5 个进化点 + append-only 进化日志 + 强制 5 项进化检查

## 评分模型

5 维加权（总和=1.0）：

| 维度 | 权重 |
|------|------|
| 代码质量 code_quality | 25% |
| 活跃度 activity | 25% |
| 社区评价 community | 20% |
| 实用性 practicality | 20% |
| 安全信号 safety | 10% |

决策阈值：≥85 auto_install / ≥70 recommend / ≥50 record / else drop

## 快速开始

### 作为 WorkBuddy skill 安装

将本仓库克隆到 `~/.workbuddy/skills/`：

```bash
git clone https://github.com/<你的用户名>/<你的仓库名>.git ~/.workbuddy/skills/ai-github-scanner
```

克隆后 WorkBuddy 自动识别该 skill，下次匹配到相关意图时自动调用。

### 在新工作区初始化 scanner 项目

```bash
python scripts/init_scanner.py /path/to/new-scanner
```

会创建项目骨架并复制 `assets/config_template.yaml` 为 `config.yaml`。

### 独立评分

```bash
python scripts/run_eval.py --repo langchain-ai/langchain --stars 92000 --forks 14800 --license MIT --pushed-at "2026-09-30T00:00:00Z"
```

输出 JSON 评分结果。

## skill结构

```
ai-github-scanner/
├── SKILL.md                              # 主入口：工作流 + 5进化点 + 自判断调度
├── assets/
│   └── config_template.yaml              # 所有可调参数集中暴露
├── references/
│   ├── auto_dispatch_protocol.md         # 自判断自寻skill调用协议
│   ├── evolution_log.md                  # append-only进化日志
│   ├── scoring_formula.md                # 评分公式详解
│   └── team_protocol.md                  # 8角色协议
└── scripts/
    ├── init_scanner.py                   # 初始化新scanner项目
    ├── run_eval.py                       # 独立评分
    └── spawn_team.py                     # 生成8角色spawn prompt
```

## 自判断自寻 skill 调度机制

本 skill 在执行过程中能自主识别能力缺口，并**主动调用其他已安装 skill 补齐缺口**：

| 阶段 | 缺口信号 | 自动调用的skill |
|------|----------|-------------------|
| 评估 | 评分分布需图表化 | smart-charts |
| 报告 | 中文摘要需降AI味 | humanizer-zh-pro |
| 审查 | 评估结果需PPT汇报 | ppt-generator |
| 安装 | 涉及Office文件 | office-suite-assistant |
| 报告 | 涉及金融项目 | neodata-financial-search / westock-data |
| 复盘 | 修复bug后积累经验 | self-improving-agent |
| 全程 | 命中已安装skill但未被调用 | auto-skill-dispatcher 兜底 |

完整协议见 `references/auto_dispatch_protocol.md`。

## 5 个进化点

| 进化点 | 触发 | 操作 |
|--------|------|------|
| 1 评分权重调优 | 打分偏差 | 改 weights（总和=1.0） |
| 2 安全规则扩展 | 发现新攻击模式 | 加 block_patterns |
| 3 扫描领域调整 | 新技术栈出现 | 加 scan_domains |
| 4 角色协议演进 | 缺角色/状态 | 协议加 RoleSpec |
| 5 经验沉淀 | 修复bug后 | evolution_log append |

## 在 WorkBuddy 中调用

```
"帮我构建一个GitHub项目自动评估系统"
"搭建一个多角色AI协作团队"
"扫描GitHub上的AI Agent项目"
```

匹配意图后自动调用本 skill。

## 完整系统构建

本 skill 描述的完整可运行系统已在本工作区构建：
- 项目根：`ai-github-scanner/`（含完整scanner代码）
- 演示报告：`data/reports/report_*.html`
- 团队轨迹：`data/reports/TEAM_TRACE.md`

详见各 `references/` 文档。

## License

MIT - 见 [LICENSE](LICENSE)

## 致谢

灵感来自 WorkBuddy skill 生态与 modelcontextprotocol/servers、langchain-ai/langchain、microsoft/autogen 等优质开源项目。