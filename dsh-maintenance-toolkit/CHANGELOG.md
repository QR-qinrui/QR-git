# Changelog

All notable changes to this project are documented in this file.
The format is based on [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/lang/zh-CN/).

## [1.0.0] - 2026-09-30

### Changed

- 维护脚本统一部署在数据目录（`deepseek-Harness插件及其数据\`），启动器根目录只保留 `tools\` 五件套
- `升级DSH运行时.ps1` / `升级DSH到0.2.0-rc.2.ps1` 改为自动向上探测启动器根目录（含 `runtime\` 与数据目录的目录），生产/沙箱判定改为「Root 是否指向探测到的启动器根目录」
- `tools\watch-and-upgrade.ps1` 与 `开始自动升级.cmd` 适配新布局（升级脚本路径指向数据目录，cmd 自动回退定位 tools\）
- `deploy.ps1` 目标根目录自动探测，映射随新布局更新
- 发布脱敏：`docs\`、`data\使用说明.md` 与补丁脚本注释中的本机绝对路径替换为 `<launcher-root>` / `<user-home>` 占位符（`maintain.ps1` 的功能锚点路径保留）

### Added

- **流程 A · F12 自查修复**：`f12-audit-repair.ps1/.cmd`
  - 5 阶段：服务探活（dsh/Ollama/OpenViking）→ 补丁幂等核验 → 路由冒烟 → 无头 Chrome CDP 采集 → 签名分类报告
  - 退出码 0=PASS / 1=REVIEW，报告 `f12-report-<时间戳>.md`，可降级运行
- **流程 B · 插件无损升级**：`update-plugins.ps1` + `auto-update.ps1`
  - 8 阶段：双源检测 → 镜像同步门禁 → 三层兼容预检 → 备份 → 精确升级 → 幂等补丁重打 → 指标化验证 → 报告
  - `-SelfTest` / `-Deep` / `-Apply` / `-AutoApply` / `-Filter` / `-HostVersion`
  - 兼容旧版 `upgrade-plugins.ps1/.cmd`（升级+补丁+重启+验收闭环）
- **流程 C · 宿主升级 SOP**：`升级DSH运行时.ps1` + `tools\` 五件套 + `升级配置.json`
  - 暂存 → 双门分析 → 沙箱演练 → 备份 → 原子交换 → 组合树断言 → 启动验收，失败自动回滚
  - 0.2.0-rc.2 冻结实例 `升级DSH到0.2.0-rc.2.ps1/.cmd`、看守器 `开始自动升级.cmd`
- **幂等补丁体系**：`apply-adaptations.ps1` + `patch-data.json`（pet / prompt-enhance / ego / whale / junction / 引擎下限归一化）
- **本机 runtime UI 补丁**：`patch-runtime-tree.mjs` + 检查/应用器
- **维护链**：`maintain.ps1` / `维护DeepSeek-Harness.cmd`（-Fix / -Update / -CheckUpdate，宿主版本单一真源）
- **工程文件**：`SKILL.md`（Agent 技能入口）、`deploy.ps1`（部署/校验器）、三份流程文档、两份实战修复记录

### Fixed

- 宿主版本「单一真源」四处修复：`maintain.ps1` / `update-plugins.ps1` / `apply-adaptations.ps1` 统一为「内置运行时优先」解析
- 引擎下限归一化改为正则通用匹配（多覆盖 4 个 0.4.4 家族包）
- F12 报告新增 watched 插件版本，报错与版本直接关联
- PS 5.1 三坑免疫：UTF-8 BOM + CRLF、`.bat` CRLF + ASCII 注释、函数名避内置别名、原生调用走 `Invoke-Native`
