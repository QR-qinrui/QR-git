# 8角色协作协议

## 角色清单

| key | 中文名 | 英文名 | 决策权限 | 主要协作 |
|-----|--------|--------|----------|----------|
| orchestrator | 主导者 | Orchestrator | coordinate | reviewer, researcher, synchronizer |
| reviewer | 整体审查者 | Reviewer | review | orchestrator, code_reviewer |
| frontend_dev | 前端开发 | Frontend Dev | execute | backend_dev, code_reviewer |
| backend_dev | 后端开发 | Backend Dev | execute | frontend_dev, code_reviewer |
| code_reviewer | 代码审查 | Code Reviewer | review | frontend_dev, backend_dev |
| researcher | 信息寻找者 | Researcher | execute | orchestrator, executors |
| synchronizer | 同步分发者 | Synchronizer | execute | orchestrator, optimizer |
| optimizer | 总结优化者 | Optimizer | optimize | orchestrator, synchronizer |

*注：用户原始需求中提到7角色，但实际设计为8角色（执行团队含3个子角色），所以是8个。*

## 三层分组

```
协调团队 COORDINATION: orchestrator / reviewer / synchronizer
执行团队 EXECUTION:    frontend_dev / backend_dev / code_reviewer
支撑团队 SUPPORT:      researcher / optimizer
```

## 任务状态机

```
pending → assigned → in_progress → in_review → approved → done
                          ↓             ↓
                       blocked       revision → in_progress
                          ↓             ↓
                       escalated    escalated → done / in_progress
```

允许的状态转移（TRANSITIONS）：
- PENDING: [ASSIGNED]
- ASSIGNED: [IN_PROGRESS, BLOCKED]
- IN_PROGRESS: [IN_REVIEW, BLOCKED]
- IN_REVIEW: [APPROVED, REVISION, BLOCKED]
- REVISION: [IN_PROGRESS, ESCALATED]
- APPROVED: [DONE]
- BLOCKED: [ESCALATED, IN_PROGRESS]
- ESCALATED: [IN_PROGRESS, DONE]
- DONE: []

## 消息类型

| type | 用途 | from → to |
|------|------|-----------|
| task_assign | 任务分配 | orchestrator → executor |
| task_update | 状态更新 | executor → synchronizer |
| review_request | 审查请求 | executor → reviewer |
| review_result | 审查结果 | reviewer → executor |
| info_broadcast | 信息广播 | synchronizer → all |
| escalate | 升级 | executor → orchestrator |
| handoff | 移交 | executor → executor |

## 消息格式

```python
TeamMessage(
    type: MessageType,
    from_role: str,
    to_role: str,
    task_id: str,
    payload: dict,
    timestamp: str  # ISO 8601
)
```

## 协作剧本（GitHub资源筛选任务）

### 阶段1：任务接收与拆解（主导者）
- 拆解为5个子任务：扫描采集 / 评估打分 / 安全检查 / 自动安装 / 报告生成
- 分配给 researcher（扫描）、backend_dev（评估+安装）、synchronizer（状态同步）

### 阶段2：信息收集（信息寻找者）
- 调研目标领域关键词
- 调用GitHub API采集候选项目
- 输出候选清单，通知 synchronizer 分发

### 阶段3：评估执行（后端开发）
- 接收候选清单，运行评估引擎打分
- 提交评估结果给 code_reviewer 审查

### 阶段4：代码审查（代码审查员）
- 审查评分模型、安全门规则、安装逻辑
- 通过则签发给 reviewer，未通过则打回 backend_dev

### 阶段5：整体审查（整体审查者）
- 审查整套交付物
- 签发验收或打回

### 阶段6：信息同步（同步分发者）
- 全程维护共享状态
- 分发关键决策

### 阶段7：复盘优化（总结优化者）
- 分析耗时、阻断、打回次数
- 输出复盘报告与改进建议
- 沉淀经验到skills体系

## 扩展为完整8-agent并行部署

每角色spawn为独立teammate：

| 角色 | spawn name | subagent_type |
|------|-----------|---------------|
| orchestrator | orchestrator | general-purpose |
| reviewer | reviewer | general-purpose |
| frontend_dev | fe-dev | general-purpose |
| backend_dev | be-dev | general-purpose |
| code_reviewer | code-reviewer | general-purpose |
| researcher | researcher | general-purpose |
| synchronizer | synchronizer | general-purpose |
| optimizer | optimizer | general-purpose |

每个teammate的prompt注入对应RoleSpec（从SKILL.md/scripts/spawn_team.py生成）。

## 冲突升级路径

```
executor 遇阻塞 → SendMessage(escalate) → orchestrator
                                         ↓
                              判断是否影响整体交付
                              ↓                ↓
                          可绕过            影响交付
                              ↓                ↓
                          重新分配         升级到 reviewer
                                          ↓
                                       reviewer 决策
                                       ↓        ↓
                                   调整验收     打回executor
```

## 协议演进约束

- 新增角色必须更新 `team/roles.py` 的 ROLES 字典
- 状态机新增状态必须更新 `TRANSITIONS` 的key与可达路径
- 消息类型扩展必须更新 `MessageType` 枚举
- 所有协议变更必须 append 到 `references/evolution_log.md`