# Changelog

本项目遵循 [Semantic Versioning](https://semver.org/lang/zh-CN/)。

## [1.0.0] - 2026-09-29

首次发布。全部组件已在 dsh 0.1.7-rc.2 + Node 22/26 生产环境实测验证。

### Added

- `packages/dsh-compat-apiproxy@0.1.1-rc.2-shim.1`
  - 零依赖 `RpcId` 恒等垫片，修复 `@limuyang2/dsh-agent-team@0.1.4` 在 dsh 0.1.7 上的 `failed to import` 崩溃
  - 语义与官方实现一致（官方同为恒等函数，仅类型层 brand）
- `packages/dsh-compat-settings-scope@1.1.0`
  - 浏览器半包：`settingsScope → webUiSettings` 别名服务，修复旧客户端插件 `entry did not activate` 致命错误
  - 宿主半包：`settings.register` 最小语义桥（get/set/update/watch），修复 `dsh-ego-browser@0.8.5` 的 `register is not a function`
  - 幂等设计：官方恢复对应 API 时垫片自动跳过
- `scripts/install.mjs`：可复现安装器（时间戳备份、幂等写入、可选 pnpm install、BOM 保留）
- `scripts/self-check.mjs`：确定性自检（9 组校验，退出码 0/1，ASCII 输出，支持 `--profile-dir` 部署校验）
- 文档：使用说明、配置文档、兼容模式总结
