# dsh-compat-apiproxy

`@deepseek-ai/dsh-host-apiproxy` 的部署本地兼容垫片。

## 背景

`@limuyang2/dsh-agent-team@0.1.4` 在模块加载期执行：

```js
import { RpcId } from '@deepseek-ai/dsh-host-apiproxy'
```

dsh 0.1.7 的依赖树已不再携带 apiproxy（该包停留在 0.1.1 时代，完整安装会拉入 25+ 个旧版 `@deepseek-ai` 依赖，与 0.1.7 运行时冲突风险极高）。agent-team 实际只用到 `RpcId` 一个导出（`lib/index.js:2723` 处 `rpcId: RpcId(randomUUID())`）。

## 实现

与官方实现语义完全一致（官方 `lib/index.js:716` 同为恒等函数，仅在类型层做 brand，零运行时开销）：

```js
function RpcId(id) { return id }
```

## 行为约定

- 若未来 agent-team 升级并引入 apiproxy 的其它导出，ESM 加载期会以
  `does not provide an export named 'X'` 明确报错（fail-fast）——届时按报错补齐即可，
  不会出现"静默拿到 undefined 后在运行期深处爆炸"的隐性问题。
- 包名沿用官方名是为了让既有 `import` 语句零改动解析；包标有 `private: true`，不会发布到 npm。

## 安装

不要手动安装本包，请使用套件根目录的安装器：

```bash
node ../../scripts/install.mjs --profile-dir "<你的 dsh-home>/profiles/web"
```

详见[套件 README](../../README.md)。
