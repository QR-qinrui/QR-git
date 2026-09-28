# afo — AI 资产文件扫描、归类与安全迁移工具

`afo`（AI File Organizer）把一次真实的「AI 文件全机迁移」实践（42GB ComfyUI 模型库登记 + 6.64GB Ollama 模型跨盘迁移零损失）沉淀为可复用工具：**只读扫描 → 方案确认 → 原子迁移 → 可追溯清单 → 可回滚**。

- **Python 核心库**：纯标准库、零第三方依赖，Windows / macOS / Linux 通用，可独立作为 CLI 使用；
- **dsh 插件层**：把核心库包装为 DeepSeek Harness 工具 `afo_organize`，AI 助手可直接调用（插件内嵌核心库，开箱即用）。

## 功能介绍

| 命令 | 作用 | 是否改动文件 |
|---|---|---|
| `scan` | 只读扫描目录，按 9 大类别统计（模型/数据集/图片/文档/代码/视频/音频/压缩包/其他） | 否 |
| `plan` | 生成分类迁移方案与目标结构，供确认 | 否 |
| `migrate` | 原子迁移：复制 → 字节校验 → 切换 → 验证 → 留备份，分批执行 | 是（需 `--yes`） |
| `verify` | 按迁移清单复检链接有效性、目标存在性、字节一致性 | 否 |
| `rollback` | 按迁移清单回滚（删链接、还原 .bak 备份） | 是（需 `--yes`） |
| `selfcheck` | 临时沙盒内全链路自检 + 环境兼容性报告，不触碰真实文件 | 否 |

三种迁移模式：

- **link（推荐跨盘迁移）**：原件改名 `.bak-<日期>` 保留，原位置创建目录联接（Windows Junction）/符号链接指向新位置——**所有程序按原路径访问零感知**，无需改任何配置或环境变量；
- **move**：复制 + 校验后删除原件（常规目录整理）；
- **copy**：仅复制，原件保留（最保守）。

## 环境依赖

| 依赖 | 要求 | 说明 |
|---|---|---|
| Python | ≥ 3.8（推荐 3.10+） | 核心库唯一运行时，仅用标准库 |
| Node.js | ≥ 22（仅 dsh 插件层需要） | dsh 0.1.x 宿主本身要求 Node 22+ |
| dsh | ≥ 0.1.7（仅 dsh 插件层需要） | DeepSeek Harness，插件挂载宿主 |

不兼容情况的明确提示：

- Windows 无管理员/开发者模式时符号链接可能不可用 → `selfcheck` 会实测并标注，Junction（目录）不受影响；
- Junction 不支持网络盘 → 创建失败时给出明确错误与建议；
- 找不到 Python → dsh 工具层提示设置环境变量 `AFO_PYTHON`。

## 安装步骤（可复现）

### 方式 A：独立 CLI（任意机器）

```bash
git clone <仓库地址> ai-file-organizer
cd ai-file-organizer
pip install .            # 安装为 afo 命令（可选）
# 或不安装，直接用源码运行：
PYTHONPATH=src python -m afo selfcheck
```

Windows PowerShell 设置 PYTHONPATH：`$env:PYTHONPATH = "src"`。

### 方式 B：dsh 插件

```bash
# 插件目录已内嵌 Python 核心（dsh-afo/vendor/afo），无需额外安装
dsh plugin --profile web add file:<本仓库绝对路径>/dsh-afo
# 指定 Python 解释器（PATH 中无 python 时）：
#   Windows: setx AFO_PYTHON "C:\path\to\python.exe"
#   macOS/Linux: export AFO_PYTHON=/usr/bin/python3
dsh --profile web   # 启动后即可让 AI「整理某个目录」
```

## 快速上手

```bash
# 1. 只读扫描（永不改动文件）
afo scan D:\待整理目录

# 2. 生成方案（不改动文件）
afo plan D:\待整理目录 --to E:\AI资源中心

# 3. 预览迁移（无 --yes 只打印方案，确认门）
afo migrate D:\待整理目录 --to E:\AI资源中心 --mode link

# 4. 确认后执行（分批复制+校验，生成 manifest.json 与 迁移清单_<日期>.md）
afo migrate D:\待整理目录 --to E:\AI资源中心 --mode link --yes

# 5. 复检
afo verify E:\AI资源中心\manifest.json

# 6. 回滚（同样需 --yes）
afo rollback E:\AI资源中心\manifest.json --yes
```

在 dsh 中对 AI 直接说：「扫描 D:\Downloads 看看构成」→「生成迁移到 E:\AI资源中心 的方案」→「确认执行」。AI 会按系统提示规范先 scan/plan、展示方案，获你同意后才带 `confirm=true` 执行。

