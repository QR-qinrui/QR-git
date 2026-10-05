# AI GitHub Scanner

> AI 驱动的 GitHub 资源自动筛选体系 + 8 角色自分工 AI 协作团队 + 自判断自寻 skill 调度机制

[![Skill Version](https://img.shields.io/badge/skill-v1.0.0-blue)]()
[![License](https://img.shields.io/badge/license-MIT-green)]()
[![Python](https://img.shields.io/badge/python-3.12+-blue)]()
[![WorkBuddy](https://img.shields.io/badge/WorkBuddy-skill-orange)]()

## 这是什么

一套可随时进化的 **AI 驱动 GitHub 资源自动筛选 skill**，配套 8 角色自分工 AI 协作团队，并内置自判断自寻 skill 调度机制。

- **筛选体系**：4 大领域并行扫描 → 五维加权评分 → 安全门检查 → 自动安装到 ~/.workbuddy/skills/
- **协作团队**：8 角色（主导者 / 整体审查者 / 前端 / 后端 / 代码审查 / 信息寻找者 / 同步分发者 / 总结优化者）
- **自判断调度**：6 个能力缺口检测点自动命中已安装 skill 并主动调用
- **随时进化**：5 个进化点 + append-only 进化日志

## 评分模型

5 维加权（总和=1.0）：code_quality 25% + activity 25% + community 20% + practicality 20% + safety 10%

决策阈值：≥85 auto_install / ≥70 recommend / ≥50 record / else drop

## quick start

```bash
# 安装为 WorkBuddy skill
cp -r ai-github-scanner ~/.workbuddy/skills/

# 初始化新scanner项目
python ai-github-scanner/scripts/init_scanner.py /path/to/new-scanner

# 独立评分
python ai-github-scanner/scripts/run_eval.py --repo owner/repo --stars 1000 --license MIT
```

## skill 结构

```
ai-github-scanner/
├── SKILL.md                              # 主入口：工作流 + 5进化点 + 自判断调度
├── assets/
│   └── config_template.yaml              # 所有可调参数集中暴露
├── references/
│   ├── auto_dispatch_protocol.md         # 自判断自寻skill调用协议
│   ├── evolution_log.md                   # append-only进化日志
│   ├── scoring_formula.md                # 评分公式详解
│   └── team_protocol.md                  # 8角色协议
└── scripts/
    ├── init_scanner.py                   # 初始化新scanner项目
    ├── run_eval.py                       # 独立评分
    └── spawn_team.py                     # 生成8角色spawn prompt
```

## 自判断自寻 skill 调度

| 阶段 | 缺口信号 | 自动调用的skill |
|------|------------|-------------------|
| 评估 | 评分分布需图表化 | smart-charts |
| 报告 | 中文摘要需降AI味 | humanizer-zh-pro |
| 审查 | 评估结果需PPT汇报 | ppt-generator |
| 安装 | 涉及Office文件 | office-suite-assistant |
| 报告 | 涉及金融项目 | neodata-financial-search / westock-data |
| 复盘 | 修复bug后积累经验 | self-improving-agent |
| 全程 | 命中已安装skill但未被调用 | auto-skill-dispatcher 兜底 |

## 5 个进化点

1. 评分权重调优 - 改 weights（总和=1.0）
2. 安全规则扩展 - 加 block_patterns
3. 扫描领域调整 - 加 scan_domains
4. 角色协议演进 - 协议加 RoleSpec + TRANSITIONS
5. 经验沉淀 - evolution_log append

## License

MIT - 见 LICENSE
