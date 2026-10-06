"""
templates - 项目总结模板

三种 entry 类型：
  - ProjectSummary  项目完成总结（默认）
  - Pattern         跨项目提炼的可复用模式
  - Lesson          失败/坑/经验教训

模板均为 Markdown 字符串，ingestor 填充后写入知识库。
"""
from __future__ import annotations

from datetime import datetime
from typing import Any


# ============================================================
# 项目完成总结模板（默认 entry 类型）
# ============================================================
PROJECT_SUMMARY_TEMPLATE = """---
title: {title}
project_id: {project_id}
entry_type: project_summary
status: {status}
created_at: {created_at}
updated_at: {updated_at}
tags: {tags}
related_skills: {related_skills}
source_path: {source_path}
---

# {title}

## 一、项目概要

- **目标**：{goal}
- **范围**：{scope}
- **交付物**：{deliverables}
- **关键决策**：{key_decisions}

## 二、技术方案

{technical_approach}

## 三、关键代码 / 文件

{key_artifacts}

## 四、遇到的问题与解决

{problems_and_solutions}

## 五、可复用经验（提取为 pattern 候选）

{reusable_patterns}

## 六、教训与改进点（提取为 lesson 候选）

{lessons}

## 七、后续行动

{next_steps}

## 八、关联资源

- **进化日志**：{evolution_log_ref}
- **依赖 skill**：{related_skills}
- **关联项目**：{related_projects}
"""


# ============================================================
# 可复用模式模板
# ============================================================
PATTERN_TEMPLATE = """---
title: {title}
pattern_id: {pattern_id}
entry_type: pattern
category: {category}
created_at: {created_at}
tags: {tags}
source_projects: {source_projects}
---

# {title}

## 适用场景

{when_to_use}

## 解决方案

{solution}

## 代码片段 / 配置示例

```
{code_sample}
```

## 出处

- 首次提炼自：{source_projects}
- 验证项目：{verified_in}
"""


# ============================================================
# 经验教训模板
# ============================================================
LESSON_TEMPLATE = """---
title: {title}
lesson_id: {lesson_id}
entry_type: lesson
severity: {severity}
created_at: {created_at}
tags: {tags}
source_projects: {source_projects}
---

# {title}

## 现象

{symptom}

## 根因

{root_cause}

## 解决方案

{fix}

## 防止复发

{prevention}

## 出处

- 触发项目：{source_projects}
"""


class _BaseTemplate:
    """模板基类：提供 render 与 fill_meta 通用方法。"""

    template: str = ""
    required_fields: tuple = ()

    @classmethod
    def render(cls, **kwargs: Any) -> str:
        cls._validate(kwargs)
        # 缺省字段填空字符串，避免 KeyError
        filled = {f: kwargs.get(f, "") for f in cls._all_placeholders()}
        return cls.template.format(**filled)

    @classmethod
    def _all_placeholders(cls) -> list[str]:
        import re
        return list(set(re.findall(r"\{([a-z_][a-z0-9_]*)\}", cls.template)))

    @classmethod
    def _validate(cls, kwargs: dict) -> None:
        missing = [f for f in cls.required_fields if f not in kwargs or not kwargs[f]]
        if missing:
            raise ValueError(f"模板必填字段缺失：{missing}")


class ProjectSummaryTemplate(_BaseTemplate):
    template = PROJECT_SUMMARY_TEMPLATE
    required_fields = ("title", "project_id", "goal")

    @classmethod
    def render_with_meta(
        cls,
        *,
        title: str,
        project_id: str,
        goal: str,
        status: str = "completed",
        tags: list | None = None,
        related_skills: list | None = None,
        source_path: str = "",
        **body: Any,
    ) -> str:
        now = datetime.now().isoformat(timespec="seconds")
        return cls.template.format(
            title=title,
            project_id=project_id,
            status=status,
            created_at=now,
            updated_at=now,
            tags=_list_to_str(tags),
            source_path=source_path,
            goal=goal,
            scope=body.get("scope", ""),
            deliverables=body.get("deliverables", ""),
            key_decisions=body.get("key_decisions", ""),
            technical_approach=body.get("technical_approach", ""),
            key_artifacts=body.get("key_artifacts", ""),
            problems_and_solutions=body.get("problems_and_solutions", ""),
            reusable_patterns=body.get("reusable_patterns", ""),
            lessons=body.get("lessons", ""),
            next_steps=body.get("next_steps", ""),
            evolution_log_ref=body.get("evolution_log_ref", "references/evolution_log.md"),
            related_skills=_list_to_str(related_skills),
            related_projects=body.get("related_projects", ""),
        )


class PatternTemplate(_BaseTemplate):
    template = PATTERN_TEMPLATE
    required_fields = ("title", "pattern_id", "category", "when_to_use", "solution")

    @classmethod
    def render_with_meta(
        cls,
        *,
        title: str,
        pattern_id: str,
        category: str,
        when_to_use: str,
        solution: str,
        code_sample: str = "",
        tags: list | None = None,
        source_projects: list | None = None,
        verified_in: list | None = None,
    ) -> str:
        now = datetime.now().isoformat(timespec="seconds")
        return cls.template.format(
            title=title,
            pattern_id=pattern_id,
            category=category,
            created_at=now,
            tags=_list_to_str(tags),
            source_projects=_list_to_str(source_projects),
            when_to_use=when_to_use,
            solution=solution,
            code_sample=code_sample or "# 待补充",
            verified_in=_list_to_str(verified_in),
        )


class LessonTemplate(_BaseTemplate):
    template = LESSON_TEMPLATE
    required_fields = ("title", "lesson_id", "severity", "symptom", "root_cause", "fix")

    @classmethod
    def render_with_meta(
        cls,
        *,
        title: str,
        lesson_id: str,
        severity: str,
        symptom: str,
        root_cause: str,
        fix: str,
        prevention: str = "",
        tags: list | None = None,
        source_projects: list | None = None,
    ) -> str:
        now = datetime.now().isoformat(timespec="seconds")
        return cls.template.format(
            title=title,
            lesson_id=lesson_id,
            severity=severity,
            created_at=now,
            tags=_list_to_str(tags),
            source_projects=_list_to_str(source_projects),
            symptom=symptom,
            root_cause=root_cause,
            fix=fix,
            prevention=prevention or "待补充",
        )


def _list_to_str(items: list | None) -> str:
    """YAML front-matter 中 [a, b] 形式更易解析。"""
    if not items:
        return "[]"
    return "[" + ", ".join(str(i) for i in items) + "]"