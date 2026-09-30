// DSH 宿主升级 —— 兼容性缺口分析器
//
// 作用：给定「目标宿主版本 + profile 目录 + 暂存运行时目录」，把 profile 里每个 bundle 的
// peer 兼容性判一遍，并对不兼容者自动给出处置建议（可升级到哪个版本 / 本地放宽 peer / 只能豁免）。
// 判定逻辑与 DSH 宿主门禁保持一致：只看 peerDependencies 里的 @deepseek-ai/dsh*，
// 用 semver.satisfies(..., { includePrerelease: true }) 比对；不看 optional，也不看 dsh.engines。
//
// 用法：
//   node analyze-compat.mjs <stageDir> <profileDir> <targetVersion>
// 输出：一行 JSON（{ targetVersion, results: [...] }），便于 PowerShell 侧消费。

import { readFileSync, existsSync } from 'node:fs'
import { join } from 'node:path'
import { createRequire } from 'node:module'

const [stageDir, profileDir, targetVersion] = process.argv.slice(2)
if (!stageDir || !profileDir || !targetVersion) {
    console.error('usage: node analyze-compat.mjs <stageDir> <profileDir> <targetVersion>')
    process.exit(2)
}

// 用暂存运行时自带的 semver，保证与宿主门禁的判定版本一致
const require = createRequire(join(stageDir, 'package.json'))
let semver
try { semver = require('semver') } catch {
    // 旧运行时是嵌套布局（semver 在 @deepseek-ai/dsh/node_modules 下），需要再兜一层
    try { semver = createRequire(join(stageDir, 'node_modules', '@deepseek-ai', 'dsh', 'package.json'))('semver') }
    catch (e) { console.error('无法加载 semver: ' + e.message); process.exit(3) }
}

const DSH_PEER = /^@deepseek-ai\/dsh(?:-|$)/

function readJson(path) {
    try { return JSON.parse(readFileSync(path, 'utf8')) } catch { return null }
}

function readManifest(root, name) {
    const p = join(root, 'node_modules', name, 'package.json')
    return existsSync(p) ? readJson(p) : null
}

/** 返回不满足目标版本的 @deepseek-ai/dsh* peer 集合 */
function incompatiblePeers(manifest, version) {
    const peers = manifest && manifest.peerDependencies
    if (!peers) return {}
    const bad = {}
    for (const [name, range] of Object.entries(peers)) {
        if (name !== '@deepseek-ai/dsh' && !DSH_PEER.test(name)) continue
        let requirement = range
        if (['workspace:^', 'workspace:~', 'workspace:*'].includes(range)) requirement = version
        let ok = false
        try { ok = semver.satisfies(version, requirement, { includePrerelease: true }) } catch { ok = false }
        if (!ok) bad[name] = range
    }
    return bad
}

async function registryLatest(name) {
    const key = name.replace('/', '%2F')
    const res = await fetch(`https://registry.npmjs.org/-/package/${key}/dist-tags`, { redirect: 'follow' })
    if (!res.ok) return { error: `HTTP ${res.status}`, httpStatus: res.status }
    const meta = await res.json()
    return { latest: meta && meta.latest }
}

async function registryManifest(name, version) {
    const key = name.replace('/', '%2F')
    const res = await fetch(`https://registry.npmjs.org/${key}/${version}`, { redirect: 'follow' })
    if (!res.ok) return { error: `manifest HTTP ${res.status}` }
    return await res.json()
}

/** 市场门：插件 manifest 的 dsh.engines.dsh 声明（市场在安装/对齐前读它） */
function enginesGate(manifest, version) {
    const req = manifest && manifest.dsh && manifest.dsh.engines && manifest.dsh.engines.dsh
    if (typeof req !== 'string' || req.trim() === '') return { required: null, ok: null }
    let ok = false
    try { ok = semver.satisfies(version, req, { includePrerelease: true }) } catch { ok = false }
    return { required: req, ok }
}

