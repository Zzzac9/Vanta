from contextlib import asynccontextmanager
from pathlib import Path

from fastapi import FastAPI, HTTPException, Request
from fastapi.responses import StreamingResponse
from langgraph.checkpoint.sqlite.aio import AsyncSqliteSaver
from pydantic import BaseModel
from typing import Any, Dict, Optional

from agent.graph import (
    build_graph,
    clear_pending_iphone_interrupts,
    resume_agent,
    run_agent,
)
from agent.streaming import stream_agent_run
from services.llm import (
    DEEPSEEK_MODEL,
    LLMNotConfiguredError,
    is_configured,
)
from services.memory_store import (
    delete_memory_record,
    init_memory_db,
    list_memory_records,
)

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
        app.state.checkpointer = checkpointer
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


class ToolRequestResponse(BaseModel):
    type: str
    name: str
    arguments: Dict[str, Any] = {}


class ChatResponse(BaseModel):
    # completed: reply 可直接展示
    # requires_tool: iPhone 需要先执行 tool_request，再调用 /chat/resume
    status: str = "completed"
    reply: str = ""
    tool_request: Optional[ToolRequestResponse] = None


class ToolResumeRequest(BaseModel):
    thread_id: str
    result: Dict[str, Any]


class MemoryResponse(BaseModel):
    id: str
    content: str
    created_at: str


async def prepare_thread_for_new_message(
    request: Request,
    thread_id: str,
) -> None:
    """让 thread 在接收新 HumanMessage 前处于合法状态。"""
    graph = request.app.state.vanta_graph
    config = {"configurable": {"thread_id": thread_id}}
    snapshot = await graph.aget_state(config)

    # 如果上一轮已经因为“tool call 后缺 ToolMessage”进入 BadRequest，
    # 当前 State 的消息顺序已经损坏，继续 append 只会重复失败。
    # 这时只清掉 LangGraph 的短期 Checkpoint；手机本地聊天记录和
    # 独立的长期 Memory SQLite 都不会被删除。
    errors = [
        str(task.error)
        for task in snapshot.tasks
        if getattr(task, "error", None)
    ]
    has_broken_tool_sequence = any(
        "tool_calls" in error
        and "tool messages" in error
        for error in errors
    )

    if has_broken_tool_sequence:
        await request.app.state.checkpointer.adelete_thread(thread_id)
        return

    # 如果只是停在 interrupt、还没被新消息破坏，则优先正常 resume，
    # 这样可以保留之前的对话上下文。
    await clear_pending_iphone_interrupts(
        graph,
        thread_id,
    )


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


@app.get("/memories", response_model=list[MemoryResponse])
def get_memories():
    """给 iPhone 记忆页读取真正的后端长期记忆。"""
    return list_memory_records()


@app.delete("/memories/{memory_id}")
def delete_memory(memory_id: str):
    """删除一条长期记忆。"""
    deleted = delete_memory_record(memory_id)
    if not deleted:
        raise HTTPException(status_code=404, detail="memory 不存在")
    return {"deleted": True}


@app.delete("/threads/{thread_id}")
async def delete_thread(thread_id: str, request: Request):
    """删除 LangGraph 中某个对话 thread 的全部 Checkpoint。"""
    if not thread_id.strip():
        raise HTTPException(status_code=400, detail="thread_id 不能为空")

    await request.app.state.checkpointer.adelete_thread(thread_id)
    return {"deleted": True}


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
        # 如果上一次 iPhone Tool 因断网/杀 App 等原因停在 interrupt，
        # 先自动取消旧操作，避免新的 HumanMessage 插进未完成 tool_call。
        await prepare_thread_for_new_message(
            request,
            thread_id,
        )

        # graph 已在 FastAPI 启动阶段编译完成，这里只负责运行它。
        result = await run_agent(
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

    return ChatResponse(**result)


@app.post("/chat/resume", response_model=ChatResponse)
async def resume_chat(
    payload: ToolResumeRequest,
    request: Request,
):
    """iPhone 执行本地工具后，用同一个 thread_id 恢复暂停的 LangGraph。"""
    thread_id = payload.thread_id.strip()
    if not thread_id:
        raise HTTPException(status_code=400, detail="thread_id 不能为空")

    try:
        result = await resume_agent(
            request.app.state.vanta_graph,
            thread_id,
            payload.result,
        )
    except Exception as exc:
        raise HTTPException(
            status_code=502,
            detail=f"Agent 恢复失败：{exc}",
        ) from exc

    return ChatResponse(**result)


@app.post("/chat/stream")
async def chat_stream(
    payload: ChatRequest,
    request: Request,
):
    """真正的流式聊天：模型生成一点，iPhone 就收到一点。"""
    message = payload.message.strip()
    thread_id = payload.thread_id.strip()

    if not message:
        raise HTTPException(status_code=400, detail="message 不能为空")
    if not thread_id:
        raise HTTPException(status_code=400, detail="thread_id 不能为空")

    # 新消息进来前先修复可能残留的旧 interrupt。
    # 这一步不做流式输出，只负责把旧的未完成 Tool Call 收尾。
    await prepare_thread_for_new_message(
        request,
        thread_id,
    )

    # NDJSON = 一行一个 JSON。这样 iPhone 可以按行持续解析，
    # 不需要等整个 HTTP 响应结束后才拿到完整字符串。
    stream = stream_agent_run(
        lambda handler: run_agent(
            request.app.state.vanta_graph,
            message,
            thread_id,
            callbacks=[handler],
        )
    )
    return StreamingResponse(
        stream,
        media_type="application/x-ndjson",
        headers={"Cache-Control": "no-cache"},
    )


@app.post("/chat/resume/stream")
async def resume_chat_stream(
    payload: ToolResumeRequest,
    request: Request,
):
    """iPhone Tool 执行完后，从 interrupt 位置继续，并继续流式返回。"""
    thread_id = payload.thread_id.strip()
    if not thread_id:
        raise HTTPException(status_code=400, detail="thread_id 不能为空")

    stream = stream_agent_run(
        lambda handler: resume_agent(
            request.app.state.vanta_graph,
            thread_id,
            payload.result,
            callbacks=[handler],
        )
    )

    return StreamingResponse(
        stream,
        media_type="application/x-ndjson",
        headers={"Cache-Control": "no-cache"},
    )
