# dsh-compat-kit

DeepSeek Harness（dsh）0.1.7+ 兼容性套件：一组**在生产环境实测验证**的兼容垫片（shim），修复为旧版 dsh API 编写的第三方插件在 0.1.7+ 宿主上的启动崩溃，附带**可复现安装器**与**确定性自检脚本**。

## 解决什么问题

dsh 0.1.7 移除了若干 0.1.x 早期的包与 API，导致一批社区插件启动失败：

| 故障现象 | 根因 | 本套件对策 |
|---------|------|-----------|
| `failed to import ... @deepseek-ai/dsh-host-apiproxy`（agent-team 等） | 0.1.7 依赖树不再携带 apiproxy 包，真包会拖入 25+ 个旧版依赖 | `dsh-compat-apiproxy`：与官方语义一致的零依赖 `RpcId` 垫片 |
| `sctx.settings.register is not a function`（ego-browser 等） | 0.1.7 的 SettingsForms 服务移除了 0.1.2-era 的 `register` 方法 | `dsh-compat-settings-scope` 宿主半包：运行期补齐最小语义实现 |
| 客户端 `entry did not activate` 致命错误（prompt-enhance、dshmarket 等） | `settingsScope` 服务名未注册，旧插件永久 pending | `dsh-compat-settings-scope` 浏览器半包：顶层注册 `settingsScope → webUiSettings` 别名 |

## 环境要求

- **Node.js >= 22**（dsh 0.1.x 硬性要求；自检会拒绝更低版本）
- **dsh >= 0.1.7-rc.2**
- pnpm（仅安装步骤需要；`--skip-pnpm` 可跳过）

Windows / macOS / Linux 均可；脚本输出为纯 ASCII，Windows GBK 控制台无乱码。

## 快速开始（可复现）

```bash
# 1. 自检套件本身（离线，无需 dsh）
node scripts/self-check.mjs

# 2. 接入你的 dsh profile（自动备份 + 幂等 + pnpm install）
node scripts/install.mjs --profile-dir "<你的 dsh-home>/profiles/web"

# 3. 验证部署结果（对真实 profile 做内容级校验）
node scripts/self-check.mjs --profile-dir "<你的 dsh-home>/profiles/web"

# 4. 重启 dsh，观察启动日志应无：
#    failed to import / settings.register is not a function /
#    skipping profile bundle / entry did not activate
```

> Windows 注意：安装前请停止正在运行的 dsh 实例——活进程会锁定
> `node_modules` 导致 pnpm 出现 EPERM rename 失败。

## 目录结构

```
dsh-compat-kit/
├── packages/
│   ├── dsh-compat-apiproxy/        # @deepseek-ai/dsh-host-apiproxy 垫片（RpcId 恒等）
│   └── dsh-compat-settings-scope/  # settingsScope 别名（浏览器端）+ register 桥（宿主端）
├── scripts/
│   ├── install.mjs                 # 可复现安装器（备份/幂等/可选 pnpm）
│   └── self-check.mjs              # 确定性自检（退出码 0/1，可接 CI）
├── docs/
│   ├── usage.md                    # 使用说明与故障排查
│   ├── configuration.md            # 配置项与 profile 集成细节
│   └── patterns.md                 # 兼容工程模式总结（经验沉淀）
└── package.json                    # npm workspaces 根清单
```

## 自检覆盖项

`self-check.mjs` 为确定性纯函数式校验（无网络、无写入），覆盖：Node 版本门槛、套件文件完整性、清单 exports 解析、`RpcId` 恒等导入测试、`settings.register` 语义 E2E（get/set/update/watch/退订/watcher 异常隔离/幂等跳过）、浏览器半包 ModuleLoader 契约、bundle patch 一致性、`node:sqlite` + FTS5 环境能力，以及（可选）对真实 profile 的部署校验（依赖声明、bundles 注册、安装内容与套件源哈希一致、安装位导入测试）。

## 卸载 / 回滚

安装器每次修改前会在 profile 目录写入 `package.json.bak-<时间戳>`；恢复该文件后重新 `pnpm install` 即可完全回滚。详见 [docs/usage.md](docs/usage.md)。

## 文档索引

- [使用说明与故障排查](docs/usage.md)
- [配置文档](docs/configuration.md)
- [兼容工程模式总结](docs/patterns.md)
- [变更记录](CHANGELOG.md)

## License

MIT（见 [LICENSE](LICENSE)）。本套件与 DeepSeek Harness 官方无隶属关系；`@deepseek-ai/dsh-host-apiproxy` 包名仅作部署本地占位，标有 `private: true`，不会发布到 npm。
