from fastapi import FastAPI, HTTPException
from pydantic import BaseModel

from agent.graph import run_agent
from services.llm import (
    DEEPSEEK_MODEL,
    LLMNotConfiguredError,
    is_configured,
)

# FastAPI 只负责 HTTP 接口；真正的 Agent 逻辑放在 agent/ 目录里。
app = FastAPI(title="Vanta Backend")


class ChatRequest(BaseModel):
    message: str
    # thread_id 用来区分不同对话。相同 thread_id 会复用同一段短期上下文。
    thread_id: str = "iphone-main-chat"


class ChatResponse(BaseModel):
    reply: str


@app.get("/")
def root():
    return {
        "name": "Vanta Backend",
        "status": "running",
        "agent": "LangGraph",
        "model": DEEPSEEK_MODEL,
        "configured": is_configured(),
    }


@app.get("/health")
def health():
    return {
        "status": "ok",
        "agent": "LangGraph",
        "llm_configured": is_configured(),
        "model": DEEPSEEK_MODEL,
    }


# iPhone 的聊天请求统一从这里进入，再交给 LangGraph。
@app.post("/chat", response_model=ChatResponse)
async def chat(request: ChatRequest):
    message = request.message.strip()
    thread_id = request.thread_id.strip()

    if not message:
        raise HTTPException(status_code=400, detail="message 不能为空")
    if not thread_id:
        raise HTTPException(status_code=400, detail="thread_id 不能为空")

    try:
        # FastAPI 不关心 Agent 内部怎么推理，只等待最终回复。
        reply = await run_agent(message, thread_id)
    except LLMNotConfiguredError as exc:
        raise HTTPException(status_code=503, detail=str(exc)) from exc
    except Exception as exc:
        raise HTTPException(
            status_code=502,
            detail=f"Agent 调用失败：{exc}",
        ) from exc

    return ChatResponse(reply=reply)
