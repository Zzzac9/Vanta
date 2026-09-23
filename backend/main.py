from contextlib import asynccontextmanager
from pathlib import Path

from fastapi import FastAPI, HTTPException, Request
from langgraph.checkpoint.sqlite.aio import AsyncSqliteSaver
from pydantic import BaseModel

from agent.graph import build_graph, run_agent
from services.llm import (
    DEEPSEEK_MODEL,
    LLMNotConfiguredError,
    is_configured,
)
from services.memory_store import init_memory_db

DATA_DIR = Path(__file__).resolve().parent / "data"
CHECKPOINT_DB_PATH = DATA_DIR / "vanta_checkpoints.sqlite"


@asynccontextmanager
async def lifespan(app: FastAPI):
    """FastAPI 启动时初始化两类持久化存储。"""
    DATA_DIR.mkdir(parents=True, exist_ok=True)

    # 长期记忆：我们自己维护的 memories 表。
    init_memory_db()

    # 短期记忆：LangGraph Checkpointer 保存每个 thread_id 的完整 State。
    async with AsyncSqliteSaver.from_conn_string(
        str(CHECKPOINT_DB_PATH)
    ) as checkpointer:
        await checkpointer.setup()
        app.state.vanta_graph = build_graph(checkpointer)
        yield


# FastAPI 只负责 HTTP；Agent 的流程编排放在 agent/graph.py。
app = FastAPI(
    title="Vanta Backend",
    lifespan=lifespan,
)


class ChatRequest(BaseModel):
    message: str

    # 相同 thread_id 代表同一段短期会话。
    # 保留默认值是为了兼容旧版 iPhone 客户端。
    thread_id: str = "iphone-main-chat"


class ChatResponse(BaseModel):
    reply: str


@app.get("/")
def root():
    return {
        "name": "Vanta Backend",
        "status": "running",
        "agent": "LangGraph",
        "memory": "SQLite",
        "model": DEEPSEEK_MODEL,
        "configured": is_configured(),
    }


@app.get("/health")
def health():
    return {
        "status": "ok",
        "agent": "LangGraph",
        "short_term_memory": "sqlite-checkpointer",
        "long_term_memory": "sqlite",
        "llm_configured": is_configured(),
        "model": DEEPSEEK_MODEL,
    }


@app.post("/chat", response_model=ChatResponse)
async def chat(
    payload: ChatRequest,
    request: Request,
):
    """iPhone 的聊天请求从这里进入，再交给 LangGraph。"""
    message = payload.message.strip()
    thread_id = payload.thread_id.strip()

    if not message:
        raise HTTPException(status_code=400, detail="message 不能为空")
    if not thread_id:
        raise HTTPException(status_code=400, detail="thread_id 不能为空")

    try:
        # graph 已在 FastAPI 启动阶段编译完成，这里只负责运行它。
        reply = await run_agent(
            request.app.state.vanta_graph,
            message,
            thread_id,
        )
    except LLMNotConfiguredError as exc:
        raise HTTPException(status_code=503, detail=str(exc)) from exc
    except Exception as exc:
        raise HTTPException(
            status_code=502,
            detail=f"Agent 调用失败：{exc}",
        ) from exc

    return ChatResponse(reply=reply)
