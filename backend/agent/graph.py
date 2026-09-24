from typing import Any

from langchain_core.messages import HumanMessage, SystemMessage
from langchain_core.runnables import RunnableConfig
from langgraph.graph import END, START, MessagesState, StateGraph
from langgraph.prebuilt import ToolNode, tools_condition
from langgraph.types import Command

from agent.prompts import SYSTEM_PROMPT
from services.llm import get_chat_model
from tools.iphone import IPHONE_TOOLS
from tools.memory import MEMORY_TOOLS

ALL_TOOLS = [*MEMORY_TOOLS, *IPHONE_TOOLS]


async def _call_model(
    state: MessagesState,
    config: RunnableConfig,
):
    """Agent 节点：让模型基于当前 State 决定回答，或发起 Tool Call。"""
    # bind_tools 会把工具 schema 告诉模型。
    # 模型如果认为需要工具，会返回带 tool_calls 的 AIMessage。
    model_with_tools = get_chat_model().bind_tools(ALL_TOOLS)

    response = await model_with_tools.ainvoke(
        [
            SystemMessage(content=SYSTEM_PROMPT),
            *state["messages"],
        ],
        # 把 LangGraph 传进来的 config 继续传给模型。
        # 这里面包含 streaming callback，否则 token 会在这一层断掉。
        config=config,
    )

    # MessagesState 会把新消息追加到历史，而不是覆盖旧消息。
    return {"messages": [response]}


def build_graph(checkpointer: Any):
    """构建并编译 Vanta 的 LangGraph。"""
    builder = StateGraph(MessagesState)

    # 1) 注册节点。
    builder.add_node("agent", _call_model)
    builder.add_node("tools", ToolNode(ALL_TOOLS))

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


def _format_run_result(result: dict) -> dict:
    """把 LangGraph 的执行结果转换成 FastAPI / iPhone 更容易理解的协议。"""
    interrupts = result.get("__interrupt__") or []
    if interrupts:
        # Phase 3 先约定一次只执行一个 iPhone Tool。
        return {
            "status": "requires_tool",
            "reply": "",
            "tool_request": interrupts[0].value,
        }

    final_message = result["messages"][-1]
    content = final_message.content
    if not isinstance(content, str):
        content = str(content)

    return {
        "status": "completed",
        "reply": content,
        "tool_request": None,
    }


async def clear_pending_iphone_interrupts(
    graph: Any,
    thread_id: str,
) -> None:
    """新消息进入前，清理上一次没有完成的 iPhone interrupt。

    典型场景：用户在 Calendar 确认框时杀掉 App、断网或强制结束请求。
    如果不先恢复旧 interrupt，下一条 HumanMessage 会插到未完成的
    tool_call 后面，LLM API 会拒绝这段不合法的消息序列。
    """
    config = {"configurable": {"thread_id": thread_id}}

    # 当前设计一次只允许一个 iPhone Tool；留 3 次只是防止模型在
    # 收到“取消”结果后又意外发起新的本地 Tool。
    for _ in range(3):
        snapshot = await graph.aget_state(config)

        has_interrupt = any(
            bool(getattr(task, "interrupts", ()))
            for task in snapshot.tasks
        )
        if not has_interrupt:
            return

        await graph.ainvoke(
            Command(
                resume={
                    "success": False,
                    "data": None,
                    "error": "上一次 iPhone 工具操作未完成，已自动取消。",
                }
            ),
            config=config,
        )


async def run_agent(
    graph: Any,
    message: str,
    thread_id: str,
    callbacks: Any = None,
) -> dict:
    """开始一轮 Agent；可能直接完成，也可能因 iPhone Tool 暂停。"""
    config = {"configurable": {"thread_id": thread_id}}

    # 流式接口会传入 callback。LangGraph 仍保存完整消息，
    # callback 只是旁路监听 LLM 正在生成的 token。
    if callbacks:
        config["callbacks"] = callbacks

    result = await graph.ainvoke(
        {"messages": [HumanMessage(content=message)]},
        config=config,
    )
    return _format_run_result(result)


async def resume_agent(
    graph: Any,
    thread_id: str,
    tool_result: dict,
    callbacks: Any = None,
) -> dict:
    """iPhone 执行完本地工具后，从 LangGraph interrupt 的位置继续。"""
    config = {"configurable": {"thread_id": thread_id}}

    if callbacks:
        config["callbacks"] = callbacks

    result = await graph.ainvoke(
        Command(resume=tool_result),
        config=config,
    )
    return _format_run_result(result)
