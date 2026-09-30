# DSH 宿主升级 SOP（可复现流程）

> 适用范围：把一键启动器内置的 DSH 宿主（`runtime\`）从一个版本升到另一个版本，
> 要求**无损**（现有插件与本地自增功能不丢）、**可回滚**、**可复现**。
> 本文由 2026-09-30 那次 0.1.7-rc.2 → 0.2.0-rc.2 的实践提炼而成。
> 公开发布版已脱敏：本机绝对路径已替换为 <launcher-root>（一键启动器目录）与 <user-home>（用户主目录）占位符。

## 0. 一句话

宿主升级不是「换一个 dsh 包」，而是**换一整个运行时 + 重新对齐 25 个 bundle 的兼容面**；
兼容面由宿主的 peer 门禁决定，所以流程的核心是**先分析、再适配、后交换、有断言、能回滚**。

## 1. 流程总结（这次实际走的阶段）

| 阶段 | 做了什么 | 产出 | 门禁 |
| --- | --- | --- | --- |
| P-1 演练 | 在 `_e2e` 沙箱（junction 镜像生产目录）里先跑一遍含交换与回滚的全流程 | 演练日志 | 交换与回滚都跑通、生产未被触碰 |
| P0 前置 | 查宿主实际运行位置与版本、磁盘、pnpm、暂存区 | 确认「宿主是内置 `runtime\`，不是 npm 全局」 | 宿主已停止、暂存区版本正确 |
| P1 暂存 | `npm install --prefix runtime-next @deepseek-ai/dsh@<目标>`，回填 npm，缓存指向工作区内 | 独立暂存运行时（565 MB） | 原生依赖探针四项全过 |
| P2 分析 | 用暂存宿主跑 `--dump-config`，把每个 bundle 的 peer 与目标版本比对 | 不兼容清单 + 处置建议 | 缺口全部被配置覆盖 |
| P2.5 补丁 | 检查暂存运行时是否带上**本机 UI 补丁**；干净态则用应用器打上 | 带定制 UI 的新运行时 | 补丁痕迹 3/3 齐备 |
| P3 适配 | 能升级的升级、本地包放宽 peer、升无可升的开精确豁免 | 适配后的 profile | 每条适配都有依据 |
| P4 交换 | 备份 profile → `runtime\` ↔ 暂存区**原子改名互换**（旧版保存不删） | 可回滚的运行时时点 | 交换前 3080 必须空闲 |
| P5 断言 | `--dump-config`：0 个 `skipping profile bundle` + 关键条目在册 | 组合树证据 | 断言失败自动回滚 |
| P6 实跑 | 单独端口真启动 + HTTP + 浏览器挂载清单 | 界面截图 + 客户端插件清单 | 无失败 fiber、无错误文本 |
| P6.6 维护 | 生产模式升级成功后运行 `maintain.ps1 -Update`，让**插件层按新宿主对齐**（失败只告警、不回滚升级） | `logs\升级DSH-<版本>-maintain.log` | 维护链 exit 0（或明确告警） |

## 2. 特点与规律（这次提炼出的规律）

1. **两道彼此独立的门**：**市场门**（安装前读 registry 的 `dsh.engines.dsh`，不匹配拒绝安装）
   与**宿主门**（每次启动按 `peerDependencies` 决定挂不挂）。装得上 ≠ 跑得起来。
2. **宿主门的判定面很窄**：只比对 `peerDependencies` 里 `@deepseek-ai/dsh*` 的名字，
   用 `semver.satisfies(..., { includePrerelease: true })`；**不认** `peerDependenciesMeta.optional`，
   **不认** `dsh.engines` 字段。所以给 peer 加 `optional` 没用，改范围或开豁免才有用。
3. **精确 pin 是最大陷阱**：`dsh-session-insights@0.5.1` 的 peer 写的是精确 `0.2.0-rc.1`，
   于是在 `0.2.0-rc.2` 上**同样不兼容**（它自己的 `engines` 却写着 0.2.0-rc.1，误导性很强）。
   判断必须按 peer 算，不能看 engines。
4. **运行中的会话会骗人**：界面一切正常，可能只是旧代码还在内存里（`patchReload: live` 不会
   让被跳过的 bundle 复活）。判定只能看 `dsh --dump-config`，不能看观感。
5. **升级会"换向"不兼容面**：0.1.7 上被跳过的是家族包与 better-sidebar（要求 ≥0.2.0-rc.1），
   0.2.0 上被跳过的是四个 0.1.x 老插件。**无损 = 两侧都要处理**，不存在只升不管。
6. **启动器自带的 `-UpgradeDsh` 升不到本体**：内置 `runtime\dsh.cmd` 优先级高于 PATH 与 npm 全局，
   而它执行的是 `npm install -g`（prefix 实测 `%APPDATA%\npm`）→ 界面会打印"更新完成"，宿主版本不变。
7. **市场会按宿主版本自动"找兼容版本"**：它会把插件降到与当前宿主匹配的旧版（watch 到
   better-sidebar 0.21.1→0.22.1 的自动回退）。手工安装的版本可能被它再次调整，
   装完要看 `.dsh-market\log.ndjson` 的 `find-compatible` 行。
8. **本机对 runtime 本身打了私有补丁**（`deepseek-Harness插件及其数据\patch-runtime-tree.mjs`：
   直接改写 `@deepseek-ai/dsh-client-ui-*/lib/*.js` —— 挽具框架 CSS、暗色默认 `#0a0e14`、
   服务状态点、skip-link、移动端适配、composer/palette 的 `frame` 类…）。**换成干净的 npm 运行时
   会把这些一起换掉**，UI 直接退回原版；而旧补丁脚本写死了 0.1.7 的嵌套布局路径
   （`dsh\node_modules\@deepseek-ai\…`），新运行时是提升布局（`node_modules\@deepseek-ai\…`），
   不能直接复用。→ 所以宿主升级必须包含 **P2.5 补丁门禁**。

## 3. 可复现流程（命令级）

工具五件套（都在启动器目录）：

| 文件 | 作用 |
| --- | --- |
| `升级DSH运行时.ps1` | 通用引擎：P0–P7 全流程，`-Analyze` / `-DryRun` / `-StageOnly` / `-VerifyOnly` / `-Rollback` |
| `升级配置.json` | 目标版本知识：要补的 bundle、要升的插件、要开的豁免、本地包 peer 放宽、验收断言 |
| `tools\analyze-compat.mjs` | 兼容缺口分析器：**同时模拟两道门**（宿主门 peer + 市场门 engines）并读取 `compatibility.json` 豁免；解析顺序与宿主启动一致（内置运行时优先）；判定与 `--dump-config` 实测**逐条一致**；给出「可升级 / 本地放宽 / 只能豁免」 |
| `tools\probe-native.mjs` | 原生依赖探针：`node-pty`/`koffi`/`sharp`/`sherpa-onnx-node` 能否加载 |
| `tools\check-runtime-patches.mjs` | 本机运行时补丁适配性检查：把 `patch-runtime-tree.mjs` 的每条锚点拿到目标运行时上逐条试，报告「可原样应用 / 需人工移植」 |
| `tools\apply-runtime-patches.mjs` | 事务型补丁应用器：在镜像里打补丁，**全部小节成功才写回**，避免半残；自动适配嵌套/提升两种布局 |
| `tools\watch-and-upgrade.ps1` + `开始自动升级.cmd` | 自动升级看守器：等你关闭启动器窗口后自动执行升级并重启（`-DryRun` 演练等待逻辑，`-Port` 可换探测端口自测） |

标准动作序列：

```powershell
cd "<launcher-root>"

# 1) 暂存目标版本（不需要停宿主；只写 runtime-next\）
.\升级DSH运行时.ps1 -StageOnly

# 2) 分析兼容缺口 + 校验配置是否覆盖（只读，可随时跑）
.\升级DSH运行时.ps1 -Analyze

# 3) 演练：打印完整计划，确认无误
.\升级DSH运行时.ps1 -DryRun

# 4) 关掉一键启动器窗口（宿主必须停止），然后正式升级
.\升级DSH运行时.ps1

# 5) 事后核验 / 反悔
.\升级DSH运行时.ps1 -VerifyOnly
.\升级DSH运行时.ps1 -Rollback
```

**验收门禁（G0–G6，全过才算成功）**

- G0 宿主已停止（3080 空闲）、暂存区版本 == 目标、pnpm 可用、磁盘 ≥3 GB
- G1 原生依赖探针 4/4 通过
- G2 分析结果**全部**被配置覆盖（P2 一致性检查，未覆盖项会被点名）
- G2.5 本机 UI 补丁齐备（暗色默认 + 服务状态点 + skip-link 痕迹 3/3；干净态会被门禁拦下）
- G3 交换后 `--dump-config` **0 个** `skipping profile bundle`
- G4 关键条目在册（`升级配置.json` 的 `assertContains`）
- G5 真启动后 HTTP 可访问、无失败 fiber
- G6 页面挂载清单与预期一致（家族包 + 本地 link 包都在）
- G6.5 插件级适配已重放（`apply-adaptations.ps1`，幂等；失败只告警不回滚）
- G6.6 维护链已完成（仅生产模式）：`maintain.ps1 -Update` 以**内置运行时**为宿主版本跑完插件层对齐
- G7 升级后自检：`升级DSH运行时.ps1 -VerifyOnly`、启动器 `-Doctor` / `-VerifyPlugins`

## 4. 不变式（保证核心稳效发挥的硬约束）

1. **永不原地改写正在运行的 `runtime\`**：一律「暂存区安装 → 原子改名互换」，旧版改名保留。
   正在运行的 node 会锁住原生 `.node`，原地覆盖必然失败或半残。
2. **任何改动前先落状态文件**：`logs\升级DSH-<版本>.state.json` 记录备份路径与阶段，
   `-Rollback` 只依赖它；profile 关键文件（package.json / pnpm-lock / compatibility.json /
   cordis.patch.yml）必须先备份。
3. **回滚要把依赖也退回去**：只还原 package.json 不够，必须再 `pnpm install`，
   否则 node_modules 里留着新版插件（本流程已内置）。
4. **用断言代替观感**：组合树断言（0 跳过 + 关键条目）是唯一的通过标准；界面正常不算通过。
5. **配置与分析强制对齐**：分析器说"不兼容"的每一项，配置里必须有对应动作，
   否则 P2 点名为未覆盖——这一条正是这次拦下 `session-insights` 误判的机制。
6. **三层验证缺一不可**：静态（dump-config）→ 运行时（真启动 + HTTP）→ 视觉（浏览器挂载清单/截图）。
   只做静态会漏掉客户端注入问题（本地包 `deepseek-idesign` 的 `inject` 就属于这类）。
7. **证据落盘**：`logs\升级<版本>-验证证据\` 存新旧 dump-config、分析 JSON、原生探针输出、界面截图。
   下次升级可以直接 diff 上一个版本的行为基线。
8. **失败自动回滚，且回滚路径要提前演练**：`-DryRun` 会把计划打全，正式跑只在断言失败时回滚。
9. **换运行时 = 换掉本机私有补丁**：`runtime\` 里的 UI 补丁是"本地自增"的一部分，
   必须在新运行时上**重放并验证**；补丁必须事务化（全部命中才写回），因为追加型补丁不幂等、
   重复应用会重复追加 CSS/组件。
10. **显式设置 `DSH_HOME`**：启动器只在自己的进程里把 `DSH_HOME` 指到
    `<启动器目录>\deepseek-Harness插件及其数据\dsh-home`；从资源管理器双击升级脚本时用户环境里
    往往没有这个变量，不显式设置的话 dsh 会去动 `%USERPROFILE%\.dsh` 这个**错误的** profile，
    豁免与断言全部打在别处。两个升级脚本都已显式设置并打印。
11. **改流程后必须跑沙箱演练**：用 `-Root` 指向 `_e2e`（`runtime` / `runtime-next` / `tools`
    用 junction 指向生产，profile 用副本 + `node_modules` junction），就能完整跑通"交换 + 回滚"
    而绝不触碰生产。第一次执行流程不该是拿生产当小白鼠。
12. **PowerShell 判空要按条数，不能按真值**：空对象 `{}` 是 **真**（本次就是因此让空配置去跑了
    `pnpm add`）。配置里任何"字典/列表"都要用 `@(...PSObject.Properties).Count -gt 0` 判断。

## 5. 这次踩过的坑（工程细节，避免重犯）

| 坑 | 现象 | 处理 |
| --- | --- | --- |
| `$ErrorActionPreference='Stop'` + 原生 stderr | dsh/pnpm 把告警写 stderr，PowerShell 升级成终止错误，脚本半途而死 | 原生调用统一包 `Invoke-Native`（临时降级 + 带出 `$LASTEXITCODE`） |
| `.ps1` 无 BOM | 中文 Windows 的 PowerShell 5.1 按 ANSI 读，中文串与括号解析错乱 | 一律 UTF-8 **with BOM** + CRLF |
| `.bat` 用 LF 换行 | cmd 把 `rem` 注释行当命令执行，报 `'click' 不是内部或外部命令` | `.bat` 必须 CRLF；注释只用 ASCII |
| 函数名撞内置别名 | `function H($p)` 被解析成 `h`（Get-History），哈希静默变 null | 避免单字母函数名，用 `Get-Sha256` 这类全名 |
| npm 11.19 的 allowScripts | 5 个安装脚本被拦（含 `dsh-subprocess-local`） | 核实为 Windows 无关项（只补 POSIX 可执行位 / no-op / 赞助信息），无需处理 |
| `npm install --prefix` 会裁掉预拷的 npm | 暂存区里 `node_modules\npm` 被 prune | **装完再**把 npm 拷进暂存区 |
| 沙箱/并发间歇性拒绝 exec | `node.exe`/`cmd.exe` 报 `Access is denied`，或静默无输出 | 重试；必要时对同一命令带理由放宽一次沙箱 |

## 6. 下次升级怎么做（例如 0.3.x）

> 注：升级成功后暂存区 `runtime-next\` 会被**消耗掉**（换到了 `runtime\`）。
> 想再跑一次（或演练）必须先重新 `-StageOnly`；直接跑升级脚本会以「缺少暂存区」exit 2 拦下，不会误动。

1. 编辑 `升级配置.json`：改 `targetVersion`，按需改 `bundlesToAdd` / `packageUpgrades` /
   `exemptions` / `exemptionsToRevoke` / `localPeerPatches` / `assertContains`。
2. 跑 `-StageOnly` 装新版本（旧配置里的 `assertContains` 先留原样也行，P6 会告诉你缺什么）。
3. 跑 `-Analyze`：分析器会列出新的缺口与建议；把建议填回配置，直到 P2 全绿。
4. `-DryRun` 复核 → 停宿主 → 正式升级。
5. 升级后把本次证据目录改名归档，作为下一次的行为基线。

## 7. 本次（0.2.0-rc.2）的既成事实

- 暂存区：`runtime-next\`（`@deepseek-ai/dsh@0.2.0-rc.2`，内置 node v26.10.0 + npm 11.19.1）
- 已授予的精确豁免（写入 profile 的 `compatibility.json`）：
  `dsh-session-insights@0.5.1`、`dsh-context-doctor@0.7.2`、`@loserfox/distill@0.1.0` → `0.2.0-rc.2`
- 本地适配：`deepseek-idesign` 的 4 条 peer 由 `>=0.0.1-rc.1 <0.2.0-0` 放宽为 `<0.3.0-0`
  （原文件备份：`deepseek-Harness插件及其数据\deepseek-idesign\package.json.bak-20260930-011629`）
- 需补回的 bundle：`@deepseek-ai/dsh-experimental-schedule-bundle`（0.2.0 把 schedule 三件套移出了默认 Web 组合）
- 备用方案：若希望少一条豁免，可改升宿主 `0.2.0-rc.1`（与 `session-insights@0.5.1` 的精确 pin 对齐），
  代价是宿主不是 npm `latest`，后续 pin 新版的插件会反过来不兼容。
## 8. 沙箱演练（改流程后必跑）

**为什么**：升级流程含"换目录 + 改 profile + 授权限"这类破坏性动作，第一次执行不该拿生产当实验。
沙箱用 junction 把生产目录"借"进来，交换只移动链接、不碰内容。

```powershell
$dir = "<launcher-root>"
$e2e = "$dir\_e2e"
New-Item -ItemType Directory -Path "$e2e\logs","$e2e\deepseek-Harness插件及其数据\dsh-home\profiles\web" -Force
New-Item -ItemType Junction -Path "$e2e\runtime"      -Target "$dir\runtime"
New-Item -ItemType Junction -Path "$e2e\runtime-next" -Target "$dir\runtime-next"
New-Item -ItemType Junction -Path "$e2e\tools"        -Target "$dir\tools"
New-Item -ItemType Junction -Path "$e2e\deepseek-Harness插件及其数据\dsh-home\profiles\web\node_modules" -Target "$dir\deepseek-Harness插件及其数据\dsh-home\profiles\web\node_modules"
Copy-Item "$dir\deepseek-Harness插件及其数据\dsh-home\profiles\web\package.json"        "$e2e\deepseek-Harness插件及其数据\dsh-home\profiles\web\" -Force
Copy-Item "$dir\deepseek-Harness插件及其数据\dsh-home\profiles\web\compatibility.json"  "$e2e\deepseek-Harness插件及其数据\dsh-home\profiles\web\" -Force
Copy-Item "$dir\deepseek-Harness插件及其数据\dsh-home\profiles\web\pnpm-lock.yaml"      "$e2e\deepseek-Harness插件及其数据\dsh-home\profiles\web\" -Force
Copy-Item "$dir\deepseek-Harness插件及其数据\dsh-home\profiles\web\cordis.patch.yml"    "$e2e\deepseek-Harness插件及其数据\dsh-home\profiles\web\" -Force
Copy-Item "$dir\deepseek-Harness插件及其数据\patch-runtime-tree.mjs" "$e2e\deepseek-Harness插件及其数据\" -Force
# 沙箱配置：把 packageUpgrades 置空、只留豁免与 bundles 补项，避免写穿 junction
```

```powershell
.\升级DSH运行时.ps1 -Root "$dir\_e2e" -Analyze          # 沙箱内分析
.\升级DSH运行时.ps1 -Root "$dir\_e2e" -NoStart          # 真交换 + 断言（不启动服务）
.\升级DSH运行时.ps1 -Root "$dir\_e2e" -Rollback -NoStart # 回滚
```

沙箱模式（`-Root` 非脚本目录）会自动跳过"宿主必须停止"的检查，并**跳过回滚时的 pnpm 重装**
（否则会写穿 junction 指向的真实 `node_modules`）。

**本次演练（2026-09-30）一次跑通抓出的问题，已全部修复：**

| # | 问题 | 修复 |
| --- | --- | --- |
| 1 | `-Rollback` 用裸 `Test-Listening 3080` 判宿主，沙箱模式下回滚被自己挡住 | 仅在生产模式（`$Root -eq $PSScriptRoot`）才做该检查 |
| 2 | `packageUpgrades: {}` 空对象在 PowerShell 里是**真**，导致空列表也去跑 `pnpm add` → 失败 | 改按 `@(...PSObject.Properties).Count` 判空；空数组/空项在豁免循环里 `continue` |
| 3 | 失败→回滚链条因 #1 断掉，任务停在被交换状态 | #1 修复后失败路径可回滚；并在回滚时把新运行时**放回暂存区**，修好后可直接重试 |
| 4 | P2 把"profile 里已有的豁免"误报成未覆盖 | 覆盖判定增加读取 `compatibility.json` 已有豁免 |
| 5 | 双击运行升级脚本时 `DSH_HOME` 可能不存在 → 打错 profile | 两个脚本都显式设置并打印 `DSH_HOME` |

**演练结论**：`交换 → 断言 → 升级完成(exit 0) → 回滚 → 完整还原(exit 0)`，且全程
`runtime\` 仍是真实的 0.1.7-rc.2 目录、profile 未被改动。

## 9. 自动化升级（一条命令 + 关窗即完成）

```powershell
.\开始自动升级.cmd            # 双击：它会等宿主停止，然后自动升级并重启
.\开始自动升级.cmd -DryRun    # 只演练等待逻辑
```

> ⚠️ 看守器**必须由用户双击启动**（从宿主体外）。宿主体内派生出来的进程会随宿主一起退出，
> 所以不能由 DSH 会话自己"埋伏"一个看守器；这也是"帮你自动化"的边界所在。

流程：双击 → 按任意键开始等待 → 关闭正在运行的启动器窗口 → 看守器检测到 3080 空闲（再等 5 秒
释放句柄）→ 调用已验证的升级脚本（自带备份/断言/失败回滚）→ 成功后自行把启动器拉起来。
全过程写日志到 `logs\自动升级-<时间戳>.log`；超过 `-WaitMinutes`（默认 30）仍未关窗就放弃并提示。
升级流程本身现在也包含 **P6.6 维护链**（`maintain.ps1 -Update`，仅生产模式、失败不致命），
所以一次升级就完成「换运行时 → 插件级适配重放 → 插件层按新宿主对齐」；
升级成功后看守器还会**自动跑一次 `-VerifyOnly`**，并把「升级后自检报告-<时间戳>.txt」写到 `logs\`
（含 runtime 版本前后、服务就绪状态、断言输出）——所以即使会话中断、证据也已落盘。
`-ReadyTimeoutSeconds` 可调就绪等待上限（默认 120 秒）。
## 10. 升级后与既有工具链的衔接（重要）

本机已有一套插件维护工具链，升级宿主后必须知道它们按哪个宿主版本干活：

| 工具 | 作用 | 与本升级的关系 |
| --- | --- | --- |
| `apply-adaptations.ps1` | 插件级适配：link 插件绝对 junction、pet 404 抑制、whale-widget AudioContext、家族包地板归一 | 升级流程 **P6.5 会自动重放**（幂等）。地板归已改为**按需**：只有地板高于宿主才压到宿主版本，宿主已满足则**保留真实声明**（不再让市场门读到假信号） |
| `update-plugins.ps1` | 无损插件更新工作流（检测/镜像门/备份/补丁/校验），支持 `-HostVersion` | **已修复**：`Resolve-HostVersion` 改为**内置运行时优先**（显式 `-HostVersion` > 运行时 > 环境变量 > 源码 checkout > 兜底），不再把新宿主误判成旧版本 |
| `auto-update.ps1` | 定时包装 `update-plugins.ps1 -AutoApply`（每日 02:30 的计划任务） | **当前未注册**该计划任务（实测只查到 OpenViking-Healthcheck），暂无干扰；若日后注册，同样受上面的宿主识别问题影响 |
| `maintain.ps1` | 深度维护：`-Fix` 调用 `apply-adaptations.ps1`；`-Update` 更新主框架并**透传宿主版本**给 `update-plugins.ps1 -Apply` | **已补上 `-HostVersion`**（留空则自动解析，顺序：参数 → **内置运行时 `runtime\`** → 环境变量 `DSH_HOST_VERSION` → 源码 checkout → 兜底）；`-SkipPluginUpdate` 可只更新主框架 |

**升级后的推荐动作顺序**：

```powershell
# 1) 升级（自动重放插件级适配）
.\升级DSH到0.2.0-rc.2.cmd

# 2) 组合树 + 补丁 + 家族包核验（只读）
.\升级DSH运行时.ps1 -VerifyOnly

# 3) 启动器自检
一键启动DeepSeek-Harness.bat -Doctor
一键启动DeepSeek-Harness.bat -VerifyPlugins

# 4) 维护插件（宿主版本已统一为以内置运行时为准，通常无需手写）
# 4a) 推荐：maintain 会自动取内置运行时版本并透传
.\维护DeepSeek-Harness.cmd -Update                      # = 检查版本 + 更新主框架 + 插件工作流(透传宿主版本)
.\维护DeepSeek-Harness.cmd -Update -HostVersion 0.2.0-rc.2   # 也可显式指定
.\维护DeepSeek-Harness.cmd -Update -SkipPluginUpdate    # 只更新主框架

# 4b) 直接调插件工作流也可以（它自己就会以运行时为准；-HostVersion 变成可选覆盖）
powershell -ExecutionPolicy Bypass -File "<数据目录>\update-plugins.ps1"
```

**分析器一致性校验**（改流程/改插件后建议复跑，用于确认门禁模型没跑偏）：

```powershell
# 分析器判定 vs 真实宿主门
$sk = (& .\runtime\node.exe .\runtime\node_modules\@deepseek-ai\dsh\lib\bin.js --profile web --dump-config 2>&1) |
      Select-String 'skipping profile bundle "([^"]+)"' | % { $_.Matches[0].Groups[1].Value }
# 与 .\升级DSH运行时.ps1 -Analyze 的「拦截」清单比对，两者应完全一致
```

### 宿主版本「单一真源」修复（2026-09-30）

**原则**：宿主版本只有一个权威来源——**内置运行时 `runtime\node_modules\@deepseek-ai\dsh\package.json`**；
源码 checkout（`deepseek-harness\package.json`）与 `compatibility.json` 只作兜底，因为宿主可以独立升级，
而源码 checkout 的版本号会长期停在旧值。

一次性修掉的四处（都做了备份、只增不改坏、PS 5.1 解析 0 错误）：

| 文件 | 修复 |
| --- | --- |
| `maintain.ps1` | 新增 `Resolve-HostVersion`（参数 → **运行时** → 环境变量 → 源码 checkout → 兜底）；新增 `-HostVersion` / `-SkipPluginUpdate`；`-Update` 把宿主版本**透传**给插件工作流；`主框架本地版本` 与 `chat-manager / open-in-tui 随主框架版本` 两处显示改用真实值 |
| `update-plugins.ps1` | `Resolve-HostVersion` 改为**运行时优先**（原来先读源码 checkout，会把 0.2.0 误判成 0.1.7） |
| `apply-adaptations.ps1` | 家族地板归一改为**按需**（宿主已满足则保留真实声明），宿主版本同样运行时优先、读 `DSH_HOST_VERSION` |
| `auto-update.ps1` | 包装 `update-plugins.ps1`，随之受益，无需改动（且该定时任务当前**未注册**） |

**实测证据**（升级到 0.2.0-rc.2 之后）：

```text
maintain.ps1 -Update                        → exit 0
   宿主版本：0.2.0-rc.2   ← 内置运行时 runtime\
   插件更新工作流：update-plugins.ps1 -Apply -HostVersion 0.2.0-rc.2
   host version: 0.2.0-rc.2 → all registry plugins are up to date
   → nothing to upgrade; -Apply does nothing.
apply-adaptations.ps1                        → host line = 0.2.0-rc.2；0 normalized to 0.2.0-rc.2, 19 already ok
```

本次实测：当前宿主（0.1.7-rc.2）与目标宿主（0.2.0-rc.2）**两侧都完全一致**——
0.1.7 上实际零跳过（家族包地板已被 `apply-adaptations.ps1` 归一并豁免 distill）；
0.2.0 上实际只跳 `dsh-better-sidebar`，与分析器判定相同，其余三项由 `compatibility.json` 豁免放行。
