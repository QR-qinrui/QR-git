#!/usr/bin/env node
/**
 * dsh-compat-kit self-check
 *
 * Deterministic, zero-dependency verification for the compat kit.
 * Runs offline checks against the repo itself, plus optional deployment
 * checks against a live dsh profile (--profile-dir <path>).
 *
 * Output is ASCII-only so it renders correctly on Windows GBK consoles.
 * Exit code: 0 = all checks passed (warnings allowed), 1 = any failure.
 *
 * Usage:
 *   node scripts/self-check.mjs
 *   node scripts/self-check.mjs --profile-dir "D:/path/to/dsh-home/profiles/web"
 */
import { readFileSync, existsSync } from 'node:fs'
import { createHash } from 'node:crypto'
import { randomUUID } from 'node:crypto'
import { createRequire } from 'node:module'
import { pathToFileURL, fileURLToPath } from 'node:url'
import path from 'node:path'

const KIT_ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..')
const PKG_APIPROXY = path.join(KIT_ROOT, 'packages', 'dsh-compat-apiproxy')
const PKG_SETTINGS = path.join(KIT_ROOT, 'packages', 'dsh-compat-settings-scope')

const results = []
function check(name, fn) {
  try {
    const detail = fn()
    results.push({ status: 'PASS', name, detail: detail || '' })
  } catch (error) {
    if (error && error.warn) {
      results.push({ status: 'WARN', name, detail: error.message })
    } else {
      results.push({ status: 'FAIL', name, detail: String((error && error.message) || error) })
    }
  }
}
function warn(message) { const e = new Error(message); e.warn = true; return e }
function assert(cond, message) { if (!cond) throw new Error(message) }
function sha256(file) { return createHash('sha256').update(readFileSync(file)).digest('hex') }

function parseArgs(argv) {
  const args = { profileDir: null }
  const rest = argv.slice(2)
  for (let i = 0; i < rest.length; i++) {
    const a = rest[i]
    if (a.startsWith('--profile-dir=')) args.profileDir = a.slice('--profile-dir='.length)
    else if (a === '--profile-dir') {
      const next = rest[i + 1]
      if (!next || next.startsWith('--')) throw new Error('--profile-dir requires a path value')
      args.profileDir = next
      i++
    } else if (a === '--help' || a === '-h') {
      console.log('Usage: node scripts/self-check.mjs [--profile-dir <dsh profile dir>]')
      process.exit(0)
    } else throw new Error(`unknown argument: ${a}`)
  }
  return args
}

// --- 1. runtime ----------------------------------------------------------
check('runtime: node version >= 22', () => {
  const major = Number(process.versions.node.split('.')[0])
  assert(major >= 22, `node ${process.versions.node} is too old (dsh 0.1.x requires >= 22)`)
  return `v${process.versions.node}`
})

// --- 2. repo integrity ---------------------------------------------------
const REQUIRED_FILES = [
  'package.json', 'README.md', 'LICENSE',
  'packages/dsh-compat-apiproxy/package.json',
  'packages/dsh-compat-apiproxy/lib/index.js',
  'packages/dsh-compat-settings-scope/package.json',
  'packages/dsh-compat-settings-scope/cordis.patch.yml',
  'packages/dsh-compat-settings-scope/lib/index.js',
  'packages/dsh-compat-settings-scope/lib/client.js',
]
check('repo: required files present', () => {
  const missing = REQUIRED_FILES.filter((f) => !existsSync(path.join(KIT_ROOT, f)))
  assert(missing.length === 0, `missing: ${missing.join(', ')}`)
  return `${REQUIRED_FILES.length} files`
})

// --- 3. manifest consistency --------------------------------------------
function loadPkg(dir) {
  const pkg = JSON.parse(readFileSync(path.join(dir, 'package.json'), 'utf8'))
  for (const [key, target] of Object.entries(pkg.exports || {})) {
    if (key === './package.json') continue
    assert(existsSync(path.join(dir, target)), `${pkg.name}: exports["${key}"] -> ${target} not found`)
  }
  return pkg
}
let apiproxyPkg, settingsPkg
check('manifest: package.json exports resolve', () => {
  apiproxyPkg = loadPkg(PKG_APIPROXY)
  settingsPkg = loadPkg(PKG_SETTINGS)
  assert(apiproxyPkg.name === '@deepseek-ai/dsh-host-apiproxy', `unexpected apiproxy name: ${apiproxyPkg.name}`)
  assert(settingsPkg.name === 'dsh-compat-settings-scope', `unexpected settings name: ${settingsPkg.name}`)
  assert(settingsPkg.dsh?.bundle?.patch === './cordis.patch.yml', 'settings dsh.bundle.patch mismatch')
  return `${apiproxyPkg.name}@${apiproxyPkg.version}, ${settingsPkg.name}@${settingsPkg.version}`
})

