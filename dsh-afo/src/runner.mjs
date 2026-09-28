// afo dsh 插件 · 纯逻辑层（不依赖 @deepseek-ai/*，可用 node 独立冒烟测试）。
// 职责：参数校验 → 组装 afo CLI 参数 → 调起 Python 核心 → 解析 JSON 输出。

import { spawn } from 'node:child_process'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

const PLUGIN_ROOT = path.dirname(path.dirname(fileURLToPath(import.meta.url)))

/** 随插件打包的 Python 核心库位置（afo 包所在目录，作为 PYTHONPATH 注入）。 */
export const AFO_VENDOR = path.join(PLUGIN_ROOT, 'vendor')

export const ACTIONS = ['scan', 'plan', 'migrate', 'verify', 'rollback', 'selfcheck']
export const MODES = ['copy', 'move', 'link']

/** 各动作所需的互斥/必填约束，提前在 JS 层拦截，给出模型可理解的错误。 */
export function validateParams(params) {
  const action = String(params.action ?? '')
  if (!ACTIONS.includes(action)) {
    throw new Error(`action 必须是 ${ACTIONS.join('/')} 之一，收到: "${action}"`)
  }
  if (['scan', 'plan', 'migrate'].includes(action) && !params.directory) {
    throw new Error(`${action} 需要 directory 参数`)
  }
  if (['plan', 'migrate'].includes(action) && !params.to) {
    throw new Error(`${action} 需要 to（目标根目录）参数`)
  }
  if (['verify', 'rollback'].includes(action) && !params.manifest) {
    throw new Error(`${action} 需要 manifest（manifest.json 路径）参数`)
  }
  if (params.mode !== undefined && !MODES.includes(params.mode)) {
    throw new Error(`mode 必须是 ${MODES.join('/')} 之一`)
  }
  return action
}

/** 组装 afo CLI 参数数组（不含 python 本体与 -m afo 前缀）。 */
export function buildCliArgs(params) {
  const action = validateParams(params)
  const args = [action]
  if (params.directory) args.push(String(params.directory))
  if (params.to) args.push('--to', String(params.to))
  if (params.mode) args.push('--mode', String(params.mode))
  if (params.categories) args.push('--categories', String(params.categories))
  if (params.manifest) args.push(String(params.manifest))
  if (params.batchSize) args.push('--batch-size', String(params.batchSize))
  if (params.noRecursive) args.push('--no-recursive')
  // 破坏性动作只在模型显式 confirm 时才加 --yes，缺省保持预览（确认门）
  if (['migrate', 'rollback'].includes(action) && params.confirm === true) {
    args.push('--yes')
  }
  args.push('--json')
  return args
}

/**
 * 调起 Python 核心并返回结构化结果。
 * @param {object} params 工具参数
 * @param {{python?: string, timeoutMs?: number}} [opts]
 * @returns {Promise<{code:number, json:object|null, stdout:string, stderr:string}>}
 */
export function runAfo(params, opts = {}) {
  const python = opts.python ?? process.env.AFO_PYTHON ?? 'python'
  const timeoutMs = opts.timeoutMs ?? 10 * 60 * 1000
  const cliArgs = buildCliArgs(params)

  return new Promise((resolve, reject) => {
    const child = spawn(python, ['-m', 'afo', ...cliArgs], {
      env: { ...process.env, PYTHONPATH: AFO_VENDOR, PYTHONUTF8: '1' },
      windowsHide: true,
    })
    let stdout = ''
    let stderr = ''
    const timer = setTimeout(() => {
      child.kill()
      reject(new Error(`afo ${params.action} 执行超时（>${timeoutMs}ms）`))
    }, timeoutMs)

    child.stdout.on('data', (d) => { stdout += d.toString('utf8') })
    child.stderr.on('data', (d) => { stderr += d.toString('utf8') })
    child.on('error', (err) => {
      clearTimeout(timer)
      reject(new Error(
        `无法启动 Python（${python}）：${err.message}。` +
        '请安装 Python 3.8+ 或设置环境变量 AFO_PYTHON 指向 python 可执行文件。'
      ))
    })
    child.on('close', (code) => {
      clearTimeout(timer)
      let json = null
      try { json = JSON.parse(stdout) } catch { /* 非 JSON 输出时保留原文 */ }
      resolve({ code: code ?? 1, json, stdout, stderr })
    })
  })
}

/** 把执行结果浓缩成给模型看的一句话摘要。 */
export function summarize(action, result) {
  const { code, json, stderr } = result
  if (json && action === 'scan') {
    const cats = Object.entries(json.categories ?? {})
      .map(([k, v]) => `${k}:${v.count}个(${v.size_human})`).join('，')
    return `扫描完成：${json.total_files} 个文件，共 ${json.total_size_human}。${cats}`
  }
  if (json && action === 'plan') {
    return `方案已生成：${json.total_files} 个迁移项，目标 ${json.target_root}（未改动任何文件）`
  }
  if (json && action === 'migrate') {
    return `迁移完成：成功 ${json.done} / 失败 ${json.failed} / 共 ${json.total}，清单 ${json.manifest_md}`
  }
  if (json && action === 'verify') {
    return `复检：${json.ok}/${json.total} 项正常`
  }
  if (json && action === 'rollback') {
    return `回滚：还原 ${json.restored}/${json.total} 项`
  }
  if (json && action === 'selfcheck') {
    const passed = (json.checks ?? []).filter((c) => c.passed).length
    return `自检：${passed}/${(json.checks ?? []).length} 项通过${json.ok ? '，核心功能正常' : '，存在失败项'}`
  }
  if (code !== 0 && stderr) return `执行失败（退出码 ${code}）：${stderr.trim()}`
  return `afo ${action} 退出码 ${code}`
}
