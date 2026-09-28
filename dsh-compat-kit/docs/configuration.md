# 配置文档

本套件自身**零配置**（垫片无语句项）；本页说明它与 dsh profile 的全部集成触点，便于手工审计或自定义接入。

## 1. profile 集成触点总览

安装器只改动一个文件：`<dsh-home>/profiles/<profile 名>/package.json`。共三处：

```jsonc
{
  "dependencies": {
    // 触点 1：浏览器/宿主双端垫片（file: 绝对路径，正斜杠）
    "dsh-compat-settings-scope": "file:<套件绝对路径>/packages/dsh-compat-settings-scope",
    // 触点 2：apiproxy 占位垫片（以官方包名安装，供既有 import 解析）
    "@deepseek-ai/dsh-host-apiproxy": "file:<套件绝对路径>/packages/dsh-compat-apiproxy"
  },
  "dsh": {
    "profile": {
      "bundles": [
        // 触点 3：只有列入 bundles，垫片的 cordis.patch.yml insert 才会生效
        "dsh-compat-settings-scope"
      ]
    }
  }
}
```

注意：

- **`@deepseek-ai/dsh-host-apiproxy` 不需要进 bundles**——它是库不是插件，只提供 `import` 目标。
- file: 依赖经 pnpm 安装后是 node_modules 里的**副本/硬链接**；改套件源码后需重新 `pnpm install` 同步（自检的哈希比对会抓出不同步）。
- 若 profile 的 package.json 带 UTF-8 BOM，安装器会保留 BOM（dsh 的某些读取路径对 BOM 敏感，保持原样最安全）。

## 2. 垫片包内结构

### dsh-compat-apiproxy

```
packages/dsh-compat-apiproxy/
├── package.json   # name=@deepseek-ai/dsh-host-apiproxy, private, exports "." -> lib/index.js
└── lib/index.js   # export { RpcId }（恒等函数）
```

package.json 关键字段：

| 字段 | 值 | 作用 |
|------|-----|------|
| `name` | `@deepseek-ai/dsh-host-apiproxy` | 以官方名占位，既有 import 零改动解析 |
| `version` | `0.1.1-rc.2-shim.1` | 对齐官方最后版本号 + `-shim.N` 后缀标识垫片代次 |
| `description` 内嵌标记 | `dsh-selfheal:apiproxy-shim@1` | 自愈标记约定：供部署侧自愈/巡检脚本识别"这是受管垫片，不要覆盖" |
| `private` | `true` | 防误发布到 npm |

### dsh-compat-settings-scope

```
packages/dsh-compat-settings-scope/
├── package.json       # exports "." -> lib/index.js（宿主端）, "./client" -> lib/client.js（浏览器端）
├── cordis.patch.yml   # bundle patch：profile 顶层 insert compat-settings-scope 条目
└── lib/
    ├── index.js       # 宿主半包：settings.register 桥
    └── client.js      # 浏览器半包：settingsScope 别名（ModuleLoader 装载）
```

package.json 关键字段：

| 字段 | 值 | 作用 |
|------|-----|------|
| `dsh.engines.dsh` | `>=0.1.7-rc.2` | 声明兼容的 dsh 版本下限 |
| `dsh.bundle.patch` | `./cordis.patch.yml` | bundle patch 挂载点 |
| `dsh.client.platform` | `web` | 浏览器半包目标平台 |

cordis.patch.yml 内容（insert 的 `name` 必须等于包名，否则加载器无法解析）：

```yaml
- insert:
    - id: compat-settings-scope
      name: dsh-compat-settings-scope
```

## 3. 运行期行为契约

| 契约 | 约束 | 违反后果 |
|------|------|---------|
| 顶层 `inject` 必须为空 `[]` | 双端垫片都不得在顶层硬依赖任何异步挂载的服务 | entry 永久 pending → `entry did not activate` 致命错误 |
| 异步服务桥接走次级 fiber | 在 `apply` 内用内联 `ctx.inject([...], cb)` | 同上 |
| 垫片不得抛错 | 全程软获取 + try-catch | 拖垮 boot / 触发 StartupError |
| 幂等让位 | 官方恢复对应 API 时自动跳过 | 覆盖官方实现会造成隐性回归 |
| watcher 异常隔离 | 单个 watcher 抛错不得影响其它 watcher 与宿主 | 插件 bug 扩散为宿主故障 |

## 4. 环境变量

本套件不读取任何环境变量。运行 dsh 时的相关变量（供参考）：`DSH_HOME` 指向 dsh 数据根（profile 的上一级）。

## 5. 与"会话全文搜索"伴随能力的关系

自检中的 `node:sqlite` + FTS5 一项针对的是 dsh 的 `session-query-sqlite` 插件（与本套件同源调优的另一项成果）。它不属于本套件，但若你想启用会话全文搜索，在 profile 的 `cordis.patch.yml` 追加：

```yaml
- id: session-query-sqlite
  name: "@deepseek-ai/dsh-session-query-sqlite"
  config:
    path: !!js dshHomePath('session-index.sqlite')
    openAt: first-search   # 首次搜索时才建索引，启动保持安静；索引持久化，重启不重建
```

要求 Node >= 22.5（`node:sqlite` 免 flag；Node 22/26 实测可用）。
