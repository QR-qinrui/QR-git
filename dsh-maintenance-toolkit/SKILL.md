---
name: dsh-maintenance-toolkit
description: DSH（DeepSeek Harness）一键启动器的运维三件套技能：F12 实证体检与自愈（f12-audit-repair）、插件无损升级（update-plugins / auto-update / 计划任务）、宿主运行时升级 SOP（升级DSH运行时 + tools 五件套，含沙箱演练、断言门禁与回滚）。Use when the user asks to check, repair, or upgrade the dsh launcher, its plugins, or the bundled runtime; when the web console shows errors or a version upgrade is pending.
---

# DSH Maintenance Toolkit（维护三件套）

沉淀自 2026-09-30 的实战（宿主 0.1.7-rc.2 → 0.2.0-rc.2、dsh-web-all 全家桶 0.4.3→0.4.4、全 profile 插件升级、多轮 F12 修复）。
三条流程共享同一套幂等补丁体系与「内置运行时优先」的宿主版本单一真源，互相衔接、可单独跑也可串联。

## 0. 布局契约（先于一切）

脚本全部以 `$PSScriptRoot` 自锚定；宿主升级引擎会**自动向上探测启动器根目录**（含 `runtime\` 与数据目录的目录），所以维护脚本统一部署在数据目录也能正确工作。**不要直接从仓库目录运行脚本**（仓库是发布源，不是部署位）。

```
<一键启动器根目录>\                      （含 runtime\、一键启动DeepSeek-Harness.bat）
├── tools\                             宿主升级工具五件套
│   ├── analyze-compat.mjs             双门兼容分析器（宿主门 peer + 市场门 engines）
│   ├── probe-native.mjs               原生依赖探针（node-pty/koffi/sharp/sherpa-onnx-node）
│   ├── check-runtime-patches.mjs      本机 UI 补丁适配性检查（先检查后应用）
│   ├── apply-runtime-patches.mjs      事务型补丁应用器（全部命中才写回）
│   └── watch-and-upgrade.ps1          升级看守器（等 3080 空闲→升级→重启）
└── deepseek-Harness插件及其数据\        （所有维护脚本都在这里）
    ├── 升级DSH运行时.ps1                通用升级引擎（自动探测启动器根目录）
    ├── 升级DSH到0.2.0-rc.2.ps1 / .cmd   0.2.0-rc.2 冻结实例（已验证）
    ├── 升级配置.json                    目标版本知识：补项/升版/豁免/断言
    ├── 开始自动升级.cmd                  升级看守器入口（自动回退定位 tools\；必须用户双击）
    ├── 使用说明.md / DSH宿主升级SOP.md / F12自查修复流程说明.md / 插件无损升级流程.md
    ├── f12-audit-repair.ps1 / .cmd      F12 自查修复主流程 / 双击入口
    ├── update-plugins.ps1               插件无损升级工作流（当前标准）
    ├── auto-update.ps1                  定时包装（计划任务每日 02:30）
    ├── upgrade-plugins.ps1 / .cmd       旧版「升级+补丁+重启+验收」闭环（保留兼容）
    ├── maintain.ps1 / 维护DeepSeek-Harness.cmd   深度维护（-Fix/-Update/-CheckUpdate）
    ├── apply-adaptations.ps1 + patch-data.json   幂等补丁体系（核心修复手段）
    ├── patch-runtime-tree.mjs           本机 runtime 私有 UI 补丁脚本
    └── dsh-home\ / 插件自愈中心\         运行时数据（本包不含，部署机上已有）