// --- 4/5. apiproxy import test and settings host E2E run in the async
// runner section below (ESM import is async).

// --- 5. settings-scope host shim: mock-context E2E -----------------------
function makeHostHarness(svc) {
  const fibers = []
  const ctx = { inject: (names, cb) => fibers.push({ names, cb }) }
  return {
    ctx,
    activate() { for (const f of fibers) f.cb({ settings: svc }) },
  }
}
async function testSettingsHost() {
  const mod = await import(pathToFileURL(path.join(PKG_SETTINGS, 'lib', 'index.js')).href)
  assert(Array.isArray(mod.inject) && mod.inject.length === 0, 'top-level inject must be [] (async-safety contract)')
  assert(typeof mod.apply === 'function', 'apply export missing')

  // case A: service without register -> shim installs it
  const svc = {}
  const h = makeHostHarness(svc)
  mod.apply(h.ctx)
  h.activate()
  assert(typeof svc.register === 'function', 'register was not installed')

  const scope = svc.register('test.ns', {}, { base: { headless: false } })
  assert(scope.get().headless === false, 'get() did not return base')

  let fired = 0
  const unwatch = scope.watch(() => { fired += 1 })
  scope.set({ headless: true })
  assert(scope.get().headless === true && fired === 1, `set/notify broken (fired=${fired})`)
  scope.update({ extra: 1 })
  assert(scope.get().extra === 1 && scope.get().headless === true && fired === 2, 'update merge broken')
  unwatch()
  scope.set({ headless: false })
  assert(fired === 2, 'unsubscribe broken')

  // watcher throwing must not break other watchers
  const scope2 = svc.register('test.ns2', {}, {})
  let ok = 0
  scope2.watch(() => { throw new Error('boom') })
  scope2.watch(() => { ok += 1 })
  scope2.set({ x: 1 })
  assert(ok === 1, 'watcher isolation broken')

  // default value when no opts
  const scope3 = svc.register('test.ns3', {})
  assert(scope3.get() && typeof scope3.get() === 'object', 'default base should be {}')

  // case B: idempotent skip when official register exists
  const official = () => 'official'
  const svc2 = { register: official }
  const h2 = makeHostHarness(svc2)
  mod.apply(h2.ctx)
  h2.activate()
  assert(svc2.register === official, 'shim must not override an existing register')

  return 'register install / get / set / update / watch / unsub / isolation / idempotent-skip'
}

// --- 6. client half: static contract -------------------------------------
check('client: ModuleLoader contract', () => {
  const src = readFileSync(path.join(PKG_SETTINGS, 'lib', 'client.js'), 'utf8')
  assert(src.includes("id: 'dsh-compat-settings-scope'"), 'ModuleLoader id must equal package name')
  assert(/const inject = \[\]/.test(src), 'top-level inject must be [] (entry must not hard-depend on async services)')
  assert(src.includes("ctx.inject(['webUiSettings']"), 'secondary fiber bridging to webUiSettings missing')
  assert(src.includes("provide('settingsScope'"), 'settingsScope alias provide missing')
  return 'id / inject=[] / secondary-fiber / alias'
})

// --- 7. bundle patch consistency -----------------------------------------
check('bundle: cordis.patch.yml insert matches package', () => {
  const yml = readFileSync(path.join(PKG_SETTINGS, 'cordis.patch.yml'), 'utf8')
  assert(yml.includes('insert:'), 'insert block missing')
  assert(yml.includes('id: compat-settings-scope'), 'entry id mismatch')
  assert(yml.includes('name: dsh-compat-settings-scope'), 'entry name must equal package name')
  return 'compat-settings-scope -> dsh-compat-settings-scope'
})

// --- 8. environment capability: node:sqlite + FTS5 ------------------------
check('env: node:sqlite + FTS5 available', () => {
  try {
    const { DatabaseSync } = createRequire(import.meta.url)('node:sqlite')
    const db = new DatabaseSync(':memory:')
    db.exec("CREATE VIRTUAL TABLE t USING fts5(x); INSERT INTO t(x) VALUES('hello world');")
    const rows = db.prepare("SELECT rowid FROM t WHERE t MATCH 'hello'").all()
    db.close()
    assert(rows.length === 1, 'FTS5 match returned no rows')
    return 'node:sqlite FTS5 OK (session-search capable)'
  } catch (e) {
    throw warn(`node:sqlite/FTS5 unavailable: ${e.message} (kit works, session-search companion feature needs Node 22.5+)`)
  }
})

