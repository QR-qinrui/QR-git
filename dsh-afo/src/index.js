// afo dsh 插件 · 挂载层（Node 端）。
// 把 Python 核心库 afo 包装成 dsh 工具 afo_organize，并注入使用规范系统提示。
// 设计：scan/plan/verify/selfcheck 只读可随时调用；migrate/rollback 缺省仅预览，
// 模型必须先把方案展示给用户、获得明确同意后才传 confirm=true。

import { defineTool } from '@deepseek-ai/dsh-tools'
import { runAfo, summarize } from './runner.mjs'

export const name = 'dsh-afo'
export const inject = ['tools', 'systemPrompt']

const SYSTEM_PROMPT_TEXT = `## 文件整理工具 afo_organize 使用规范
- 整理/迁移文件前，必须先调用 action=scan（只读）了解目录构成，再用 action=plan 生成方案；
- plan 结果必须先展示给用户并获得明确同意，之后才允许 action=migrate 且 confirm=true；
- migrate 优先 mode=link（原路径保留链接，程序无感）；仅用户明确要求常规整理时用 mode=move；
- 迁移完成后调用 action=verify 复检，并向用户出示迁移清单路径；
- 任何失败如实汇报 error 字段，不要重试超过 2 次；
- selfcheck 可在安装后或排障时运行，验证插件环境是否正常。`

function afoOrganizeTool() {
  return defineTool({
    name: 'afo_organize',
    description:
      'AI 资产文件扫描、归类与安全迁移。scan=只读统计目录构成；plan=生成分类迁移方案（不改文件）；' +
      'migrate=执行迁移（缺省仅预览，confirm=true 才实际执行，原子复制+字节校验+可追溯清单，支持 link/move/copy 三模式）；' +
      'verify=按清单复检；rollback=按清单回滚（同样需要 confirm=true）；selfcheck=环境自检。' +
      '当用户要求整理目录、归类文件、迁移模型/数据集到其它磁盘时使用。',
    parameters: {
      action: {
        type: 'string', required: true,
        enum: ['scan', 'plan', 'migrate', 'verify', 'rollback', 'selfcheck'],
        description: '要执行的动作',
      },
      directory: { type: 'string', description: '待扫描/整理的目录（scan/plan/migrate 必填）' },
      to: { type: 'string', description: '目标根目录（plan/migrate 必填）' },
      mode: {
        type: 'string', enum: ['copy', 'move', 'link'],
        description: '迁移模式：link=原件留.bak+原位建链接（推荐）；move=校验后删原件；copy=仅复制。缺省 move',
      },
      categories: { type: 'string', description: '只处理指定类别，逗号分隔，如 models,datasets' },
      manifest: { type: 'string', description: 'manifest.json 路径（verify/rollback 必填）' },
      batchSize: { type: 'number', description: '批大小，缺省 10' },
      noRecursive: { type: 'boolean', description: '只处理顶层文件，不递归子目录' },
      confirm: {
        type: 'boolean',
        description: '破坏性动作确认开关：migrate/rollback 只有在已向用户展示方案并获得明确同意后才传 true',
      },
    },
    output: {
      schema: {
        type: 'object', additionalProperties: false,
        properties: {
          text: { type: 'string', required: true },
          data: { type: 'object', additionalProperties: true, required: true },
        },
      },
      render: (_args, value) => [{ type: 'text', text: value.text }],
      presentationMeta: (_args, value) => ({ kind: 'afo-organize', data: value.data }),
    },
    isConcurrencySafe: (args) => ['scan', 'plan', 'verify', 'selfcheck'].includes(String(args?.action)),
    async execute(args) {
      const result = await runAfo(args)
      const text = summarize(String(args.action), result)
      if (result.code !== 0 && result.json === null) {
        throw new Error(text)
      }
      return { text, data: result.json ?? { stdout: result.stdout, stderr: result.stderr, code: result.code } }
    },
  })
}

export function apply(ctx) {
  ctx.effect(() => ctx.tools.register(afoOrganizeTool()), 'afo.tool')
  if (ctx.systemPrompt?.section) {
    ctx.effect(
      () => ctx.systemPrompt.section({ name: 'dsh-afo', order: 900, text: SYSTEM_PROMPT_TEXT }),
      'afo.systemPrompt',
    )
  }
}