const profile = readJson(join(profileDir, 'package.json'))
if (!profile) { console.error('读不到 profile package.json: ' + profileDir); process.exit(4) }
const bundles = (profile.dsh && profile.dsh.profile && profile.dsh.profile.bundles) || []
const deps = profile.dependencies || {}
// 宿主门会读 profile 的 compatibility.json：命中的精确豁免会被**放行**（不再跳过），
// 所以分析器必须同样读取，否则判定会与真实启动不一致（实测踩过）。
const compat = readJson(join(profileDir, 'compatibility.json')) || {}

const results = []
for (const name of bundles) {
    // 解析顺序必须与宿主启动一致：**内置运行时（in-box）优先，其次 profile**
    // —— 否则像 @deepseek-ai/dsh-web-app 这种同时存在于两处的官方包会被误判（实测踩过）。
    const fromRuntime = readManifest(stageDir, name)
    const fromProfile = readManifest(profileDir, name)
    const manifest = fromRuntime || fromProfile
    const source = fromRuntime ? 'runtime' : (fromProfile ? 'profile' : null)
    if (!manifest) { results.push({ name, status: 'not-installed' }); continue }

    const bad = incompatiblePeers(manifest, targetVersion)
    const eng = enginesGate(manifest, targetVersion)
    const compatKey = name + '@' + manifest.version
    const exempted = Array.isArray(compat[compatKey]) && compat[compatKey].includes(targetVersion)
    if (Object.keys(bad).length === 0) {
        // 宿主门通过；仍需报告市场门（engines）状态，供"升完会不会被市场降级"判断
        if (eng.ok === false) { results.push({ name, status: 'engines-blocked', installed: manifest.version, source, engines: eng }); continue }
        results.push({ name, status: 'compatible', installed: manifest.version, source, engines: eng }); continue
    }

    const spec = String(deps[name] || '')
    const entry = {
        name,
        status: exempted ? 'exempted' : 'incompatible',
        installed: manifest.version,
        source,
        spec,
        exempted,
        local: /^(?:link|file):/.test(spec),
        incompatiblePeers: bad,
        engines: eng,
        advice: null,
        candidate: null,
    }

    if (entry.local) {
        entry.advice = 'local-peer-patch'
        entry.hint = '本地 link/file 包：把上面这些 peer 范围的上界放宽即可原生通过（无需豁免）'
    } else {
        try {
            const { latest, error, httpStatus } = await registryLatest(name)
            if (httpStatus === 404 || httpStatus === 401) { entry.advice = 'needs-exemption'; entry.hint = 'npm 上无此包或为私有包（github/私有依赖）：升无可升，只能豁免或等上游适配' }
            else if (error) { entry.advice = 'needs-exemption'; entry.hint = 'registry 不可达（' + error + '）：先按豁免处理，联网后重跑分析' }
            else if (!latest) { entry.advice = 'needs-exemption'; entry.hint = 'registry 无 dist-tags.latest' }
            else if (latest === manifest.version) { entry.advice = 'needs-exemption'; entry.hint = '上游 latest 就是当前版本（' + latest + '），升无可升' }
            else {
                const m2 = await registryManifest(name, latest)
                if (m2.error) { entry.advice = 'needs-exemption'; entry.hint = '取 ' + latest + ' 的 manifest 失败：' + m2.error }
                else {
                    const bad2 = incompatiblePeers(m2, targetVersion)
                    const eng2 = enginesGate(m2, targetVersion)
                    entry.candidate = { version: latest, compatible: Object.keys(bad2).length === 0, incompatiblePeers: bad2, engines: eng2 }
                    if (entry.candidate.compatible) { entry.advice = 'upgrade'; entry.hint = '升级到 ' + latest + ' 即原生兼容' }
                    else { entry.advice = 'needs-exemption'; entry.hint = '上游最新 ' + latest + ' 仍不兼容目标版本，只能豁免或等上游' }
                }
            }
        } catch (e) {
            entry.advice = 'needs-exemption'
            entry.hint = '联网检查失败：' + String(e && e.message ? e.message : e)
        }
    }
    results.push(entry)
}

console.log(JSON.stringify({ targetVersion, bundleCount: bundles.length, results }, null, 2))
