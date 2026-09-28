/**
 * dsh-compat-settings-scope · 宿主半包。
 *
 * 职责一（原有）：浏览器半包 lib/client.js 把已废弃的 `settingsScope`
 * 服务名注册为 `webUiSettings` 的别名，让仍用旧客户端 API
 * （inject: ['settingsScope']）的第三方插件（dsh-prompt-enhance、
 * dshmarket 等）在 dsh 0.1.7+ 客户端上正常激活。
 *
 * 职责二（dsh-selfheal:settings-register-shim@1）：
 * 宿主侧兼容 0.1.2-era 的 `settings.register(ns, schema, { base })` API。
 * dsh 0.1.7 的 SettingsForms 服务仅提供 configure/describe/update/
 * replace/mutate，旧插件 dsh-ego-browser@0.8.5 在激活期调用
 * `sctx.settings.register(...)` 会抛 "register is not a function"，
 * 导致其设置桥整体失效（工具可用但配置桥报错刷屏）。
 * 本 shim 在 SettingsForms 实例上补齐最小语义实现：
 *   scope.get()    返回当前值（初始为 { base } 传入的配置）
 *   scope.set(v)   覆盖写并通知 watcher
 *   scope.watch(cb) 订阅变更，返回退订函数
 * 语义与旧版只读场景一致；真正的持久化编辑仍走新版 SettingsForms。
 * 若官方日后恢复 register 方法，本 shim 自动跳过（幂等）。
 */

export const inject = []

export function apply(ctx) {
  ctx.inject?.(['settings'], (sctx) => {
    const svc = sctx.settings
    if (!svc || typeof svc.register === 'function') return
    try {
      svc.register = (ns, schema, opts) => {
        let value = (opts && typeof opts === 'object' && 'base' in opts) ? opts.base : {}
        const listeners = new Set()
        const notify = () => {
          for (const listener of [...listeners]) {
            try { listener() } catch { /* watcher 异常不污染宿主 */ }
          }
        }
        return {
          get: () => value,
          set: (v) => { value = v; notify() },
          update: (patch) => { value = { ...value, ...patch }; notify() },
          watch: (cb) => {
            listeners.add(cb)
            return () => listeners.delete(cb)
          },
        }
      }
      ctx.logger?.('compat-settings-scope')?.info?.('host settings.register shim installed (0.1.2-era API compat)')
    } catch (error) {
      ctx.logger?.('compat-settings-scope')?.warn?.('settings.register shim 安装失败：' + (error?.message || error))
    }
  })
}
