"""
knowledge - AI 知识库自动归纳入库模块

提供"项目完成 → 自动归纳总结 → 入库 → 索引 → 同步"的完整链路。
作为 ai-github-scanner skill 的内嵌能力，无需依赖外部服务。
"""
from .templates import ProjectSummaryTemplate, PatternTemplate, LessonTemplate
from .storage import KnowledgeStorage
from .ingestor import ProjectIngestor
from .indexer import KnowledgeIndexer

__version__ = "1.2.0"
__all__ = [
    "ProjectSummaryTemplate",
    "PatternTemplate",
    "LessonTemplate",
    "KnowledgeStorage",
    "ProjectIngestor",
    "KnowledgeIndexer",
]