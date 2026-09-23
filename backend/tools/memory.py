from langchain_core.tools import tool

from services.memory_store import (
    save_memory_record,
    search_memory_records,
)


@tool
def save_memory(content: str) -> str:
    """Save a stable user fact or preference into long-term memory.

    Use this for information likely to be useful in future conversations,
    such as preferences, habits, long-term goals, or explicit "remember this" requests.
    Do not use it for temporary details that only matter in the current conversation.
    """
    created = save_memory_record(content)

    if created:
        return f"已保存长期记忆：{content}"
    return f"这条长期记忆已经存在：{content}"


@tool
def search_memory(query: str, limit: int = 5) -> str:
    """Search long-term memory with a short keyword or concept.

    Prefer concise queries such as "咖啡", "工作地点", or "健身目标"
    instead of sending the user's whole sentence.
    """
    memories = search_memory_records(query, limit=limit)

    if not memories:
        return f"没有找到与“{query}”相关的长期记忆。"

    lines = "\n".join(f"- {item}" for item in memories)
    return f"找到以下长期记忆：\n{lines}"


# ToolNode 会统一注册这个列表里的工具。
MEMORY_TOOLS = [save_memory, search_memory]
