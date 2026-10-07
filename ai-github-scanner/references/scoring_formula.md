# 评分公式详解

> 5维加权评分模型，权重总和=1.0

## 权重默认值

| 维度 | key | 默认权重 |
|------|-----|----------|
| 代码质量 | code_quality | 0.25 |
| 活跃度 | activity | 0.25 |
| 社区评价 | community | 0.20 |
| 实用性 | practicality | 0.20 |
| 安全信号 | safety | 0.10 |

## 子项公式

### code_quality (25%)
```
star_score     = min(100, stars/1000 * 30 + 10)
ratio_score    = 100 if 0.05 <= forks/stars <= 0.5
                 60  if fork_ratio > 0.5
                 30  if fork_ratio == 0
contrib_score  = min(100, contributors * 5)
license_score  = 100 if has_license else 0
topic_score    = min(100, topics_count * 15)
score = star_score*0.25 + ratio_score*0.20 + contrib_score*0.25
        + license_score*0.15 + topic_score*0.15
```

### activity (25%)
```
push_score     = 100 if last_push ≤ 7d
                 80  if ≤ 30d
                 60  if ≤ 90d
                 40  if ≤ 180d
                 10  else
commit_score   = min(100, commits_last_4w * 4)
release_score  = min(100, recent_releases * 20)
score = push_score*0.40 + commit_score*0.40 + release_score*0.20
```

### community (20%)
```
watch_score    = min(100, watchers/100 * 30 + 10)
star_score     = min(100, stars/500 * 50)
issue_score    = 90 if open_issues < 50
                 70 if < 200
                 40 else
home_score     = 100 if homepage else 50
score = watch_score*0.30 + star_score*0.30
        + issue_score*0.25 + home_score*0.15
```

### practicality (20%)
```
readme_score   = 50 base + 长度bonus + install/usage/example段落bonus
compat_score   = min(100, 关键词匹配数 * 25)
desc_score     = 80 if len(description) > 30 else 30
score = readme_score*0.40 + compat_score*0.40 + desc_score*0.20
```

### safety (10%)
```
起始100分，扣分制：
- 无license:  -30
- archived:   -50
- 描述含可疑关键词: -40
- 仓库年龄<30d: -20
score = max(0, 100 - deductions)
```

## 决策输出

```
total = Σ(dimension_score * weight)   范围 0-100

if total >= 85: decision = auto_install
elif total >= 70: decision = recommend
elif total >= 50: decision = record
else: decision = drop
```

## 缺失数据语义（v1.2.1）

> 背景：2026-10-06 真实扫描发现 304/304 个项目的 contributors/commits/releases/readme
> 四项二级数据全部为 0（gh 不可用且无 REST 兜底，静默返回空值被按 0 分计），
> 导致总分被硬性封顶在 69.45 < 70 推荐阈值——任何项目都无法被推荐或安装。

### 三态语义

| 状态 | 代码表示 | 评分处理 |
|------|----------|----------|
| 真实值 | 数值 / 空list / 空str | 正常计分（0 也是真实值） |
| 数据缺失 | `None` | **剔除该子项，其余子项权重按比例归一化**（不按 0 分计） |
| 全部缺失 | 全为 `None` | 该维度返回中性分 50 |

### 权重重归一化公式

```
score = Σ(可用子项分 × 子项权重) / Σ(可用子项权重)
```

例：activity 维度中 commits 数据缺失时 →
`score = (push_score×0.40 + release_score×0.20) / 0.60`

### 决策完备性门

`auto_install` 属于危险动作（会自动安装代码），要求完整证据：

```
if total >= 85 且 核心证据缺失 → 降级为 recommend
核心证据 = contributors / commits_last_4w / releases / readme 任一项
```

- 开关：`thresholds.require_full_data_for_auto_install`（默认 true）
- 报告 JSON 中每项有 `missing_data` 字段列出缺失项；summary 加注"数据不完整"

## 常见调优场景

| 场景 | 调整 |
|------|------|
| 项目偏保守，少误装 | 提高 auto_install 到 88-90 |
| 项目偏激进，多纳入新工具 | 降低 auto_install 到 80 |
| 强调活跃度 | 提高 activity 到 0.30，降低 community 到 0.15 |
| 强调安全 | 提高 safety 到 0.20，降低 practicality 到 0.15 |
| 允许数据不完整时也自动安装 | `require_full_data_for_auto_install: false`（不建议） |
| 纳入新维度 | 在 evaluator.py 加新维度，更新权重总和=1.0 |

## 验证方法

1. 用 `scripts/run_eval.py` 对一批已知项目跑评分
2. 检查 Top5 排序是否符合直觉
3. 检查 `decision` 分布是否合理（auto_install占比通常10-30%）
4. **检查数据完备性**：确认没有大面积 `missing_data`（大面积缺失说明 API/认证出问题，先修数据链再调评分）
5. 如偏差，先调整权重而非公式