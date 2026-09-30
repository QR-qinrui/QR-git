# Contributing

感谢你愿意贡献。这个仓库把 DSH 一键启动器的运维经验固化成了脚本，贡献请遵守「可复现、可回滚、可审计」三条原则。

## 报告问题

- 用 Bug 报告模板（`.github\ISSUE_TEMPLATE\bug_report.yml`），带上：环境（宿主/插件版本）、现象、`f12-report-*.md` 或脚本输出中的关键行。
- 涉及私有路径、token 的内容请先脱敏。

## 提 Pull Request

1. Fork + 新建分支（`fix/xxx` 或 `feat/xxx`）。
2. 修改后先跑只读自测：
   ```powershell
   powershell -ExecutionPolicy Bypass -File .\deploy.ps1          # 布局校验
   powershell -ExecutionPolicy Bypass -File .\data\update-plugins.ps1 -SelfTest   # 部署机上跑
   ```
3. 遵守 PS 5.1 三坑（改脚本必读）：
   - `.ps1` 保存为 **UTF-8 with BOM + CRLF**；
   - `.bat` / `.cmd` 保存为 **CRLF**，注释只用 ASCII；
   - 函数名避开内置别名（如 `H` 会撞 `Get-History`）；
   - 原生调用统一包 `Invoke-Native`（`$ErrorActionPreference='Stop'` 会吃掉原生 stderr）；
   - 字典/列表判空按条数：`@(...PSObject.Properties).Count -gt 0`。
4. 变更写入 `CHANGELOG.md`（Keep a Changelog 格式）。
5. 破坏性动作（升级/回滚）必须在只读模式（`-Analyze` / `-DryRun` / 检测模式）通过后，且 PR 描述里写明验证证据。

## 扩展错误签名表

新错误 = 一行签名 + 一个修复动作：

1. `f12-audit-repair.ps1` 的 `Classify-Entry` 加一行；
2. 对应 Phase 加探测/修复动作；
3. `-SelfTest` 或一次全量跑通验证后更新 `CHANGELOG.md`。

## 发布流程

维护者：推 `v*` tag → Actions 自动构建 zip 并创建 GitHub Release（`.github\workflows\release.yml`）。

## 约定

- Commit message 风格：`<type>: <subject>`（feat / fix / docs / chore）。
- 不提交：`.bak-*` 备份、临时报告、`dsh-home\`、`插件自愈中心\` 运行时数据。
