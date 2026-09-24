from typing import Optional

from langchain_core.tools import tool
from langgraph.types import interrupt


def _request_iphone_tool(
    name: str,
    arguments: Optional[dict] = None,
) -> dict:
    """暂停 LangGraph，交给 iPhone 执行本地能力，再拿回结果。"""
    result = interrupt(
        {
            "type": "iphone_tool",
            "name": name,
            "arguments": arguments or {},
        }
    )

    if not isinstance(result, dict):
        return {
            "success": False,
            "error": "iPhone 返回了无法识别的工具结果。",
        }

    return result


def _tool_error(result: dict) -> Optional[str]:
    if result.get("success"):
        return None
    return result.get("error") or "未知错误"


@tool
def get_today_steps() -> str:
    """Read today's step count from the user's iPhone HealthKit data."""
    result = _request_iphone_tool("health.steps")
    if error := _tool_error(result):
        return f"读取 iPhone HealthKit 失败：{error}"
    steps = (result.get("data") or {}).get("steps")
    if steps is None:
        return "iPhone 没有返回今日步数。"
    return f"iPhone HealthKit 今日累计步数：{steps} 步"


@tool
def get_today_active_energy() -> str:
    """Read today's active energy burned from iPhone HealthKit in kilocalories."""
    result = _request_iphone_tool("health.active_energy")
    if error := _tool_error(result):
        return f"读取 iPhone HealthKit 失败：{error}"

    kcal = (result.get("data") or {}).get("activeEnergyKcal")
    if kcal is None:
        return "iPhone 没有返回今日活动能量。"

    return f"iPhone HealthKit 今日活动能量：{kcal:.1f} kcal"


@tool
def get_latest_workout() -> str:
    """Read the user's most recent workout recorded in iPhone HealthKit."""
    result = _request_iphone_tool("health.latest_workout")
    if error := _tool_error(result):
        return f"读取 iPhone HealthKit 失败：{error}"

    workout = (result.get("data") or {}).get("workout")
    if not workout:
        return "HealthKit 中没有找到训练记录。"
    workout_type = workout.get("type") or "未知训练"
    start = workout.get("start") or "未知"
    end = workout.get("end") or "未知"
    minutes = workout.get("durationMinutes")
    kcal = workout.get("energyKcal")

    parts = [
        f"类型：{workout_type}",
        f"开始：{start}",
        f"结束：{end}",
    ]
    if minutes is not None:
        parts.append(f"时长：{minutes:.1f} 分钟")
    if kcal is not None:
        parts.append(f"活动能量：{kcal:.1f} kcal")

    return "HealthKit 最近一次训练：" + "；".join(parts)


@tool
def get_last_night_sleep() -> str:
    """Read last night's sleep duration from iPhone HealthKit."""
    result = _request_iphone_tool("health.sleep")
    if error := _tool_error(result):
        return f"读取 iPhone HealthKit 失败：{error}"

    sleep = (result.get("data") or {}).get("sleep")
    if not sleep:
        return "iPhone 没有返回昨晚睡眠数据。"

    hours = sleep.get("hours")
    start = sleep.get("start")
    end = sleep.get("end")

    if hours is None:
        return "HealthKit 中没有找到昨晚的有效睡眠样本。"

    detail = f"昨晚实际睡眠约 {hours:.2f} 小时"
    if start and end:
        detail += f"；睡眠样本范围：{start} 至 {end}"

    return "iPhone HealthKit " + detail


@tool
def get_today_calendar_events() -> str:
    """Read all calendar events scheduled for today from the user's iPhone."""
    result = _request_iphone_tool("calendar.today")
    if error := _tool_error(result):
        return f"读取 iPhone 日历失败：{error}"

    data = result.get("data") or {}
    events = data.get("calendarEvents") or []
    time_zone = data.get("timeZone") or "未知时区"
    if not events:
        return f"今天的日历中没有事件。设备时区：{time_zone}"

    lines = []
    for event in events:
        title = event.get("title") or "无标题日程"
        start = event.get("start") or "未知"
        end = event.get("end") or "未知"
        all_day = event.get("isAllDay", False)
        location = event.get("location")
        calendar_title = event.get("calendarTitle") or "未知日历"
        event_id = event.get("id") or ""

        detail = f"{title}；开始：{start}；结束：{end}"
        if all_day:
            detail += "；全天事件"
        if location:
            detail += f"；地点：{location}"
        detail += f"；日历：{calendar_title}"
        if event_id:
            detail += f"；内部 event_id：{event_id}"
        lines.append("- " + detail)

    return (
        f"今天的 iPhone 日历事件（设备时区：{time_zone}）：\n"
        + "\n".join(lines)
    )


