import os
from functools import lru_cache

from dotenv import load_dotenv
from langchain_openai import ChatOpenAI

# 从 backend/.env 读取配置，避免把 API Key 写进源码。
load_dotenv()

DEEPSEEK_API_KEY = os.getenv("DEEPSEEK_API_KEY", "")
DEEPSEEK_BASE_URL = os.getenv("DEEPSEEK_BASE_URL", "https://api.deepseek.com")
DEEPSEEK_MODEL = os.getenv("DEEPSEEK_MODEL", "deepseek-flash")


class LLMNotConfiguredError(RuntimeError):
    pass


def is_configured() -> bool:
    return bool(DEEPSEEK_API_KEY)


@lru_cache(maxsize=1)
def get_chat_model() -> ChatOpenAI:
    """创建并缓存 DeepSeek ChatModel。"""
    if not DEEPSEEK_API_KEY:
        raise LLMNotConfiguredError(
            "缺少 DEEPSEEK_API_KEY，请在 backend/.env 中配置。"
        )

    # DeepSeek 提供 OpenAI 兼容接口，所以 LangChain 可以直接用 ChatOpenAI 接入。
    return ChatOpenAI(
        model=DEEPSEEK_MODEL,
        api_key=DEEPSEEK_API_KEY,
        base_url=DEEPSEEK_BASE_URL,
        temperature=0.2,
    )
