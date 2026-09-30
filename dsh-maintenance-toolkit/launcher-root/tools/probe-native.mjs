// 原生依赖加载探针：升级后确认新运行时里带原生件的依赖都能 require/import 成功。
// 用法：<stageDir>\node.exe tools\probe-native.mjs
// 退出码：全部成功 0，有失败 1（便于升级流程断言）。
import { createRequire } from 'node:module'
import { join } from 'node:path'

const stage = process.argv[2] || process.cwd()
const require = createRequire(join(stage, 'package.json'))

const mods = ['node-pty', 'koffi', 'sharp', 'sherpa-onnx-node']
let failed = 0
for (const name of mods) {
    try {
        require(name)
        console.log(`OK   ${name}`)
    } catch (e) {
        failed++
        const msg = e && e.message ? String(e.message).split('\n')[0] : String(e)
        console.log(`FAIL ${name}  -> ${msg}`)
    }
}
process.exit(failed === 0 ? 0 : 1)
