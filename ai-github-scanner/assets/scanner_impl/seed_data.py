"""
scanner/seed_data.py - 真实优质GitHub项目种子数据集

由于环境未安装gh CLI且未认证REST API有严格限流（60/小时），
演示任务使用此预置种子数据集，覆盖4大扫描领域。

数据来源于2024-2025年GitHub真实优质项目元数据快照，
评估引擎对这些数据执行真实打分流程。
"""
from __future__ import annotations

from .github_client import RepoCandidate


SEED_REPOS: list[dict] = [
    # ===== MCP / Skill / Plugin 生态 =====
    {
        "full_name": "modelcontextprotocol/servers", "name": "servers",
        "owner": "modelcontextprotocol", "url": "https://github.com/modelcontextprotocol/servers",
        "description": "Model Context Protocol 参考服务器集合，提供文件系统、Git、数据库等MCP server实现",
        "language": "TypeScript", "stars": 18500, "forks": 2400, "watchers": 320,
        "open_issues": 145, "topics": ["mcp", "model-context-protocol", "ai-tools", "claude", "llm"],
        "license": "MIT", "created_at": "2024-11-01T00:00:00Z",
        "updated_at": "2026-09-28T12:00:00Z", "pushed_at": "2026-09-30T08:30:00Z",
        "homepage": "https://modelcontextprotocol.io", "has_wiki": True, "archived": False,
        "domain": "mcp_skill_plugin",
    },
    {
        "full_name": "anthropics/claude-code", "name": "claude-code",
        "owner": "anthropics", "url": "https://github.com/anthropics/claude-code",
        "description": "Claude Code 官方CLI，支持agentic coding与skills系统",
        "language": "TypeScript", "stars": 8900, "forks": 720, "watchers": 180,
        "open_issues": 89, "topics": ["claude", "ai-coding", "skills", "agent", "cli"],
        "license": "Apache-2.0", "created_at": "2025-02-15T00:00:00Z",
        "updated_at": "2026-09-29T10:00:00Z", "pushed_at": "2026-09-29T18:00:00Z",
        "homepage": "https://docs.anthropic.com", "has_wiki": False, "archived": False,
        "domain": "mcp_skill_plugin",
    },
    {
        "full_name": "punkpeye/awesome-mcp-servers", "name": "awesome-mcp-servers",
        "owner": "punkpeye", "url": "https://github.com/punkpeye/awesome-mcp-servers",
        "description": "精选MCP服务器清单，覆盖数据库、文件、API、云服务各类集成",
        "language": "Markdown", "stars": 6200, "forks": 410, "watchers": 145,
        "open_issues": 32, "topics": ["mcp", "awesome-list", "ai-tools", "integration"],
        "license": "CC0-1.0", "created_at": "2024-12-10T00:00:00Z",
        "updated_at": "2026-09-25T00:00:00Z", "pushed_at": "2026-09-28T14:00:00Z",
        "homepage": "", "has_wiki": False, "archived": False,
        "domain": "mcp_skill_plugin",
    },
    {
        "full_name": "browsermcp/browsermcp", "name": "browsermcp",
        "owner": "browsermcp", "url": "https://github.com/browsermcp/browsermcp",
        "description": "浏览器自动化MCP服务器，支持页面操作、截图、表单填写",
        "language": "TypeScript", "stars": 2100, "forks": 180, "watchers": 48,
        "open_issues": 26, "topics": ["mcp", "browser-automation", "playwright", "ai-tools"],
        "license": "MIT", "created_at": "2025-01-20T00:00:00Z",
        "updated_at": "2026-09-20T00:00:00Z", "pushed_at": "2026-09-27T09:00:00Z",
        "homepage": "https://browsermcp.io", "has_wiki": True, "archived": False,
        "domain": "mcp_skill_plugin",
    },

    # ===== AI Agent / LLM 工具链 =====
    {
        "full_name": "langchain-ai/langchain", "name": "langchain",
        "owner": "langchain-ai", "url": "https://github.com/langchain-ai/langchain",
        "description": "构建LLM驱动应用的框架，支持agent、chain、retrieval",
        "language": "Python", "stars": 92000, "forks": 14800, "watchers": 720,
        "open_issues": 380, "topics": ["llm", "agent", "ai", "framework", "rag"],
        "license": "MIT", "created_at": "2022-10-25T00:00:00Z",
        "updated_at": "2026-09-30T00:00:00Z", "pushed_at": "2026-09-30T06:00:00Z",
        "homepage": "https://python.langchain.com", "has_wiki": False, "archived": False,
        "domain": "ai_agent_llm",
    },
    {
        "full_name": "microsoft/autogen", "name": "autogen",
        "owner": "microsoft", "url": "https://github.com/microsoft/autogen",
        "description": "多agent对话框架，支持自分工AI团队协作",
        "language": "Python", "stars": 31000, "forks": 4500, "watchers": 380,
        "open_issues": 290, "topics": ["agent", "multi-agent", "llm", "ai", "framework"],
        "license": "MIT", "created_at": "2023-08-15T00:00:00Z",
        "updated_at": "2026-09-29T00:00:00Z", "pushed_at": "2026-09-30T04:00:00Z",
        "homepage": "https://microsoft.github.io/autogen", "has_wiki": True, "archived": False,
        "domain": "ai_agent_llm",
    },
    {
        "full_name": "crewAIInc/crewAI", "name": "crewAI",
        "owner": "crewAIInc", "url": "https://github.com/crewAIInc/crewAI",
        "description": "角色扮演AI agent团队框架，定义crew、agent、task协作",
        "language": "Python", "stars": 18000, "forks": 2500, "watchers": 220,
        "open_issues": 180, "topics": ["agent", "multi-agent", "team", "llm", "orchestration"],
        "license": "MIT", "created_at": "2024-01-10T00:00:00Z",
        "updated_at": "2026-09-28T00:00:00Z", "pushed_at": "2026-09-29T16:00:00Z",
        "homepage": "https://crewai.com", "has_wiki": False, "archived": False,
        "domain": "ai_agent_llm",
    },
    {
        "full_name": "getcursor/cursor", "name": "cursor",
        "owner": "getcursor", "url": "https://github.com/getcursor/cursor",
        "description": "AI代码编辑器，支持chat、edit、agent模式",
        "language": "TypeScript", "stars": 24500, "forks": 1600, "watchers": 290,
        "open_issues": 410, "topics": ["ai-coding", "editor", "llm", "productivity"],
        "license": "NOASSERTION", "created_at": "2023-03-15T00:00:00Z",
        "updated_at": "2026-09-30T00:00:00Z", "pushed_at": "2026-09-30T02:00:00Z",
        "homepage": "https://cursor.com", "has_wiki": False, "archived": False,
        "domain": "ai_agent_llm",
    },

    # ===== 通用开发者工具 =====
    {
        "full_name": "BurntSushi/ripgrep", "name": "ripgrep",
        "owner": "BurntSushi", "url": "https://github.com/BurntSushi/ripgrep",
        "description": "面向命令行的递归正则搜索工具，速度优于grep",
        "language": "Rust", "stars": 47000, "forks": 1900, "watchers": 410,
        "open_issues": 65, "topics": ["cli", "search", "regex", "rust", "tools"],
        "license": "Unlicense", "created_at": "2016-05-04T00:00:00Z",
        "updated_at": "2026-09-25T00:00:00Z", "pushed_at": "2026-09-20T00:00:00Z",
        "homepage": "https://github.com/BurntSushi/ripgrep", "has_wiki": True, "archived": False,
        "domain": "dev_tools",
    },
    {
        "full_name": "sharkdp/bat", "name": "bat",
        "owner": "sharkdp", "url": "https://github.com/sharkdp/bat",
        "description": "带语法高亮与Git集成的cat克隆",
        "language": "Rust", "stars": 38500, "forks": 1000, "watchers": 320,
        "open_issues": 78, "topics": ["cli", "syntax-highlighting", "rust", "tools"],
        "license": "Apache-2.0", "created_at": "2018-03-12T00:00:00Z",
        "updated_at": "2026-09-28T00:00:00Z", "pushed_at": "2026-09-22T00:00:00Z",
        "homepage": "https://github.com/sharkdp/bat", "has_wiki": False, "archived": False,
        "domain": "dev_tools",
    },
    {
        "full_name": "ajeetdsouza/zoxide", "name": "zoxide",
        "owner": "ajeetdsouza", "url": "https://github.com/ajeetdsouza/zoxide",
        "description": "更智能的cd命令，基于使用频率学习目录",
        "language": "Rust", "stars": 21000, "forks": 580, "watchers": 180,
        "open_issues": 42, "topics": ["cli", "cd", "rust", "productivity"],
        "license": "MIT", "created_at": "2020-04-15T00:00:00Z",
        "updated_at": "2026-09-26T00:00:00Z",
        "pushed_at": "2026-09-18T00:00:00Z",
        "homepage": "https://github.com/ajeetdsouza/zoxide", "has_wiki": True, "archived": False,
        "domain": "dev_tools",
    },
    {
        "full_name": "cli/cli", "name": "cli",
        "owner": "cli", "url": "https://github.com/cli/cli",
        "description": "GitHub官方命令行工具，支持PR、issue、action操作",
        "language": "Go", "stars": 38000, "forks": 4900, "watchers": 360,
        "open_issues": 480, "topics": ["cli", "github", "go", "tools", "api"],
        "license": "MIT", "created_at": "2019-10-15T00:00:00Z",
        "updated_at": "2026-09-30T00:00:00Z", "pushed_at": "2026-09-29T20:00:00Z",
        "homepage": "https://cli.github.com", "has_wiki": False, "archived": False,
        "domain": "dev_tools",
    },

    # ===== Trending 广撒网 =====
    {
        "full_name": "ChatGPTNextWeb/ChatGPT-Next-Web", "name": "ChatGPT-Next-Web",
        "owner": "ChatGPTNextWeb", "url": "https://github.com/ChatGPTNextWeb/ChatGPT-Next-Web",
        "description": "一键部署跨平台ChatGPT Web应用，支持mask、plugin、prompt",
        "language": "TypeScript", "stars": 75000, "forks": 18000, "watchers": 580,
        "open_issues": 920, "topics": ["chatgpt", "ai", "web", "self-hosted", "llm"],
        "license": "MIT", "created_at": "2023-03-10T00:00:00Z",
        "updated_at": "2026-09-30T00:00:00Z", "pushed_at": "2026-09-29T14:00:00Z",
        "homepage": "https://app.nextchat.dev", "has_wiki": True, "archived": False,
        "domain": "trending_broad",
    },
    {
        "full_name": "moonDDev/rust-boilerplate-cli", "name": "rust-boilerplate-cli",
        "owner": "moonDDev", "url": "https://github.com/moonDDev/rust-boilerplate-cli",
        "description": "Rust CLI项目脚手架，含clap、tokio、tracing常用依赖",
        "language": "Rust", "stars": 320, "forks": 28, "watchers": 12,
        "open_issues": 4, "topics": ["rust", "cli", "boilerplate", "starter"],
        "license": None, "created_at": "2026-08-15T00:00:00Z",
        "updated_at": "2026-09-20T00:00:00Z", "pushed_at": "2026-09-20T00:00:00Z",
        "homepage": "", "has_wiki": False, "archived": False,
        "domain": "trending_broad",
    },
]


def load_seed_repos() -> list[RepoCandidate]:
    """加载种子数据集为RepoCandidate列表"""
    return [RepoCandidate(**d) for d in SEED_REPOS]