```

- 部署映射：仓库 `data\*` → 数据目录；仓库 `launcher-root\*` → 启动器根目录；仓库 `docs\*.md` → 数据目录。
- 新机器部署：仓库根目录 `deploy.ps1`（默认只校验，`-Apply` 才复制；`-Root` 显式指定目标，默认自动向上探测）。
- 参考机（本机）所有文件已在位：直接按下面命令跑，勿动仓库副本。
- `DSH_HOME` 未显式设置时脚本自动回退到 `<数据目录>\dsh-home`；宿主升级脚本会显式设置并打印，**执行前核对打印值指向 `deepseek-Harness插件及其数据\dsh-home`**。

## 1. 决策表（用户请求 → 流程）

| 用户说 | 走哪条流程 | 入口 |
| --- | --- | --- |
| 体检 / 查错 / 控制台报错 / F12 有红 / 修一修 | A. F12 自查修复 | `f12-audit-repair.cmd` |
| 插件有新版本 / 升级插件 / 无损更新 | B. 插件无损升级 | `update-plugins.ps1` |
| 升级 dsh 本体 / 宿主大版本 / 0.2.0-rc.2 | C. 宿主升级 SOP | `升级DSH运行时.ps1` |
| 日常维护 / 更新主框架 / 重打补丁 | 维护链 | `维护DeepSeek-Harness.cmd` |
| 升级后想自动重启一体化（旧习惯） | B 的旧版闭环 | `upgrade-plugins.cmd` |

**串联关系（升级后必读）**：宿主升级 P6.5 自动重放 `apply-adaptations.ps1`（幂等），P6.6 自动跑 `maintain.ps1 -Update`（透传宿主版本给 `update-plugins.ps1 -Apply`）。因此一次宿主升级 = 换运行时 → 插件级适配 → 插件层按新宿主对齐，三流程天然兼容。
**宿主版本单一真源**：内置运行时 `runtime\node_modules\@deepseek-ai\dsh\package.json`。所有工具解析顺序均为：显式参数 → 内置运行时 → 环境变量 → 源码 checkout → 兜底。不要读 `deepseek-harness\package.json`（会长期停在旧值）。

## 2. 流程 A：F12 自查修复（5 阶段）

```
powershell -ExecutionPolicy Bypass -File f12-audit-repair.ps1               # 全量（含无头浏览器采集）
powershell -ExecutionPolicy Bypass -File f12-audit-repair.ps1 -SkipCapture  # 跳过浏览器采集（快速体检）
powershell -ExecutionPolicy Bypass -File f12-audit-repair.ps1 -NoRepair     # 只查不修
powershell -ExecutionPolicy Bypass -File f12-audit-repair.ps1 -LiveUrl <url> # 手动指定 token URL
```

阶段：1 服务探活（dsh :3080 / Ollama :11434 / OpenViking :1933）→ 2 补丁完整性（5 个幂等标记，缺失自动重跑 `apply-adaptations.ps1`）→ 3 宿主路由冒烟 → 4 无头 Chrome CDP 采集 15 秒（console.error / 异常 / 4xx·5xx / boot 状态）→ 5 签名分类 + 时间戳报告。

- 退出码：0 = PASS；1 = REVIEW。报告写脚本同目录 `f12-report-<时间戳>.md`。
- 可降级：浏览器不可用 / 无 token / 无 Chrome 时逐级降级，其余阶段照常，不中断。
- 依赖：Chrome/Edge；`%LOCALAPPDATA%\DeepSeek-Harness\tools\cdp-lib.mjs`（启动器引擎自带）；采集器 `f12-capture.mjs` 自包含；工具目录不可写时自动落 `.f12-tools`。
- 判定语义（设计行为与真故障分开）：
  - 真故障：`pet-404`、`ego-watch-stop-409`（→ Phase 2 已自动重打补丁）、`agent-team-react130`（第三方旧 API，需先适配再装）、`ollama-tags-500`（→ Phase 1 自动修悬空 junction 并还原 models.bak-*）、`whale-audio-warning`（→ Phase 2 重打手势门禁补丁）。
  - 噪音：`changes-summary-404`（设计行为）、`net-abort`（导航中止）。
- 扩展签名表：`Classify-Entry` 加一行 + 对应 Phase 加探测/修复动作，见流程文档第五节。

## 3. 流程 B：插件无损升级（8 阶段）

```
powershell -ExecutionPolicy Bypass -File update-plugins.ps1                  # 检测（默认，只读）
powershell -ExecutionPolicy Bypass -File update-plugins.ps1 -SelfTest        # 自检：semver 断言+补丁标记+锚点模拟+引擎下限+API 探针
powershell -ExecutionPolicy Bypass -File update-plugins.ps1 -Deep            # 深度检测（下载 tarball 做新版本锚点预检，慢）
powershell -ExecutionPolicy Bypass -File update-plugins.ps1 -Apply           # 执行升级
powershell -ExecutionPolicy Bypass -File update-plugins.ps1 -AutoApply       # 自动化模式（只升 npm 插件，跳过 git 依赖）
powershell -ExecutionPolicy Bypass -File update-plugins.ps1 -Filter "dsh-*"  # 只检测指定插件（通配）
powershell -ExecutionPolicy Bypass -File update-plugins.ps1 -HostVersion 0.2.0-rc.1  # 宿主版本重新标定
```

阶段：1 检测（npmjs 真值 + 锁文件 commit，file:/link: 与 @deepseek-ai/* 跳过）→ 2 镜像同步门禁（npmmirror 已同步才动手，-Apply 时最多等 10 分钟/包）→ 3 三层兼容预检（peer 硬门槛 / engines 软门槛 / 补丁锚点模拟）→ 4 备份 → 5 安装（`pnpm install --ignore-scripts --config.minimumReleaseAge=0`）→ 6 补丁重打（`apply-adaptations.ps1` 幂等）→ 7 验证（版本核对 + 回环 API 探针 + degraded 空 + 异常标签 = 0 + cloudflared.exe 恢复）→ 8 报告（`修复记录-<时间戳>-自动升级.md`）。

- 硬不兼容自动降档到「宿主兼容线最新版」（如 better-sidebar 0.24.1→0.22.1）；无兼容版暂缓（session-insights 0.5.1，宿主 0.2.0-rc.1 起解锁）。
- 回滚：备份目录还原 package.json / pnpm-lock.yaml / pnpm-workspace.yaml → `pnpm install --config.minimumReleaseAge=0 --ignore-scripts` → 重跑 `apply-adaptations.ps1`。
- 自动化：`auto-update.ps1` 包 `-AutoApply`，日志 `插件自愈中心\logs\auto-update-<时间戳>.log` + `auto-update-history.log`；计划任务 `DSH-Plugin-Lossless-AutoUpdate` 每日 02:30（查询 `schtasks /Query /TN "DSH-Plugin-Lossless-AutoUpdate"`，删除 `schtasks /Delete /TN ... /F`）。
- 边界：自动化只升 npm 插件；git 依赖（ego-browser 等）留给人工 `-Apply`（会重启浏览器窗口）；宿主门禁插件自动 pin 精确版本。

## 4. 流程 C：宿主升级 SOP

```
cd <数据目录：deepseek-Harness插件及其数据>
.\升级DSH运行时.ps1 -StageOnly   # 暂存目标版本到 runtime-next（不停宿主）
.\升级DSH运行时.ps1 -Analyze     # 双门分析 + 配置一致性（只读）
.\升级DSH运行时.ps1 -DryRun      # 打印完整计划
# 关闭启动器窗口（宿主必须停止）后：
.\升级DSH运行时.ps1              # 正式升级（备份→交换→断言→启动，失败自动回滚）
.\升级DSH运行时.ps1 -VerifyOnly  # 事后组合树断言
.\升级DSH运行时.ps1 -Rollback    # 反悔
```

- 引擎会自动向上探测启动器根目录（`runtime\`、`tools\`、`logs\`、启动器 bat 都以探测结果为准）；`-Root <沙箱目录>` 仍可做完整破坏性演练。
- 换目标版本只改 `升级配置.json`（targetVersion / bundlesToAdd / packageUpgrades / exemptions / localPeerPatches / assertContains）。
- 验收门禁 G0–G7：宿主已停、原生探针 4/4、分析全覆盖、UI 补丁痕迹 3/3、dump-config 0 跳过、关键条目在册、真启动无失败 fiber、浏览器挂载清单一致、`maintain.ps1 -Update` 完成。
- **改流程必跑沙箱演练**：按 `DSH宿主升级SOP.md` 第八节建 `_e2e`（junction + 副本 profile），`-Root <沙箱目录> -Analyze / -NoStart / -Rollback -NoStart` 三连跑通再碰生产。
- `开始自动升级.cmd`（数据目录）看守器**必须用户双击**（宿主体外）：等待 3080 空闲 → 自动升级 → 重启启动器 → 自动 `-VerifyOnly`。它先找数据目录下 tools\，找不到自动回退到启动器根目录 tools\。代理会话不能替用户埋伏看守器。
- 暂存区一次性：升级成功后 `runtime-next\` 被消耗，重跑先 `-StageOnly`（缺暂存区会 exit 2 拦截，不会误动）。
- 冻结实例 `升级DSH到0.2.0-rc.2.cmd` 是本次目标版本的已验证入口，等价 `升级DSH运行时.ps1` + 冻结配置。

## 5. 维护链与交叉修复

- `维护DeepSeek-Harness.cmd -Update`：检查版本 + 更新主框架 + 插件工作流（自动透传内置运行时版本）；`-SkipPluginUpdate` 只更主框架；`-HostVersion <v>` 显式覆盖。
- `maintain.ps1 -Fix`：重跑 `apply-adaptations.ps1`（补丁复发时首选）。
- `upgrade-plugins.cmd -Apply`（旧闭环）：备份 → pnpm 升级 → 重打补丁 → 重启服务 → F12 验收。仍可用，但新工作优先 `update-plugins.ps1`。
- `patch-runtime-tree.mjs` 由 `check-runtime-patches.mjs` / `apply-runtime-patches.mjs` 消费（参数 `<patchScript> <runtimeDir> <workdir>`），会自动适配嵌套/提升布局；**不要脱离工具单独运行它**（追加型补丁不幂等，重复应用会重复追加）。

## 6. 安全边界（违反即停）

1. 破坏性动作（`-Apply`、正式升级、`-Rollback`）必须先 `-DryRun`/`-Analyze`/检测模式给用户过目，确认后再执行。
2. 宿主升级前 3080 必须空闲；升级中避免正在进行的浏览器任务（ego 会热重载并重启窗口）。
3. 看守器（自动升级）只能由用户双击启动，绝不从宿主体内派生。
4. 永不原地改写运行中的 `runtime\`（只能暂存区 → 原子互换）；断言失败自动回滚。
5. 改任何 `.ps1` 后：UTF-8 with BOM + CRLF；`.bat` 必须 CRLF 且注释只用 ASCII；函数名避开内置别名（单字母函数名在 PS 5.1 会撞 `Get-History`）；原生调用统一 `Invoke-Native` 包（`$ErrorActionPreference='Stop'` 会吃掉原生 stderr）。
6. 回滚必须连依赖一起退（还原 manifest 后重跑 pnpm install），只还原 package.json 不够。
7. 每次运行留痕：`f12-report-*.md` / `修复记录-*.md` / `插件自愈中心\备份\` / `logs\`。修完把结论写一条 dsh-memento 记忆（agent 轨道），下次升级有据可查。

## 7. 给代理的执行提示

- 先跑只读模式（`-SelfTest` / `-Analyze` / 检测模式 / `-NoRepair`），把输出与门禁对照后，再向用户申请破坏性步骤。
- PowerShell 5.1 优先：`powershell -ExecutionPolicy Bypass -File <脚本>`，不要用 pwsh 7 运行这些脚本。
- 报告/日志先 `Select-String` 关键行（`[FAIL]`、`skipping profile bundle`、签名表项），再决定下一步。
