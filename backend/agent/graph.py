from langchain_core.messages import AIMessage, HumanMessage, SystemMessage
from langgraph.checkpoint.memory import InMemorySaver
from langgraph.graph import END, START, MessagesState, StateGraph

from services.llm import chat_with_deepseek_messages


# LangGraph 内部使用 Message 对象；DeepSeek 的 OpenAI 兼容接口需要 role/content 字典。
def _to_provider_messages(messages):
    result = []
    for message in messages:
        if isinstance(message, HumanMessage):
            role = "user"
        elif isinstance(message, AIMessage):
            role = "assistant"
        elif isinstance(message, SystemMessage):
            role = "system"
        else:
            continue

        content = message.content
        if not isinstance(content, str):
            content = str(content)
        result.append({"role": role, "content": content})
    return result


# 当前 Phase 1 只有一个节点：把完整会话历史交给 DeepSeek，并把回复写回 State。
async def _call_model(state: MessagesState):
    reply = await chat_with_deepseek_messages(
        _to_provider_messages(state["messages"])
    )
    return {"messages": [AIMessage(content=reply)]}


# Checkpointer 负责保存每个 thread_id 的短期会话历史。
# InMemorySaver 只存在内存里，所以后端重启后这些历史会消失。
checkpointer = InMemorySaver()

# Phase 1 的图非常简单：START -> agent -> END。以后工具节点会从这里继续扩展。
_builder = StateGraph(MessagesState)
_builder.add_node("agent", _call_model)
_builder.add_edge(START, "agent")
_builder.add_edge("agent", END)

vanta_graph = _builder.compile(checkpointer=checkpointer)


async def run_agent(message: str, thread_id: str) -> str:
    # LangGraph 用 configurable.thread_id 找到对应会话的 Checkpoint。
    config = {"configurable": {"thread_id": thread_id}}
    result = await vanta_graph.ainvoke(
        {"messages": [HumanMessage(content=message)]},
        config=config,
    )
    final_message = result["messages"][-1]
    content = final_message.content
    if not isinstance(content, str):
        content = str(content)
    return content
