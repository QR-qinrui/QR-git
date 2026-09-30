## 变更说明

<!-- 一句话说明这个 PR 改了什么、为什么 -->

关联 Issue：#

## 验证清单

- [ ] PS 5.1 语法解析通过（所有改动过的 `.ps1`）
- [ ] 编码规范：`.ps1` UTF-8 with BOM + CRLF；`.cmd` CRLF + ASCII 注释
- [ ] 只读模式自测通过（`deploy.ps1` / `-SelfTest` / `-Analyze` / 检测模式）
- [ ] 破坏性改动已在沙箱或 -DryRun 演练过，证据附在 PR 描述
- [ ] CHANGELOG.md 已按 Keep a Changelog 更新

## 影响范围

- [ ] 仅文档/模板
- [ ] 补丁体系（patch-data.json / apply-adaptations.ps1）
- [ ] 流程脚本（升级 / 体检 / 维护）
- [ ] 部署布局或 deploy.ps1
