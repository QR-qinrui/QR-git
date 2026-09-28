// dsh 插件层冒烟测试：不依赖 dsh 宿主，直接验证 runner 纯逻辑层。
// 运行：AFO_PYTHON=<python路径> node test/smoke.mjs
import { mkdtempSync, writeFileSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import path from 'node:path'
import { buildCliArgs, runAfo, summarize } from '../src/runner.mjs'

let passed = 0
let failed = 0
function check(name, cond, detail = '') {
  if (cond) { passed++; console.log(`✅ ${name}`) }
  else { failed++; console.log(`❌ ${name} ${detail}`) }
}

// 1) 参数校验与 CLI 组装
check('非法 action 被拦截', (() => {
  try { buildCliArgs({ action: 'hack' }); return false } catch { return true }
})())
check('migrate 缺 to 被拦截', (() => {
  try { buildCliArgs({ action: 'migrate', directory: '/tmp/x' }); return false } catch { return true }
})())
const previewArgs = buildCliArgs({ action: 'migrate', directory: '/tmp/x', to: '/tmp/y' })
check('migrate 默认不带 --yes（确认门）', !previewArgs.includes('--yes'))
const confirmArgs = buildCliArgs({ action: 'migrate', directory: '/tmp/x', to: '/tmp/y', confirm: true, mode: 'link' })
check('confirm=true 才带 --yes 且透传 mode',
  confirmArgs.includes('--yes') && confirmArgs.includes('link'))

// 2) 真实调起 Python 核心：scan
const sandbox = mkdtempSync(path.join(tmpdir(), 'afo_dsh_smoke_'))
writeFileSync(path.join(sandbox, 'm.gguf'), Buffer.alloc(128))
writeFileSync(path.join(sandbox, 'd.csv'), 'a,b\n1,2\n')
try {
  const scan = await runAfo({ action: 'scan', directory: sandbox })
  check('scan 退出码 0', scan.code === 0, scan.stderr)
  check('scan JSON 解析成功', scan.json?.total_files === 2,
    JSON.stringify(scan.json ?? scan.stdout).slice(0, 120))
  const text = summarize('scan', scan)
  check('scan 摘要包含类别信息', text.includes('models'), text)

  // 3) 全链路：migrate(link) → verify → rollback
  const dst = path.join(sandbox, 'out')
  const mig = await runAfo({ action: 'migrate', directory: sandbox, to: dst, mode: 'link', confirm: true })
  check('migrate(link) 成功 2 项', mig.json?.done === 2, mig.stderr.slice(0, 200))

  const ver = await runAfo({ action: 'verify', manifest: mig.json.manifest_json })
  check('verify 2 项正常', ver.json?.ok === 2, JSON.stringify(ver.json ?? '').slice(0, 200))

  const rb = await runAfo({ action: 'rollback', manifest: mig.json.manifest_json, confirm: true })
  check('rollback 还原 2 项', rb.json?.restored === 2, JSON.stringify(rb.json ?? '').slice(0, 200))

  // 4) selfcheck
  const sc = await runAfo({ action: 'selfcheck' }, { timeoutMs: 120000 })
  check('selfcheck 全部通过', sc.json?.ok === true, summarize('selfcheck', sc))
} finally {
  rmSync(sandbox, { recursive: true, force: true })
}

console.log(`\n结果：${passed} 通过，${failed} 失败`)
process.exit(failed === 0 ? 0 : 1)
