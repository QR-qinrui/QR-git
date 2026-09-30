// 运行时本地补丁「适配性检查器」
//
// 背景：本机对 runtime 里的 client UI 包打过私有补丁（patch-runtime-tree.mjs 直接改写
// @deepseek-ai/dsh-client-ui-*/lib/*.js：挽具框架 CSS、暗色默认、服务状态点、skip-link、移动端适配…）。
// 宿主升级会换掉这些文件，因此升级前必须知道：这些补丁还能不能原样命中新的 bundle。
//
// 做法：把补丁脚本按小节拆开，在「目标运行时文件的镜像目录」上分别执行（writeFileSync 只写到镜像），
// 统计每条锚点的命中数；命中 0 或 >1 即为需要人工移植的锚点。
//
// 用法：
//   node check-runtime-patches.mjs <patchScript> <runtimeDir> <workdir>
//     patchScript : patch-runtime-tree.mjs 的路径
//     runtimeDir  : 被检查的运行时目录（支持嵌套布局与提升布局）
//     workdir     : 作为 cwd 运行补丁脚本（补丁脚本用相对路径读 deepseek-harness/packages/... 的 CSS）
// 输出：一行 JSON 报告。

import { readFileSync, writeFileSync, mkdirSync, existsSync, rmSync } from 'node:fs'
import { join, dirname, resolve } from 'node:path'
import { spawnSync } from 'node:child_process'
import { tmpdir } from 'node:os'

const [patchScript, runtimeDir, workdir] = process.argv.slice(2)
if (!patchScript || !runtimeDir || !workdir) {
    console.error('usage: node check-runtime-patches.mjs <patchScript> <runtimeDir> <workdir>')
    process.exit(2)
}

let src = readFileSync(patchScript, 'utf8').replace(/\r\n/g, '\n')

// 1) 从补丁脚本里解析它读写的文件清单：P('theme', 'client.js') 形式
const targets = new Set()
// P('theme','client.js') 实际是 @deepseek-ai/dsh-client-ui-theme/lib/client.js（补丁脚本会补 dsh-client-ui- 前缀）
for (const m of src.matchAll(/P\('([^']+)',\s*'([^']+)'\)/g)) targets.add('dsh-client-ui-' + m[1] + '/lib/' + m[2])
if (targets.size === 0) { console.error('没能从补丁脚本里解析出目标文件'); process.exit(3) }

// 2) 建立镜像目录：优先嵌套布局，其次提升布局
const mirror = join(tmpdir(), 'dsh-patch-check-' + Date.now())
mkdirSync(mirror, { recursive: true })
let missing = []
for (const rel of targets) {
    const pkg = rel.split('/')[0]
    const rest = rel.slice(pkg.length + 1)
    const candidates = [
        join(runtimeDir, 'node_modules', '@deepseek-ai', 'dsh', 'node_modules', '@deepseek-ai', pkg, rest),
        join(runtimeDir, 'node_modules', '@deepseek-ai', pkg, rest),
    ]
    const found = candidates.find(p => existsSync(p))
    if (!found) { missing.push(rel); continue }
    const dest = join(mirror, pkg, rest)
    mkdirSync(dirname(dest), { recursive: true })
    writeFileSync(dest, readFileSync(found))
}

// 3) 拆分补丁脚本：头部（helpers）+ 各小节
const firstSection = src.indexOf('// ---------- ')
if (firstSection < 0) { console.error('补丁脚本里找不到小节标记'); process.exit(4) }
let head = src.slice(0, firstSection)
const sections = ('// ---------- ' + src.slice(firstSection + '// ---------- '.length))
    .split('// ---------- ')
    .map(s => s.trim())
    .filter(Boolean)

// 头部改造：把 B 指向镜像；把 rep() 的抛错改为记录
head = head.replace(/const B = '[^']*';/, 'const B = ' + JSON.stringify(mirror + '/') + ';')
head = head.replace(
    /function rep\(s, oldS, newS, label\) \{[\s\S]*?\n\}/,
    `const RESULTS = [];\nfunction rep(s, oldS, newS, label) {\n  const n = s.split(oldS).length - 1;\n  if (n !== 1) { RESULTS.push({ label, count: n, ok: false }); return s; }\n  RESULTS.push({ label, count: n, ok: true });\n  return s.replace(oldS, newS);\n}`
)
if (!head.includes('const RESULTS = []')) { console.error('无法改造 rep()（补丁脚本结构变了）'); process.exit(5) }

const report = []
for (const section of sections) {
    const name = (section.split('----------')[0] || '').trim()
    const body = section.slice(section.indexOf('----------') + 10).trim()
    const script = head + '\n' + body + '\nconsole.log("@@" + JSON.stringify(RESULTS))\n'
    const tmpFile = join(mirror, 'section.mjs')
    writeFileSync(tmpFile, script, 'utf8')
    const run = spawnSync(process.execPath, [tmpFile], { cwd: workdir, encoding: 'utf8' })
    const out = (run.stdout || '')
    const marker = out.lastIndexOf('@@')
    let anchors = []
    if (marker >= 0) {
        try { anchors = JSON.parse(out.slice(marker + 2).trim()) } catch { anchors = [] }
    }
    const failed = anchors.filter(a => !a.ok)
    report.push({
        section: name,
        anchors: anchors.length,
        applied: anchors.length - failed.length,
        failed: failed.map(a => ({ label: a.label, count: a.count })),
        error: anchors.length === 0 ? ((run.stderr || '').trim().split('\n')[0] || 'no anchors recorded') : null,
    })
}

try { rmSync(mirror, { recursive: true, force: true }) } catch {}

const total = report.reduce((n, r) => n + r.anchors, 0)
const applied = report.reduce((n, r) => n + r.applied, 0)
console.log(JSON.stringify({
    runtimeDir: resolve(runtimeDir),
    mirrorTargets: targets.size,
    missingFiles: missing,
    totalAnchors: total,
    appliedAnchors: applied,
    sections: report,
}, null, 2))