// --- 9. optional: verify deployment into a live dsh profile ---------------
async function testProfileDeployment(profileDir) {
  const pkgPath = path.join(profileDir, 'package.json')
  assert(existsSync(pkgPath), `profile package.json not found: ${pkgPath}`)
  const raw = readFileSync(pkgPath, 'utf8').replace(/^\uFEFF/, '')
  const pkg = JSON.parse(raw)

  const deps = pkg.dependencies || {}
  assert(deps['dsh-compat-settings-scope'], 'dependencies missing dsh-compat-settings-scope')
  assert(deps['@deepseek-ai/dsh-host-apiproxy'], 'dependencies missing @deepseek-ai/dsh-host-apiproxy')

  const bundles = pkg.dsh?.profile?.bundles || []
  assert(bundles.includes('dsh-compat-settings-scope'), 'dsh.profile.bundles missing dsh-compat-settings-scope')

  const installedSettings = path.join(profileDir, 'node_modules', 'dsh-compat-settings-scope', 'lib', 'index.js')
  const installedApiproxy = path.join(profileDir, 'node_modules', '@deepseek-ai', 'dsh-host-apiproxy', 'lib', 'index.js')
  assert(existsSync(installedSettings), 'node_modules/dsh-compat-settings-scope not installed (run pnpm install)')
  assert(existsSync(installedApiproxy), 'node_modules/@deepseek-ai/dsh-host-apiproxy not installed (run pnpm install)')

  assert(sha256(installedSettings) === sha256(path.join(PKG_SETTINGS, 'lib', 'index.js')),
    'installed settings-scope lib/index.js differs from kit source (re-run install + pnpm install)')
  assert(sha256(installedApiproxy) === sha256(path.join(PKG_APIPROXY, 'lib', 'index.js')),
    'installed apiproxy lib/index.js differs from kit source (re-run install + pnpm install)')

  // import from the installed location (catches Chinese-path / space resolution issues)
  const mod = await import(pathToFileURL(installedApiproxy).href)
  const id = randomUUID()
  assert(mod.RpcId(id) === id, 'installed RpcId identity broken')

  return 'deps + bundles + installed content + import all verified'
}

// --- runner ----------------------------------------------------------------
const args = parseArgs(process.argv)

// async checks
await (async () => {
  try {
    const mod = await import(pathToFileURL(path.join(PKG_APIPROXY, 'lib', 'index.js')).href)
    const id = randomUUID()
    assert(mod.RpcId(id) === id, 'RpcId is not identity')
    assert(Object.keys(mod).length === 1, `unexpected extra exports: ${Object.keys(mod).join(',')}`)
    results.push({ status: 'PASS', name: 'apiproxy: RpcId import + identity', detail: `uuid round-trip OK, exports=[${Object.keys(mod)}]` })
  } catch (e) {
    results.push({ status: 'FAIL', name: 'apiproxy: RpcId import + identity', detail: String(e.message || e) })
  }

  try {
    const detail = await testSettingsHost()
    results.push({ status: 'PASS', name: 'settings-host: register shim E2E', detail })
  } catch (e) {
    results.push({ status: 'FAIL', name: 'settings-host: register shim E2E', detail: String(e.message || e) })
  }

  if (args.profileDir) {
    try {
      const detail = await testProfileDeployment(args.profileDir)
      results.push({ status: 'PASS', name: 'profile: deployment verified', detail })
    } catch (e) {
      results.push({ status: 'FAIL', name: 'profile: deployment verified', detail: String(e.message || e) })
    }
  }
})()

// --- report ----------------------------------------------------------------
const version = JSON.parse(readFileSync(path.join(KIT_ROOT, 'package.json'), 'utf8')).version
console.log(`dsh-compat-kit self-check v${version}`)
console.log(`kit root: ${KIT_ROOT}`)
console.log('-'.repeat(64))
for (const r of results) {
  console.log(`[${r.status}] ${r.name}${r.detail ? ` -- ${r.detail}` : ''}`)
}
const passed = results.filter((r) => r.status === 'PASS').length
const warned = results.filter((r) => r.status === 'WARN').length
const failed = results.filter((r) => r.status === 'FAIL').length
console.log('-'.repeat(64))
console.log(`RESULT: ${passed} passed, ${warned} warned, ${failed} failed`)
process.exit(failed > 0 ? 1 : 0)
