/**
 * dsh-compat-settings-scope · 浏览器半包（兼容垫片）。
 *
 * 背景：dsh 0.1.7 客户端把 settings 服务从旧的 `ctx.settingsScope` 迁移到
 * `webUiSettings`（由 dsh-web-settings 的 WebUiSettingsBinder 提供）。binder
 * 上保留了 `get settingsScope(){return this}` 的编译期别名，但并没有在 cordis
 * service registry 里注册 `settingsScope` 这个名字。于是任何仍用旧 API
 * （inject: ['settingsScope']）的第三方插件（dsh-prompt-enhance、dshmarket 等）
 * 都会在 service resolver 里永远等不到服务 → 永久 pending → 触发 web boot
 * 的 "entry did not activate" 致命错误。
 *
 * 本垫片在 profile 顶层把 `settingsScope` 注册为 `webUiSettings` 的别名服务，
 * 一劳永逸地让所有旧插件正常激活，无需逐个改插件源码。新装的旧插件也自动兼容。
 *
 * 关键设计（一劳永逸防 pending）：
 * - `webUiSettings` 是由 dsh-web-all 通过 mountClientChildren 异步动态挂载的
 *   服务，可能延迟提供。因此**绝不能**在顶层 `inject` 里硬依赖它（硬依赖会让
 *   本 entry 在服务就绪前永久 pending，触发 "entry did not activate"）。
 * - 正确做法（与官方所有 family 插件一致）：顶层 inject 只依赖稳定同步的
 *   服务，对 `webUiSettings` 用**内联的 ctx.inject 次级 fiber**（次级 fiber
 *   的 pending 不阻塞 entry 激活，且不纳入未激活计数）+ 软获取兜底。
 *
 * 约定（与 dsh-open-in-tui 一致）：
 * - 用 `window.__ModuleLoader__.load({ id, factory })` 装载，id 必须等于包名；
 * - factory 无副作用，只把 `apply` / `inject` 挂到 module.exports。
 */
window.__ModuleLoader__.load({
  id: 'dsh-compat-settings-scope',
  factory: () => {
    const module = { exports: {} }
    const exports = module.exports

    /**
     * 顶层只依赖稳定的基础服务，避免把本 entry 绑死在一个可能延迟/缺失的
     * 异步服务（webUiSettings）上。webUiSettings 的桥接放到 apply 内的次级
     * fiber 里，这样即使 webUiSettings 没就绪，本 entry 也保持已激活。
     */
    const inject = []

    /**
     * 注册别名服务。webUiSettings 就绪后（内联 inject 的次级 fiber 触发），
     * 把它别名到 settingsScope。全程软获取 + try-catch，绝不抛错拖垮 boot。
     */
    function apply(ctx) {
      try {
        ctx.inject(['webUiSettings'], (settingsCtx) => {
          try {
            const binder = settingsCtx.get('webUiSettings')
            if (binder === undefined) return
            // binder 自带 get settingsScope(){return this}，这里直接别名到同一实例。
            settingsCtx.provide('settingsScope', binder)
          } catch {
            // 垫片失败不应影响主流程；旧插件仍会 pending，但不至于拖垮 boot。
          }
        })
      } catch {
        // ctx.inject 本身失败（理论上不会）也不抛。
      }
    }

    exports.apply = apply
    exports.inject = inject
    return module.exports
  },
})
