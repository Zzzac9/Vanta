import os
from typing import Iterable

from dotenv import load_dotenv
from openai import AsyncOpenAI

from agent.prompts import SYSTEM_PROMPT

# 从 backend/.env 读取 Key、模型名等配置，避免把密钥写死在源码里。
load_dotenv()

DEEPSEEK_API_KEY = os.getenv("DEEPSEEK_API_KEY", "")
DEEPSEEK_BASE_URL = os.getenv("DEEPSEEK_BASE_URL", "https://api.deepseek.com")
DEEPSEEK_MODEL = os.getenv("DEEPSEEK_MODEL", "deepseek-flash")


class LLMNotConfiguredError(RuntimeError):
    pass


def is_configured() -> bool:
    return bool(DEEPSEEK_API_KEY)


# DeepSeek 提供 OpenAI 兼容接口，因此可以直接使用 AsyncOpenAI 客户端。
def _client() -> AsyncOpenAI:
    if not DEEPSEEK_API_KEY:
        raise LLMNotConfiguredError(
            "缺少 DEEPSEEK_API_KEY，请在 backend/.env 中配置。"
        )
    return AsyncOpenAI(
        api_key=DEEPSEEK_API_KEY,
        base_url=DEEPSEEK_BASE_URL,
    )


# 这里是纯 LLM 层：接收完整消息历史，不负责 LangGraph 的状态管理。
async def chat_with_deepseek_messages(
    messages: Iterable[dict[str, str]],
) -> str:
    client = _client()
    # 每次请求都把系统提示放在最前面，再拼接当前 thread 的历史消息。
    payload = [
        {"role": "system", "content": SYSTEM_PROMPT},
        *list(messages),
    ]

    response = await client.chat.completions.create(
        model=DEEPSEEK_MODEL,
        messages=payload,
        stream=False,
    )

    reply = response.choices[0].message.content
    if not reply or not reply.strip():
        raise RuntimeError("DeepSeek 返回了空回复。")
    return reply.strip()


async def chat_with_deepseek(message: str) -> str:
    return await chat_with_deepseek_messages(
        [{"role": "user", "content": message}]
    )
