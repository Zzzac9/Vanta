import sqlite3
from datetime import datetime, timezone
from pathlib import Path
from uuid import uuid4

# 长期记忆单独存到自己的 SQLite 文件中。
# 它和 LangGraph 的会话 Checkpoint 不是同一类数据。
DATA_DIR = Path(__file__).resolve().parent.parent / "data"
MEMORY_DB_PATH = DATA_DIR / "vanta_memory.sqlite"


def init_memory_db() -> None:
    """创建长期记忆表。重复调用是安全的。"""
    DATA_DIR.mkdir(parents=True, exist_ok=True)

    with sqlite3.connect(MEMORY_DB_PATH) as conn:
        conn.execute(
            """
            CREATE TABLE IF NOT EXISTS memories (
                id TEXT PRIMARY KEY,
                content TEXT NOT NULL UNIQUE,
                created_at TEXT NOT NULL
            )
            """
        )
        conn.commit()


def save_memory_record(content: str) -> bool:
    """保存一条长期记忆；已存在时不重复插入。"""
    text = content.strip()
    if not text:
        return False

    with sqlite3.connect(MEMORY_DB_PATH) as conn:
        cursor = conn.execute(
            """
            INSERT OR IGNORE INTO memories (id, content, created_at)
            VALUES (?, ?, ?)
            """,
            (
                str(uuid4()),
                text,
                datetime.now(timezone.utc).isoformat(),
            ),
        )
        conn.commit()
        return cursor.rowcount > 0


def search_memory_records(query: str, limit: int = 5) -> list[str]:
    """按关键词搜索长期记忆；工具调用时应传入简短关键词。"""
    keyword = query.strip()
    if not keyword:
        return []

    safe_limit = max(1, min(limit, 10))

    with sqlite3.connect(MEMORY_DB_PATH) as conn:
        rows = conn.execute(
            """
            SELECT content
            FROM memories
            WHERE content LIKE ?
            ORDER BY created_at DESC
            LIMIT ?
            """,
            (f"%{keyword}%", safe_limit),
        ).fetchall()

    return [row[0] for row in rows]


def list_memory_records() -> list[dict[str, str]]:
    """返回全部长期记忆，供 iPhone 的“记忆”页面展示。"""
    with sqlite3.connect(MEMORY_DB_PATH) as conn:
        rows = conn.execute(
            """
            SELECT id, content, created_at
            FROM memories
            ORDER BY created_at DESC
            """
        ).fetchall()

    return [
        {
            "id": row[0],
            "content": row[1],
            "created_at": row[2],
        }
        for row in rows
    ]


def delete_memory_record(memory_id: str) -> bool:
    """按 id 删除一条长期记忆。"""
    with sqlite3.connect(MEMORY_DB_PATH) as conn:
        cursor = conn.execute(
            "DELETE FROM memories WHERE id = ?",
            (memory_id,),
        )
        conn.commit()
        return cursor.rowcount > 0