@tool
def get_next_calendar_event() -> str:
    """Read the next upcoming calendar event from the user's iPhone."""
    result = _request_iphone_tool("calendar.next")
    if error := _tool_error(result):
        return f"读取 iPhone 日历失败：{error}"

    data = result.get("data") or {}
    events = data.get("calendarEvents") or []
    time_zone = data.get("timeZone") or "未知时区"
    if not events:
        return f"未来 30 天没有找到日历事件。设备时区：{time_zone}"

    event = events[0]
    title = event.get("title") or "无标题日程"
    start = event.get("start") or "未知"
    end = event.get("end") or "未知"
    location = event.get("location")
    all_day = event.get("isAllDay", False)
    event_id = event.get("id") or ""

    detail = f"下一条日程：{title}；开始：{start}；结束：{end}"
    if all_day:
        detail += "；全天事件"
    if location:
        detail += f"；地点：{location}"
    if event_id:
        detail += f"；内部 event_id：{event_id}"

    return detail + f"；设备时区：{time_zone}"


@tool
def get_device_calendar_context() -> str:
    """Read the iPhone's current time and time zone for resolving relative dates."""
    result = _request_iphone_tool("calendar.context")
    if error := _tool_error(result):
        return f"读取 iPhone 当前时间失败：{error}"

    data = result.get("data") or {}
    current_time = data.get("currentTime") or "未知"
    time_zone = data.get("timeZone") or "未知时区"

    return f"iPhone 当前时间：{current_time}；设备时区：{time_zone}"


@tool
def create_calendar_event(
    title: str,
    start_iso: str,
    end_iso: str,
    location: str = "",
) -> str:
    """Create one iPhone calendar event after explicit user confirmation on the phone.

    Use ISO-8601 timestamps with offsets. If the user used a relative time
    such as "tomorrow afternoon", call get_device_calendar_context first.
    """
    result = _request_iphone_tool(
        "calendar.create",
        {
            "title": title,
            "start_iso": start_iso,
            "end_iso": end_iso,
            "location": location,
        },
    )
    if error := _tool_error(result):
        return f"创建日程未完成：{error}"

    data = result.get("data") or {}
    events = data.get("calendarEvents") or []
    if not events:
        return "日程已创建，但 iPhone 没有返回事件详情。"

    event = events[0]
    return (
        f"日程已创建：{event.get('title')}；"
        f"开始：{event.get('start')}；结束：{event.get('end')}；"
        f"内部 event_id：{event.get('id')}"
    )


@tool
def update_calendar_event(
    event_id: str,
    title: str = "",
    start_iso: str = "",
    end_iso: str = "",
    location: str = "",
) -> str:
    """Update one calendar event after explicit confirmation on the iPhone.

    First read the target event to obtain its internal event_id.
    Empty optional fields mean "leave unchanged".
    """
    result = _request_iphone_tool(
        "calendar.update",
        {
            "event_id": event_id,
            "title": title,
            "start_iso": start_iso,
            "end_iso": end_iso,
            "location": location,
        },
    )
    if error := _tool_error(result):
        return f"修改日程未完成：{error}"

    events = (result.get("data") or {}).get("calendarEvents") or []
    if not events:
        return "日程已修改。"

    event = events[0]
    return (
        f"日程已修改：{event.get('title')}；"
        f"开始：{event.get('start')}；结束：{event.get('end')}；"
        f"内部 event_id：{event.get('id')}"
    )


@tool
def delete_calendar_event(event_id: str) -> str:
    """Delete one calendar event after explicit confirmation on the iPhone.

    First read the target event to obtain its internal event_id.
    """
    result = _request_iphone_tool(
        "calendar.delete",
        {"event_id": event_id},
    )
    if error := _tool_error(result):
        return f"删除日程未完成：{error}"

    return "日程已从 iPhone Calendar 删除。"


IPHONE_TOOLS = [
    get_today_steps,
    get_today_active_energy,
    get_latest_workout,
    get_last_night_sleep,
    get_today_calendar_events,
    get_next_calendar_event,
    get_device_calendar_context,
    create_calendar_event,
    update_calendar_event,
    delete_calendar_event,
]
