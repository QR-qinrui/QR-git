# dsh-compat-settings-scope

dsh 0.1.7+ 设置服务的双端兼容垫片：浏览器半包 + 宿主半包。

## 职责一：`settingsScope` 别名（浏览器半包 `lib/client.js`）

dsh 0.1.7 客户端把 settings 服务从旧的 `settingsScope` 迁移到 `webUiSettings`，但没有在 cordis service registry 注册旧名字。任何仍 `inject: ['settingsScope']` 的第三方插件（dsh-prompt-enhance、dshmarket 等）都会永久 pending，触发 web boot 的 `entry did not activate` 致命错误。

本半包在 profile 顶层把 `settingsScope` 注册为 `webUiSettings` 的别名服务，所有旧插件（含未来新装的）零改动正常激活。

**关键设计（防 pending）**：`webUiSettings` 由 dsh-web-all 异步动态挂载，可能延迟提供。因此顶层 `inject` 保持为空 `[]`，桥接放在 `apply` 内的**次级 fiber**（内联 `ctx.inject`）中——次级 fiber 的 pending 不阻塞 entry 激活，也不纳入未激活计数。全程软获取 + try-catch，绝不抛错拖垮 boot。

## 职责二：`settings.register` 桥（宿主半包 `lib/index.js`）

dsh 0.1.7 的 SettingsForms 服务仅提供 configure/describe/update/replace/mutate，移除了 0.1.2-era 的 `register(ns, schema, { base })`。旧插件（如 dsh-ego-browser@0.8.5）激活期调用会抛 `register is not a function`。

本半包在运行期为 SettingsForms 实例补齐最小语义实现：

| 方法 | 语义 |
|------|------|
| `scope.get()` | 返回当前值（初始为 `{ base }` 传入的配置，缺省 `{}`） |
| `scope.set(v)` | 覆盖写并通知 watcher |
| `scope.update(patch)` | 浅合并并通知 watcher |
| `scope.watch(cb)` | 订阅变更，返回退订函数；watcher 异常隔离不污染宿主 |

语义与旧版只读场景一致；真正的持久化编辑仍走新版 SettingsForms。**幂等**：官方日后恢复 `register` 方法时本 shim 自动跳过。

## 激活条件

本包必须被列入 profile 的 `dsh.profile.bundles`（安装器自动处理）；`cordis.patch.yml` 的 insert 条目才会生效。

## 安装

```bash
node ../../scripts/install.mjs --profile-dir "<你的 dsh-home>/profiles/web"
```

详见[套件 README](../../README.md)。
