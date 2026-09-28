# 兼容工程模式总结

从一次真实的 dsh 0.1.x → 0.1.7 生产环境调优（23+ 社区插件）中提炼的可复用模式。本套件是模式 1–3 的直接产物；模式 4–7 是配套运维纪律。

## 模式 1：零依赖恒等垫片（Identity Shim）

**场景**：插件 `import` 了一个宿主已移除的包。

**做法**：
1. 先用 grep 确认插件**实际用到哪些导出**（通常只有一两个）；
2. 找到官方实现核对语义（本例中官方 `RpcId` 就是恒等函数，仅类型层 brand）；
3. 写一个零依赖、与官方语义一致的垫片包，**以原包名**发布（`private: true`），既有 import 零改动解析。

**纪律**：
- 只补实际用到的导出。缺失的导出让 ESM 加载期 `does not provide an export named 'X'` 明确报错（fail-fast），不做"全家桶式"伪造——静默返回 undefined 会把故障推迟到运行期深处。
- 拒绝"装真包"的诱惑：真包往往拖入大量同时代旧依赖，与现宿主冲突风险远高于一个恒等函数。

**实例**：`dsh-compat-apiproxy`（25+ 个 0.1.1 时代依赖 ↔ 3 行恒等函数）。

## 模式 2：宿主 API 桥接（Host API Bridge）

**场景**：宿主升级删除了插件仍在调用的服务方法。

**做法**：写一个 compat 插件，在运行期为服务实例补齐**最小语义实现**：
- 只实现插件实际使用的子集（get/set/update/watch）；
- **幂等**：官方恢复该方法时自动跳过（`if (typeof svc.register === 'function') return`）；
- **异常隔离**：插件侧 watcher 抛错不得污染宿主与其它 watcher；
- 新功能（持久化编辑等）仍走新 API，垫片只保兼容语义。

**实例**：`dsh-compat-settings-scope` 宿主半包的 `settings.register` 桥。

## 模式 3：别名服务 + 次级 fiber（Service Alias via Secondary Fiber）

**场景**：宿主改了服务名，旧插件 `inject` 旧名导致永久 pending，升级为 boot 致命错误（`entry did not activate`）。

**做法**：在 profile 顶层把旧名注册为新服务的别名。关键纪律：

- **绝不在顶层 `inject` 硬依赖异步挂载的服务**——异步服务（如 `webUiSettings` 由 dsh-web-all 动态挂载）可能延迟提供，硬依赖会让垫片自己也 pending，从"治病"变"致病"；
- 正确姿势：顶层 `inject = []`，在 `apply` 内用**内联 `ctx.inject` 创建次级 fiber** 做桥接（次级 fiber 的 pending 不阻塞 entry 激活、不纳入未激活计数）；
- 全程软获取 + try-catch，垫片任何失败都不得拖垮 boot。

**实例**：`dsh-compat-settings-scope` 浏览器半包。

## 模式 4：精确版本豁免（Surgical Version Waiver）

**场景**：插件声明的 peer 版本与宿主不完全匹配，被启动器跳过。

**做法**：用 `dsh plugin allow-version <pkg@确切版本> --dsh-version <确切版本> --accept-risk` 豁免**单点**，而非全局关闭版本检查。豁免范围越窄，未来升级时暴露真冲突的信号越清晰。

## 模式 5：自愈标记约定（Self-heal Marker）

**场景**：部署环境有插件自愈/巡检机制，可能把垫片当"异常包"覆盖或清除。

**做法**：垫片包 `description` 内嵌机器可读标记 `dsh-selfheal:<名称>@<代次>`，自愈脚本识别后跳过受管垫片。标记即契约，代次号随垫片语义变更递增。

## 模式 6：依赖声明防清除（Dependencies as Source of Truth）

**场景**：插件管理器/市场重新生成 lockfile 时，清掉了"只在 bundles 里引用、dependencies 里没有"的包，导致启动时 `skipping profile bundle ... cannot resolve`。

**做法**：所有必须存活的包一律写进 `dependencies`（本套件安装器即如此）；bundles 只做激活编排，不做安装来源。修复时用 `pnpm add <pkg>@<version>` 而不是手动改文件，保证 lockfile 同步。

## 模式 7：证据门禁（Evidence Gate）

**场景**：调优/修复后"看起来没问题"。

**做法**：三层证据，缺一不可：
1. **离线契约**：插件清单、语法、导出形状静态验证通过；
2. **在线冒烟**：服务起来后路由级验证通过；
3. **功能实证**：触发一次真实调用并看到正向产物（索引文件生成、子进程存活等），而不只是"没报错"。

原则：**无证据 = 未完成**。本套件的 `self-check.mjs` 即该原则的工程化：确定性校验、退出码 0/1、可接 CI。

---

### 反模式清单（同样来自实战）

| 反模式 | 后果 | 正解 |
|--------|------|------|
| 从 IDE/AI 工具内部托管长驻 node 服务 | 沙箱注入的 `NODE_OPTIONS` shim 干扰子进程（批量删除守卫误判 dsh 锁文件清理），后台进程被无声回收 | 服务只走用户自己的启动器链路 |
| pnpm install 时 dsh 仍在运行 | Windows 上 EPERM rename 失败，留下 `*_tmp_*` 残骸 | 先停服；残骸归档而非删除 |
| 看日志"没报错"就宣布完成 | 功能可能从未真正执行 | 模式 7 三层证据 |
| 升级宿主主框架追新 | 23 个插件的生态连锁崩溃风险 | 刻意钉住版本，用垫片消化差异 |
