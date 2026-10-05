# 自判断自寻skill调度协议

> 让 ai-github-scanner 在执行过程中能自主识别能力缺口，
> 并主动调用其他已安装skill补齐缺口，形成"自进化"闭环。

## 触发原理

ai-github-scanner 内置 6 个能力缺口检测点：

| 检测点 | 缺口信号 | 推荐调用的skill |
|--------|----------|-----------------|
| 评估阶段 | 评分公式需要数学验证 | smart-charts（图表化展示分布） |
| 评估阶段 | 项目描述含中文需要降AI味 | humanizer-zh-pro |
| 审查阶段 | 需要生成PPT汇报 | ppt-generator |
| 安装阶段 | 需要操作Office文件 | office-suite-assistant |
| 报告阶段 | 需要查找财经项目数据 | neodata-financial-search / westock-data |
| 复盘阶段 | 需要捕获错误经验 | self-improving-agent |
| 全程 | 命中已安装skill但未被自动调用 | auto-skill-dispatcher兜底 |

## 调用决策算法

每次能力缺口检测命中时，按以下顺序判断：

```
1. 用户是否显式指定了某skill？
   是 → 尊重用户选择，调用该skill
   否 → 进入步骤2

2. 当前是否有可用的已安装skill能补齐缺口？
   是 → 主动调用，无需求询问
   否 → 进入步骤3

3. 是否能用通用代码补齐？
   是 → 直接写代码
   否 → 用 AskUserQuestion 询问用户

4. 关键约束：自判断仅用于 skill调用 决策，
   不修改 ai-github-scanner 自身的代码或评分逻辑。
```

## 命中已安装skill的自动调用清单

| 命中场景 | 自动调用的skill | 调用方式 |
|----------|------------------|----------|
| 用户要求生成图表/可视化 | smart-charts | Skill tool |
| 用户要求降AI味（中文文案） | humanizer-zh-pro | Skill tool |
| 用户要求生成PPT | ppt-generator | Skill tool |
| 用户上传或要求处理 Word/Excel/PPT | office-suite-assistant | Skill tool |
| 用户要求创建新skill | skill-creator | Skill tool |
| 用户提"安装skill/装技能" | marketplace-skill-installer | Skill tool |
| 用户要求金融数据查询 | neodata-financial-search | Skill tool |
| 用户要求选股/选基 | westock-tool | Skill tool |
| 用户要求修复bug | systematic-debugging | Skill tool |
| 用户要求提交代码 | github（已安装） | Skill tool |

## 嵌入SKILL.md的方式

将本协议的内容追加到 ai-github-scanner/SKILL.md 末尾的"扩展能力"小节，
并在每次启动skill时由调度器读取该清单。

## 与 auto-skill-dispatcher 的关系

- auto-skill-dispatcher 是全局自调度器（已安装）
- 本协议是 ai-github-scanner 内部的能力缺口补齐机制
- 两者互补：auto-skill-dispatcher识别"用户意图"，本协议识别"任务过程中的能力需求"

## 失败处理

- skill调用失败：记录到 `references/evolution_log.md`，
  错误覆盖为通用代码 fallback，标记本次为"自判断失败"
- 推荐调用的skill未安装：跳过调用，记录到 evolution_log
  作为"潜在skill依赖未满足"信号，但不阻塞任务