## 参数配置

详见 [docs/CONFIG.md](docs/CONFIG.md)：全部子命令参数、类别映射表、目标目录定制、清单格式、环境变量。

## 自检方法

```bash
afo selfcheck          # 文本报告，退出码 0=全部通过
afo selfcheck --json   # 机读 JSON（供程序调用）
```

自检内容：Python 版本 → 平台识别 → 临时目录可写 → Junction/符号链接实测 → 沙盒内「扫描→方案→迁移→复检→回滚」全链路 → 沙盒清理。共 14 项，全部在系统临时目录进行，**不触碰任何真实文件**。

回归测试：

```bash
PYTHONPATH=src python -m unittest discover -s tests -v   # Python 核心 11 项
cd dsh-afo && AFO_PYTHON=<python路径> node test/smoke.mjs  # dsh 层 11 项
```

## 兼容性矩阵

| 环境 | 状态 | 说明 |
|---|---|---|
| Windows 10/11 | ✅ 已实测（Python 3.13，Node 22） | Junction 无需管理员权限 |
| macOS / Linux | ✅ 支持（符号链接路径） | 代码路径一致，CI 建议先跑 `selfcheck` |
| Python 3.8–3.13 | ✅ | `requires-python >= 3.8` |
| 网络盘/可移动盘 | ⚠️ | Junction 不支持网络路径，会明确报错并给出建议 |

## 常见问题（FAQ）

**Q1：migrate 会不会覆盖同名文件？**
不会。目标已存在时自动追加 `_1`/`_2` 递增后缀（模式 P5），绝不覆盖。

**Q2：迁移中途失败会怎样？**
每个迁移项是独立"原子事务"：校验失败的半成品会被清理，原件不动；单项失败记录到清单并继续其余项，不中断整体。

**Q3：link 模式迁移后原程序还能用吗？**
能。原路径变为 Junction/符号链接指向新位置，程序无感（本工具的设计蓝本：Ollama 模型跨盘迁移后 `ollama list` 实测正常）。

**Q4：如何彻底回滚？**
`afo rollback <manifest.json> --yes` 自动删链接并还原 `.bak` 备份；手动方式：删除原路径链接（Windows 用 `rmdir`，只删链接不删数据），把 `.bak-<日期>` 目录改名回原路径。

**Q5：Windows 上控制台中文乱码？**
设置 `PYTHONUTF8=1` 环境变量（dsh 工具层已自动注入）。

**Q6：会扫描哪些目录/跳过哪些？**
默认递归扫描，自动跳过 `.git`、`node_modules`、`__pycache__`、回收站等；`--no-recursive` 只看顶层文件。

## 项目结构

```
ai-file-organizer/
├── src/afo/              # Python 核心库（纯标准库）
│   ├── scanner.py        # P1 只读扫描与统计
│   ├── planner.py        # P1 迁移方案生成（确认门输入）
│   ├── migrator.py       # P2/P5/P6 原子迁移、冲突重命名、分批执行
│   ├── linker.py         # P3 跨平台 Junction/符号链接
│   ├── manifest.py       # P4 manifest.json + 迁移清单.md
│   ├── verify.py         # 完整性复检
│   ├── rollback.py       # 按清单回滚
│   ├── selfcheck.py      # 沙盒全链路自检
│   └── cli.py            # 六命令 CLI（--json 机读输出）
├── tests/test_core.py    # 单元测试（11 项）
├── dsh-afo/              # dsh 挂载层（插件包名 dsh-afo）
│   ├── src/index.js      # defineTool 注册 + 系统提示注入
│   ├── src/runner.mjs    # 纯逻辑层（参数校验/调起 Python/JSON 解析）
│   ├── vendor/afo/       # 内嵌的 Python 核心（开箱即用）
│   ├── test/smoke.mjs    # 插件层冒烟测试（11 项）
│   ├── package.json      # dsh.bundle.patch / dshx.contributes 清单
│   └── cordis.patch.yml  # insert 挂载声明
├── docs/CONFIG.md        # 参数配置文档
└── pyproject.toml        # 打包配置（pip install . 得 afo 命令）
```

## 设计模式（来自实战沉淀）

P1 只读扫描+确认门 · P2 原子迁移单元（复制→校验→切换→验证→留备份） · P3 路径透明化（Junction） · P4 可追溯清单 · P5 冲突安全重命名 · P6 小批量逐批验证。详见仓库根目录《第一阶段-成果清单与经验总结.md》（随附于工作区）。

## 版本记录

- **v1.0.0**（2026-09-29）：首个版本。六命令核心库 + dsh 插件层 + 22 项自动化测试 + 完整文档。

## 许可证

MIT
