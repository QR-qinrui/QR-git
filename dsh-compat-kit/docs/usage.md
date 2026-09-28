# 使用说明

## 1. 安装（可复现步骤）

前置条件：Node.js >= 22、pnpm、dsh >= 0.1.7-rc.2，且 **dsh 实例已停止**（活进程会在 Windows 上锁定 `node_modules`，导致 pnpm EPERM rename 失败）。

```bash
# 步骤 1：克隆/解压本套件后，先做离线自检
node scripts/self-check.mjs
# 期望输出末尾：RESULT: 8 passed, 0 warned, 0 failed（exit 0）

# 步骤 2：接入 dsh profile
node scripts/install.mjs --profile-dir "<你的 dsh-home>/profiles/web"
# 安装器会：备份 package.json → 写入两个 file: 依赖 → 注册 bundle → pnpm install

# 步骤 3：部署校验（对真实 profile 做内容级核对）
node scripts/self-check.mjs --profile-dir "<你的 dsh-home>/profiles/web"
# 期望：新增 [PASS] profile: deployment verified

# 步骤 4：启动 dsh，观察启动日志
```

启动日志验收标准（四项全无）：

- 无 `failed to import ... dsh-host-apiproxy`
- 无 `settings.register is not a function`
- 无 `skipping profile bundle ... cannot resolve`
- 无 `entry did not activate`

## 2. 安装器参数

| 参数 | 说明 |
|------|------|
| `--profile-dir <path>` | 必填。dsh profile 目录（含 package.json 的那层，通常是 `<dsh-home>/profiles/web`）；也支持 `--profile-dir=<path>` 写法 |
| `--skip-pnpm` | 只改 package.json，不执行 pnpm install（无 pnpm 环境或想手动控制时使用） |
| `--help` | 打印用法 |

安装器是**幂等**的：重复执行不会重复写入，已是最新时报告 `already up to date`。每次实际修改前都会在 profile 目录生成 `package.json.bak-<时间戳>` 备份。

## 3. 自检脚本参数

| 参数 | 说明 |
|------|------|
| （无参） | 离线校验套件本身：运行时、文件完整性、清单一致性、垫片功能 E2E、环境能力 |
| `--profile-dir <path>` | 追加部署校验：依赖声明、bundles 注册、安装内容与套件源哈希一致、安装位导入（也支持 `=` 写法） |

退出码：`0` = 全部通过（允许 WARN），`1` = 存在 FAIL。可直接接入 CI 或启动器前置检查。

WARN 与 FAIL 的区别：`node:sqlite`/FTS5 不可用只影响"会话全文搜索"这一伴随能力，不影响垫片本身功能，故记 WARN 不记 FAIL。

## 4. 卸载 / 回滚

```bash
# 方式一：用安装器备份恢复（推荐）
cp "<profile>/package.json.bak-<时间戳>" "<profile>/package.json"
cd "<profile>" && pnpm install

# 方式二：手动移除
# 1) 从 package.json dependencies 删除 dsh-compat-settings-scope 与 @deepseek-ai/dsh-host-apiproxy
# 2) 从 dsh.profile.bundles 删除 dsh-compat-settings-scope
# 3) pnpm install
```

## 5. 故障排查

| 现象 | 原因 | 处理 |
|------|------|------|
| pnpm install 报 `EPERM: operation not permitted, rename` | 有活的 dsh/node 进程锁定 node_modules | 停止全部 dsh 实例与残留 node 进程后重跑 |
| 启动日志仍有 `skipping profile bundle` | 依赖被插件管理器/市场清空（pnpm-lock 再生成丢包） | 重跑 `install.mjs`；确保包写在 `dependencies` 里（本安装器正是这么做的），只在 bundles 里引用会被清 |
| 启动日志 `does not provide an export named 'X'` | 下游插件升级，开始引用垫片未提供的新导出 | 按报错名在对应垫片 `lib/index.js` 补齐该导出（先核对官方实现语义） |
| 自检报 `installed ... differs from kit source` | 套件源码改过但安装位未同步（file: 依赖是拷贝/硬链接） | 重跑 `install.mjs` 或在 profile 里 `pnpm install` |
| Windows 控制台自检输出乱码 | 不会乱码——脚本输出为纯 ASCII；若见乱码说明终端本身编码异常 | `chcp 65001` 或换 UTF-8 终端 |
| 垫片安装后官方升级恢复了对应 API | 无需操作 | 垫片幂等跳过，自动让位官方实现 |

## 6. 配套建议（与本套件同源的验证门禁）

若你的启动器带验证模式，安装后建议按顺序跑：

1. 离线契约验证（如 `-VerifyPlugins`）——确认插件清单契约完整
2. 在线冒烟（如 `-VerifyLive`）——确认 web 路由可用
3. 功能实证——触发一次真实调用（如搜索）确认对应产物生成（如索引文件）

原则：**无证据 = 未完成**。只看"没报错"不算验证通过，要看到正向产物。
