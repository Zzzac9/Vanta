from typing import Any

from langchain_core.messages import HumanMessage, SystemMessage
from langgraph.graph import END, START, MessagesState, StateGraph
from langgraph.prebuilt import ToolNode, tools_condition

from agent.prompts import SYSTEM_PROMPT
from services.llm import get_chat_model
from tools.memory import MEMORY_TOOLS


async def _call_model(state: MessagesState):
    """Agent 节点：让模型基于当前 State 决定回答，或发起 Tool Call。"""
    # bind_tools 会把工具 schema 告诉模型。
    # 模型如果认为需要工具，会返回带 tool_calls 的 AIMessage。
    model_with_tools = get_chat_model().bind_tools(MEMORY_TOOLS)

    response = await model_with_tools.ainvoke(
        [
            SystemMessage(content=SYSTEM_PROMPT),
            *state["messages"],
        ]
    )

    # MessagesState 会把新消息追加到历史，而不是覆盖旧消息。
    return {"messages": [response]}


def build_graph(checkpointer: Any):
    """构建并编译 Vanta 的 LangGraph。"""
    builder = StateGraph(MessagesState)

    # 1) 注册节点。
    builder.add_node("agent", _call_model)
    builder.add_node("tools", ToolNode(MEMORY_TOOLS))

    # 2) 注册普通边：程序从 START 先进入 agent。
    builder.add_edge(START, "agent")

    # 3) 注册条件边：
    # tools_condition 会检查最后一条 AIMessage 是否包含 tool_calls。
    # 有工具调用 -> tools；没有 -> END。
    builder.add_conditional_edges(
        "agent",
        tools_condition,
        {
            "tools": "tools",
            "__end__": END,
        },
    )

    # 工具执行完后回到 agent，让模型读取工具结果并组织最终回答。
    builder.add_edge("tools", "agent")

    # Checkpointer 负责保存每个 thread_id 的短期会话 State。
    return builder.compile(checkpointer=checkpointer)


async def run_agent(
    graph: Any,
    message: str,
    thread_id: str,
) -> str:
    """运行一次 Agent；相同 thread_id 会恢复同一段短期上下文。"""
    config = {
        "configurable": {
            "thread_id": thread_id,
        }
    }

    result = await graph.ainvoke(
        {"messages": [HumanMessage(content=message)]},
        config=config,
    )

    final_message = result["messages"][-1]
    content = final_message.content

    if not isinstance(content, str):
        content = str(content)

    return content
