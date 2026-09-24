import asyncio
import json
from typing import Any, AsyncIterator, Awaitable, Callable

from langchain_core.callbacks import AsyncCallbackHandler


class QueueTokenHandler(AsyncCallbackHandler):
    """把 LLM 新生成的 token 放进 asyncio.Queue。

    LangGraph 仍然负责完整的 Agent 状态；
    这个 Handler 只负责把生成过程“旁路”给 FastAPI，
    所以不会破坏原来的 Checkpoint / Tool Call 逻辑。
    """

    def __init__(self, queue: asyncio.Queue):
        self.queue = queue

    async def on_llm_new_token(self, token: str, **kwargs: Any) -> None:
        if token:
            await self.queue.put(
                {
                    "type": "token",
                    "delta": token,
                }
            )


def encode_event(event: dict) -> str:
    """每行一个 JSON，iPhone 可以边收边解析，不必等整个响应结束。"""
    return json.dumps(event, ensure_ascii=False) + "\n"


async def stream_agent_run(
    run: Callable[[AsyncCallbackHandler], Awaitable[dict]],
) -> AsyncIterator[str]:
    """把一次 LangGraph 执行转换为 NDJSON 流。"""
    queue: asyncio.Queue = asyncio.Queue()
    handler = QueueTokenHandler(queue)

    async def runner() -> None:
        try:
            result = await run(handler)

            if result["status"] == "requires_tool":
                # Agent 因 iPhone Tool interrupt 暂停。
                await queue.put(
                    {
                        "type": "tool_request",
                        "tool_request": result["tool_request"],
                    }
                )
            else:
                await queue.put({"type": "done"})
        except Exception as exc:
            # 流式响应已经开始后不能再改 HTTP status，
            # 所以错误也作为一个 stream event 返回给手机。
            await queue.put(
                {
                    "type": "error",
                    "message": str(exc),
                }
            )
        finally:
            await queue.put(None)

    task = asyncio.create_task(runner())

    try:
        while True:
            event = await queue.get()
            if event is None:
                break
            yield encode_event(event)
    finally:
        if not task.done():
            task.cancel()
