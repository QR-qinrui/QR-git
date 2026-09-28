/**
 * dsh-compat-apiproxy · 部署本地兼容垫片（shim）。
 * dsh-selfheal:apiproxy-shim@1
 *
 * 背景：@limuyang2/dsh-agent-team@0.1.4 的 lib 在模块加载期执行
 *   import { RpcId } from "@deepseek-ai/dsh-host-apiproxy"
 * 但 dsh 0.1.7-rc.2 的依赖树已不再携带 apiproxy（该包停留在 0.1.1-era，
 * 且其完整安装会拉入 25+ 个旧版 @deepseek-ai 依赖，与 0.1.7 运行时冲突
 * 风险极高）。agent-team 实际只用到 RpcId 这一个导出（lib/index.js:2723
 * 处 rpcId: RpcId(randomUUID())）。
 *
 * 本垫片与官方实现语义完全一致（官方 lib/index.js:716 同样为恒等函数，
 * 仅在类型层做 brand，零运行时开销）：
 *
 *   function RpcId(id) { return id }
 *
 * 若未来 agent-team 升级并引入 apiproxy 的其它导出，加载时会以
 * "does not provide an export named 'X'" 明确报错——届时按报错补齐即可。
 */
function RpcId(id) {
  return id
}

export { RpcId }
