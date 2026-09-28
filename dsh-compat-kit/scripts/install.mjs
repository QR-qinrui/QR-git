#!/usr/bin/env node
/**
 * dsh-compat-kit installer
 *
 * Reproducibly wires the two compat packages into a dsh profile:
 *   1. backs up the profile package.json (timestamped .bak next to it)
 *   2. adds file: dependencies for both compat packages (absolute paths)
 *   3. ensures dsh.profile.bundles contains dsh-compat-settings-scope
 *   4. runs `pnpm install` in the profile (unless --skip-pnpm)
 *   5. prints the verification command
 *
 * Idempotent: re-running on an already-wired profile changes nothing and
 * reports "already up to date". Zero dependencies, Node >= 22, any OS.
 *
 * Usage:
 *   node scripts/install.mjs --profile-dir "D:/path/to/dsh-home/profiles/web"
 *   node scripts/install.mjs --profile-dir <path> --skip-pnpm
 *
 * Notes:
 * - Stop any running dsh instance before installing: live processes lock
 *   node_modules and cause pnpm EPERM rename failures on Windows.
 * - file: dependencies are copied/hard-linked by pnpm; after editing kit
 *   sources re-run this script (or `pnpm install`) to sync.
 */
import { readFileSync, writeFileSync, existsSync } from 'node:fs'
import { spawnSync } from 'node:child_process'
import { pathToFileURL, fileURLToPath } from 'node:url'
import path from 'node:path'

const KIT_ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..')
const PKG_APIPROXY = path.join(KIT_ROOT, 'packages', 'dsh-compat-apiproxy')
const PKG_SETTINGS = path.join(KIT_ROOT, 'packages', 'dsh-compat-settings-scope')

function fail(message) {
  console.error(`[FAIL] ${message}`)
  process.exit(1)
}
function info(message) { console.log(`[INFO] ${message}`) }
function ok(message) { console.log(`[ OK ] ${message}`) }

function parseArgs(argv) {
  const args = { profileDir: null, skipPnpm: false }
  const rest = argv.slice(2)
  for (let i = 0; i < rest.length; i++) {
    const a = rest[i]
    if (a.startsWith('--profile-dir=')) args.profileDir = a.slice('--profile-dir='.length)
    else if (a === '--profile-dir') {
      const next = rest[i + 1]
      if (!next || next.startsWith('--')) fail('--profile-dir requires a path value')
      args.profileDir = next
      i++
    }
    else if (a === '--skip-pnpm') args.skipPnpm = true
    else if (a === '--help' || a === '-h') {
      console.log('Usage: node scripts/install.mjs --profile-dir <dsh profile dir> [--skip-pnpm]')
      process.exit(0)
    } else fail(`unknown argument: ${a}`)
  }
  if (!args.profileDir) fail('missing required --profile-dir <path> (the dsh profile dir containing package.json)')
  return args
}

function toFileSpec(absPath) {
  // pnpm file: specs use forward slashes, including on Windows.
  return 'file:' + absPath.replace(/\\/g, '/')
}

function timestamp(date = new Date()) {
  const p = (n) => String(n).padStart(2, '0')
  return `${date.getFullYear()}${p(date.getMonth() + 1)}${p(date.getDate())}-${p(date.getHours())}${p(date.getMinutes())}${p(date.getSeconds())}`
}

const args = parseArgs(process.argv)

// --- validate kit ---------------------------------------------------------
for (const dir of [PKG_APIPROXY, PKG_SETTINGS]) {
  if (!existsSync(path.join(dir, 'package.json'))) fail(`kit package missing: ${dir} (run from an intact dsh-compat-kit checkout)`)
}

// --- validate profile -----------------------------------------------------
const profileDir = path.resolve(args.profileDir)
const pkgPath = path.join(profileDir, 'package.json')
if (!existsSync(pkgPath)) fail(`profile package.json not found: ${pkgPath}`)

const rawBytes = readFileSync(pkgPath)
const hasBom = rawBytes.length >= 3 && rawBytes[0] === 0xef && rawBytes[1] === 0xbb && rawBytes[2] === 0xbf
const raw = rawBytes.toString('utf8').replace(/^\uFEFF/, '')
let pkg
try {
  pkg = JSON.parse(raw)
} catch (e) {
  fail(`profile package.json is not valid JSON: ${e.message}`)
}

// --- compute desired state --------------------------------------------------
const wantDeps = {
  'dsh-compat-settings-scope': toFileSpec(PKG_SETTINGS),
  '@deepseek-ai/dsh-host-apiproxy': toFileSpec(PKG_APIPROXY),
}

pkg.dependencies = pkg.dependencies || {}
const changes = []
for (const [name, spec] of Object.entries(wantDeps)) {
  if (pkg.dependencies[name] !== spec) {
    pkg.dependencies[name] = spec
    changes.push(`dependency ${name} -> ${spec}`)
  }
}

pkg.dsh = pkg.dsh || {}
pkg.dsh.profile = pkg.dsh.profile || {}
if (!Array.isArray(pkg.dsh.profile.bundles)) {
  pkg.dsh.profile.bundles = pkg.dsh.profile.bundles ? pkg.dsh.profile.bundles : []
}
if (!pkg.dsh.profile.bundles.includes('dsh-compat-settings-scope')) {
  pkg.dsh.profile.bundles.push('dsh-compat-settings-scope')
  changes.push('bundles += dsh-compat-settings-scope')
}

// --- write (idempotent) -----------------------------------------------------
if (changes.length === 0) {
  ok('profile already up to date (no changes)')
} else {
  const backup = `${pkgPath}.bak-${timestamp()}`
  writeFileSync(backup, rawBytes)
  info(`backup written: ${backup}`)
  const body = JSON.stringify(pkg, null, 2) + '\n'
  writeFileSync(pkgPath, (hasBom ? '\uFEFF' : '') + body, 'utf8')
  for (const c of changes) ok(c)
}

// --- pnpm install -------------------------------------------------------------
if (args.skipPnpm) {
  info('--skip-pnpm set: run `pnpm install` in the profile dir yourself')
} else {
  info('running pnpm install (this can take a minute)...')
  const r = spawnSync('pnpm', ['install', '--prefer-offline'], {
    cwd: profileDir,
    stdio: 'inherit',
    shell: true,
  })
  if (r.error) fail(`failed to launch pnpm: ${r.error.message} (install pnpm or re-run with --skip-pnpm)`)
  if (r.status !== 0) fail(`pnpm install exited with code ${r.status} (EPERM? stop running dsh processes and retry)`)
  ok('pnpm install done')
}

// --- next steps -----------------------------------------------------------------
console.log('-'.repeat(64))
ok('install complete')
console.log('verify with:')
console.log(`  node "${path.join(KIT_ROOT, 'scripts', 'self-check.mjs')}" --profile-dir "${profileDir}"`)
console.log('then start dsh and watch the boot log: no "failed to import", no "settings.register is not a function",')
console.log('no "skipping profile bundle", no "entry did not activate".')
