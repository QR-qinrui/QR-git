# dsh-maintenance-toolkit

![Platform](https://img.shields.io/badge/platform-Windows-blue)
![PowerShell](https://img.shields.io/badge/PowerShell-5.1%2B-blue)
![License](https://img.shields.io/badge/license-MIT-green)
![Version](https://img.shields.io/badge/version-1.0.0-orange)
![Status](https://img.shields.io/badge/status-production--tested-brightgreen)

**DSH（DeepSeek Harness）一键启动器 · 运维维护三件套**

A production-tested maintenance toolkit for the DeepSeek Harness one-click launcher on Windows. It turns three rounds of real-world operations (2026-09-30) into reproducible, rollback-safe, auditable workflows: **F12 evidence-based self-check & repair**, **lossless plugin upgrade**, and **host runtime upgrade SOP**. All flows share one idempotent patch system and one single source of truth for the host version.

沉淀自 2026-09-30 三轮实战（宿主 0.1.7-rc.2 → 0.2.0-rc.2、dsh-web-all 全家桶 0.4.3→0.4.4、全 profile 插件升级、多轮 F12 修复）。三套流程共享同一套幂等补丁体系与「内置运行时优先」的宿主版本单一真源，可单独运行，也可串联（宿主升级会自动重放插件补丁并完成插件层对齐）。

---

## 目录

- [三大流程](#三大流程)
- [仓库布局](#仓库布局)
- [前置条件](#前置条件)
- [快速开始](#快速开始)
- [退出码与报告](#退出码与报告)
- [关键设计](#关键设计)
- [安全须知](#安全须知)
- [安装为 Agent 技能](#安装为-agent-技能)
- [错误签名扩展](#错误签名扩展)
- [发布](#发布)
- [贡献](#贡献)
- [License](#license)

## 三大流程

| # | 流程 | 入口 | 能力 |
| --- | --- | --- | --- |
| A | **F12 自查修复** | `f12-audit-repair.cmd` | 服务探活 → 补丁完整性核验 → 路由冒烟 → 无头 Chrome CDP 采集 → 签名分类报告（PASS/REVIEW） |
| B | **插件无损升级** | `update-plugins.ps1` | 8 阶段：双源检测 → 镜像同步门禁 → 三层兼容预检 → 备份 → 精确升级 → 幂等补丁重打 → 指标化验证 → 报告；支持每日计划任务 |
| C | **宿主升级 SOP** | `升级DSH运行时.ps1` | 暂存 → 双门分析 → 沙箱演练 → 备份 → 原子交换 → 组合树断言 → 启动验收；失败自动回滚 |

流程文档：`docs\F12自查修复流程说明.md` · `docs\插件无损升级流程.md` · `docs\DSH宿主升级SOP.md`。

## 仓库布局

```
dsh-maintenance-toolkit/
├── SKILL.md                  # Agent 技能入口（何时用、怎么用、安全边界）
├── README.md                 # 本文件
├── CHANGELOG.md              # 版本变更记录
├── CONTRIBUTING.md           # 贡献指南
├── LICENSE                   # MIT
├── deploy.ps1                # 部署/校验到一键启动器目录（默认只校验，-Apply 才复制）
├── .github/                  # Issue 模板、PR 模板、发版 Actions
├── docs/                     # 三份流程文档
├── launcher-root/            # 部署到「一键启动器根目录」的文件（仅 tools 五件套）
│   └── tools/                     analyze-compat / probe-native / check-runtime-patches /
│                                  apply-runtime-patches / watch-and-upgrade
├── data/                     # 部署到「deepseek-Harness插件及其数据\」的全部维护脚本
│   ├── 升级DSH运行时.ps1          通用升级引擎（自动探测启动器根目录）
│   ├── 升级DSH到0.2.0-rc.2.ps1/.cmd  0.2.0-rc.2 冻结实例
│   ├── 升级配置.json / 开始自动升级.cmd / 使用说明.md
│   ├── f12-audit-repair.ps1/.cmd
│   ├── update-plugins.ps1 / auto-update.ps1 / upgrade-plugins.ps1/.cmd
│   ├── maintain.ps1 / 维护DeepSeek-Harness.cmd
│   ├── apply-adaptations.ps1 + patch-data.json   幂等补丁体系
│   └── patch-runtime-tree.mjs     本机 runtime 私有 UI 补丁
└── records/                  # 实战修复记录（可审计样本）
```

## 前置条件

- Windows + PowerShell 5.1（脚本刻意兼容 5.1，含 BOM/CRLF/别名坑免疫）
- DeepSeek Harness 一键启动器本体（含 `runtime\` 与 `deepseek-Harness插件及其数据\`）
- 流程 A 可选：Chrome 或 Edge（无头采集）；pnpm（流程 B/C 使用）
- 网络：npmjs + npmmirror（流程 B 双源门禁）

## 快速开始

```powershell
# 1) 校验/部署到启动器目录。deploy.ps1 自动向上查找启动器根目录
#    （含 runtime\ 与 deepseek-Harness插件及其数据\ 的目录），也可 -Root 显式指定；
#    默认只校验，-Apply 才复制
powershell -ExecutionPolicy Bypass -File .\deploy.ps1
powershell -ExecutionPolicy Bypass -File .\deploy.ps1 -Apply
powershell -ExecutionPolicy Bypass -File .\deploy.ps1 -Root "D:\your\launcher\root" -Apply

# 2) 三件套入口（均在部署布局中运行，勿从仓库目录直接跑脚本）
f12-audit-repair.cmd                                    # A：体检修复
powershell -ExecutionPolicy Bypass -File update-plugins.ps1 -SelfTest   # B：自检
powershell -ExecutionPolicy Bypass -File update-plugins.ps1 -Apply      # B：升级
.\升级DSH运行时.ps1 -Analyze                            # C：分析（升级前必读 SOP）
```

详细命令与验收门禁见 `SKILL.md` 与 `docs\` 三份文档。

## 退出码与报告

| 脚本 | 退出码 | 报告产物 |
| --- | --- | --- |
| f12-audit-repair.ps1 | 0=PASS / 1=REVIEW | `f12-report-<时间戳>.md`（脚本同目录） |
| update-plugins.ps1 -SelfTest | 0=全绿 / 1=有失败项（可挂 CI） | `修复记录-<时间戳>-自动升级.md` |
| 升级DSH运行时.ps1 | 0=成功 / 2=缺暂存区拦截 / 其他=失败 | `logs\升级DSH-<版本>.state.json` + 验证证据目录 |

## 关键设计

- **实证优先**：结论来自真实浏览器 CDP 采集 + 真实 API 探测，不用猜。
- **双源确认**：npmjs 是地面真值，npmmirror 是实际下载源，缺一不动手。
- **幂等自愈**：补丁检查、`apply-adaptations.ps1`、升级全流程均可重复运行。
- **无损可回滚**：先备份 → 精确升级 → 断言失败自动回滚；宿主升级用暂存区原子互换，旧版改名保留。
- **签名分类**：错误映射到已知签名（pet-404 / ego-409 / react130 / changes-summary-404 / ollama-500 / whale-audio），设计行为与真故障分开。
- **单一真源**：宿主版本只认内置运行时 `runtime\...\dsh\package.json`，四个工具统一解析顺序。

## 安全须知

- 破坏性动作（`-Apply`、正式升级、回滚）先跑只读模式（检测 / `-Analyze` / `-DryRun` / `-SelfTest`）。
- 宿主升级前必须停止宿主（3080 空闲）；升级会热重载 ego 并重启浏览器窗口。
- `开始自动升级.cmd` 看守器必须由用户双击启动（宿体外），不能由会话代跑。
- 改脚本后遵守 PS 5.1 三坑：`.ps1` 用 UTF-8 with BOM + CRLF；`.bat` 用 CRLF + ASCII 注释；函数名避开内置别名。
- 已脱敏：`docs\`、`data\使用说明.md` 与补丁脚本注释中的本机绝对路径已替换为 `<launcher-root>` / `<user-home>` 占位符；`maintain.ps1` 的源码 checkout 路径（`C:\Users\QR\deepseek-harness`）与 node 候选目录属于功能锚点，发布前请自行决定是否改写。

## 安装为 Agent 技能

- dsh / OpenViking：`add_skill(path="<本仓库目录>")`，或打包成 zip 上传。
- 手动：把仓库目录复制到 harness 的 skills 目录（`SKILL.md` 为入口）。
- 仅装 `SKILL.md` 文本也可工作，但辅助脚本需按上述布局部署。

## 错误签名扩展

新错误 = 一行签名 + 一个修复动作（见 `docs\F12自查修复流程说明.md` 第五节）：

1. `f12-audit-repair.ps1` 的 `Classify-Entry` 加一行；
2. 对应 Phase 加探测/修复动作；
3. `-SelfTest` 或一次全量跑通后更新 `CHANGELOG.md`。

## 发布

推送 `v*` tag 会自动构建 zip 并创建 GitHub Release（见 `.github\workflows\release.yml`）：

```bash
git tag v1.0.0
git push origin main --tags
```

手动发版：把 `dsh-maintenance-toolkit.zip` 作为附件上传到 Release。

## 贡献

见 `CONTRIBUTING.md`。提交前请确认：PS 5.1 语法通过、编码规范（BOM/CRLF）满足、只读模式自测过、变更写进 CHANGELOG。

## License

[MIT](LICENSE) © 2026 dsh-maintenance-toolkit contributors
