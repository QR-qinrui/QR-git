// 运行时本地补丁「事务型应用器」
//
// 用途：把 patch-runtime-tree.mjs 这套私有 UI 补丁，安全地打到「布局可能不同」的运行时上。
//   1) 自动定位 7 个目标文件（兼容旧嵌套布局与新的提升布局）
//   2) 先复制到临时镜像目录，在镜像上按小节执行补丁
//   3) 任一小节失败 → 直接放弃，**不碰真实运行时**（避免半残状态）
//   4) 全部成功 → 才把镜像文件写回运行时
//
// 注意：patch-runtime-tree.mjs 对「追加型」补丁不是幂等的，重复应用会重复追加 CSS/组件。
//       因此只应在**干净的、刚装好的**运行时上使用；脚本会先确认每条锚点恰好命中一次之外的
//       情况并拒绝执行（配合 check-runtime-patches.mjs 使用：先检查 23/23 再应用）。
//
// 用法：
//   node apply-runtime-patches.mjs <patchScript> <runtimeDir> <workdir>
import { readFileSync, writeFileSync, mkdirSync, existsSync, rmSync, copyFileSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { spawnSync } from 'node:child_process'
import { tmpdir } from 'node:os'

const [patchScript, runtimeDir, workdir] = process.argv.slice(2)
if (!patchScript || !runtimeDir || !workdir) {
    console.error('usage: node apply-runtime-patches.mjs <patchScript> <runtimeDir> <workdir>')
    process.exit(2)
}

const src = readFileSync(patchScript, 'utf8').replace(/\r\n/g, '\n')

// 1) 目标文件与它们在运行时里的真实路径
const targets = new Map() // mirrorRel -> realPath
for (const m of src.matchAll(/P\('([^']+)',\s*'([^']+)'\)/g)) {
    const rel = 'dsh-client-ui-' + m[1] + '/lib/' + m[2]
    if (targets.has(rel)) continue
    const pkg = rel.split('/')[0]
    const rest = rel.slice(pkg.length + 1)
    const candidates = [
        join(runtimeDir, 'node_modules', '@deepseek-ai', 'dsh', 'node_modules', '@deepseek-ai', pkg, rest),
        join(runtimeDir, 'node_modules', '@deepseek-ai', pkg, rest),
    ]
    const found = candidates.find(p => existsSync(p))
    if (found) targets.set(rel, found)
}
if (targets.size === 0) { console.error('没有定位到任何目标文件，运行时布局不认识'); process.exit(3) }

// 2) 镜像 + 头部改造（B 指向镜像；rep 保持原语义：不命中就抛错）
const mirror = join(tmpdir(), 'dsh-patch-apply-' + Date.now())
mkdirSync(mirror, { recursive: true })
for (const [rel, real] of targets) {
    const dest = join(mirror, rel)
    mkdirSync(dirname(dest), { recursive: true })
    copyFileSync(real, dest)
}

const firstSection = src.indexOf('// ---------- ')
if (firstSection < 0) { console.error('补丁脚本里找不到小节标记'); process.exit(4) }
let head = src.slice(0, firstSection)
head = head.replace(/const B = '[^']*';/, 'const B = ' + JSON.stringify(mirror + '/') + ';')

const sections = ('// ---------- ' + src.slice(firstSection + '// ---------- '.length))
    .split('// ---------- ')
    .map(s => s.trim())
    .filter(Boolean)

const applied = []
const failed = []
for (const section of sections) {
    const name = (section.split('----------')[0] || '').trim()
    const body = section.slice(section.indexOf('----------') + 10).trim()
    const file = join(mirror, 'section.mjs')
    writeFileSync(file, head + '\n' + body + '\n', 'utf8')
    const run = spawnSync(process.execPath, [file], { cwd: workdir, encoding: 'utf8' })
    if (run.status === 0) { applied.push(name); continue }
    const line = ((run.stderr || '').trim().split('\n').find(l => l.includes('Error:')) || (run.stderr || '').trim().split('\n')[0] || 'unknown')
    failed.push({ section: name, reason: line.replace(/^\s+/, '') })
}

let written = false
if (failed.length === 0) {
    for (const [rel, real] of targets) copyFileSync(join(mirror, rel), real)
    written = true
} else {
    console.error('有 ' + failed.length + ' 个小节未能应用，已放弃写回（运行时保持原样）')
}
try { rmSync(mirror, { recursive: true, force: true }) } catch {}

console.log(JSON.stringify({
    runtimeDir,
    targetFiles: targets.size,
    sectionsApplied: applied,
    sectionsFailed: failed,
    written,
}, null, 2))
process.exit(written ? 0 : 1)
