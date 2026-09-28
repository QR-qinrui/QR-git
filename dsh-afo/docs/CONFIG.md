# afo 参数配置文档

## 一、全局约定

- `--json`：所有子命令通用，输出机读 JSON（dsh 插件层固定使用）；
- 退出码：`0` 成功；`1` 存在失败项；`2` 参数/路径错误；
- 破坏性命令（`migrate` / `rollback`）不带 `--yes` 时只预览，不改动任何文件。

## 二、子命令参数

### scan — 只读扫描

| 参数 | 类型 | 默认 | 说明 |
|---|---|---|---|
| `directory` | 位置参数 | 必填 | 待扫描目录 |
| `--no-recursive` | 开关 | 递归 | 只扫描顶层文件 |
| `--json` | 开关 | 关 | JSON 输出 |

默认跳过目录：`.git` `.svn` `.hg` `node_modules` `__pycache__` `.venv` `venv` `$RECYCLE.BIN` `System Volume Information`，以及符号链接目录。

### plan — 生成方案

| 参数 | 类型 | 默认 | 说明 |
|---|---|---|---|
| `directory` | 位置参数 | 必填 | 待整理目录 |
| `--to` | 路径 | 必填 | 目标根目录 |
| `--categories` | 逗号分隔 | 全部 | 只纳入指定类别 |
| `--no-recursive` | 开关 | 递归 | 只处理顶层文件 |

已位于 `--to` 目标结构内的文件自动排除（防自我迁移）。

### migrate — 执行迁移

| 参数 | 类型 | 默认 | 说明 |
|---|---|---|---|
| `directory` | 位置参数 | 必填 | 待整理目录 |
| `--to` | 路径 | 必填 | 目标根目录 |
| `--mode` | copy/move/link | move | 见下方模式说明 |
| `--categories` | 逗号分隔 | 全部 | 只迁移指定类别 |
| `--batch-size` | 整数 | 10 | 批大小（模式 P6） |
| `--manifest-dir` | 路径 | 目标根目录 | 清单输出目录 |
| `--yes` | 开关 | 关 | 确认执行（确认门） |

迁移模式对比：

| 模式 | 原件处理 | 原路径访问 | 适用场景 |
|---|---|---|---|
| `link` | 改名 `.bak-<日期>` 保留 | 经 Junction/符号链接保持有效 | 跨盘迁移且程序引用原路径（如 Ollama 模型库） |
| `move` | 校验后删除 | 失效 | 常规目录整理 |
| `copy` | 保留 | 不变 | 备份式归集 |

### verify — 完整性复检

| 参数 | 类型 | 默认 | 说明 |
|---|---|---|---|
| `manifest` | 位置参数 | 必填 | manifest.json 路径 |

检查项：目标存在且字节一致；link 模式原路径是有效链接（文件允许硬链接）；move 模式原路径已清空。

### rollback — 按清单回滚

| 参数 | 类型 | 默认 | 说明 |
|---|---|---|---|
| `manifest` | 位置参数 | 必填 | manifest.json 路径 |
| `--categories` | 逗号分隔 | 全部 | 只回滚指定类别 |
| `--yes` | 开关 | 关 | 确认执行 |

安全约束：原路径现存与目标无关的普通文件/目录时拒绝覆盖，需人工处理（防误删）。

### selfcheck — 环境自检

无参数（`--json` 通用）。在系统临时目录建沙盒实测全链路，14 项检测，退出码 0 = 全部通过。

## 三、类别映射表

| 类别 | 扩展名 |
|---|---|
| models | .gguf .safetensors .ckpt .pt .pth .onnx .bin .h5 .pb .tflite .mlmodel .mlpackage .lora .vae .ema |
| datasets | .csv .tsv .parquet .jsonl .arrow .feather .npy .npz .hdf5 .tfrecord |
| images | .jpg .jpeg .png .gif .bmp .webp .svg .ico .tiff |
| documents | .doc .docx .pdf .txt .md .xls .xlsx .ppt .pptx .odt .rtf .ini .log |
| code | .js .ts .jsx .tsx .py .java .cpp .c .h .html .css .scss .json .xml .yaml .yml .go .rs .php .rb .swift .kt |
| videos | .mp4 .avi .mov .wmv .flv .mkv .webm .m4v |
| audio | .mp3 .wav .flac .aac .ogg .wma .m4a |
| archives | .zip .rar .7z .tar .gz .bz2 .xz |
| others | 未匹配以上类别的文件 |

目标子目录默认与类别同名（`models/` `datasets/` …），代码内 `planner.DEFAULT_TARGET_DIRS` 可定制。

## 四、清单文件格式

每次迁移生成两个文件（默认落在目标根目录）：

- `manifest.json`：机读档案（版本、时间、模式、每项的 source/target/backup/link/status/error）；
- `迁移清单_<日期>.md`：人读清单（原路径↔新路径表格、回滚备份列表、回滚方法、失败明细）。

## 五、环境变量

| 变量 | 作用 | 使用方 |
|---|---|---|
| `AFO_PYTHON` | 指定 Python 解释器路径（PATH 无 python 时必填） | dsh 插件层 |
| `PYTHONPATH` | 指向 `core`（源码运行方式 A 时需要） | 独立 CLI |
| `PYTHONUTF8` | 置 1 解决 Windows 中文输出乱码（dsh 层自动注入） | 全部 |

## 六、dsh 插件配置

`dsh-afo/package.json` 关键字段：

- `dsh.bundle.patch` → `cordis.patch.yml`（insert 挂载声明，id 须与包名对应）；
- `dshx.contributes.tools` → `["afo_organize"]`（工具发现清单）；
- 插件无浏览器端渲染组件，工具结果以 JSON + 文本摘要呈现。

工具 `afo_organize` 参数与 CLI 一一对应，差异：`--yes` 映射为 `confirm`（布尔），且系统提示已约束 AI「先展示方案、获用户明确同意后才传 confirm=true」。
