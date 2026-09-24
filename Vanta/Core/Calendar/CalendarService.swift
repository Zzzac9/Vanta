import Foundation
import EventKit

enum CalendarServiceError: LocalizedError {
    case authorizationDenied
    case eventNotFound
    case noDefaultCalendar
    case queryFailed(String)

    var errorDescription: String? {
        switch self {
        case .authorizationDenied:
            return "没有获得日历访问权限"
        case .eventNotFound:
            return "没有找到要操作的日程"
        case .noDefaultCalendar:
            return "没有可用于创建事件的默认日历"
        case .queryFailed(let message):
            return "日历操作失败：\(message)"
        }
    }
}

// 只把 Agent 真正需要的字段从 EventKit 对象中抽出来。
struct CalendarEventSummary {
    // eventIdentifier 是 EventKit 给事件的稳定标识。
// 修改/删除时用它精确定位事件，避免只按标题猜。
    let id: String
    let title: String
    let start: Date
    let end: Date
    let isAllDay: Bool
    let location: String?
    let calendarTitle: String
}
@MainActor
final class CalendarService {
    static let shared = CalendarService()

    // EKEventStore 可以理解成“系统日历数据库入口”。
    private let eventStore = EKEventStore()
    private var didRequestAuthorization = false

    private init() {}

    /// Full Access 同时允许读取和写入事件。
    /// 真正执行写操作前，我们还会在 Vanta UI 再做一次用户确认。
    func requestAuthorizationIfNeeded() async throws {
        guard !didRequestAuthorization else {
            return
        }

        let granted = try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Bool, Error>) in
            eventStore.requestFullAccessToEvents { granted, error in
                if let error {
                    continuation.resume(
                        throwing: CalendarServiceError.queryFailed(
                            error.localizedDescription
                        )
                    )
                    return
                }

                continuation.resume(returning: granted)
            }
        }

        guard granted else {
            throw CalendarServiceError.authorizationDenied
        }

        didRequestAuthorization = true
    }
    /// 今天 00:00 到明天 00:00 的所有事件。
    func todayEvents() async throws -> [CalendarEventSummary] {
        try await requestAuthorizationIfNeeded()

        let calendar = Calendar.current
        let start = calendar.startOfDay(for: Date())
        let end = calendar.date(
            byAdding: .day,
            value: 1,
            to: start
        ) ?? Date()

        return events(from: start, to: end)
    }

    /// 未来 30 天内下一条还没结束的事件。
    func nextEvent() async throws -> CalendarEventSummary? {
        try await requestAuthorizationIfNeeded()

        let now = Date()
        let end = Calendar.current.date(
            byAdding: .day,
            value: 30,
            to: now
        ) ?? now

        return events(from: now, to: end).first {
            $0.end >= now
        }
    }

    /// 按 EventKit 的唯一标识读取一个事件。
    /// 修改/删除前可以先用它向用户展示“到底要动哪一条”。
    func event(id: String) async throws -> CalendarEventSummary {
        try await requestAuthorizationIfNeeded()

        guard let event = eventStore.event(withIdentifier: id) else {
            throw CalendarServiceError.eventNotFound
        }

        return summary(from: event)
    }

    /// 真正向系统 Calendar 创建事件。
    /// 这个方法本身不弹确认框；确认逻辑放在 PhoneToolExecutor/UI 层。
    func createEvent(
        title: String,
        start: Date,
        end: Date,
        location: String?
    ) async throws -> CalendarEventSummary {
        try await requestAuthorizationIfNeeded()
        guard let calendar = eventStore.defaultCalendarForNewEvents else {
            throw CalendarServiceError.noDefaultCalendar
        }

        let event = EKEvent(eventStore: eventStore)
        event.title = title
        event.startDate = start
        event.endDate = end
        event.location = location
        event.calendar = calendar

        do {
            try eventStore.save(event, span: .thisEvent, commit: true)
        } catch {
            throw CalendarServiceError.queryFailed(
                error.localizedDescription
            )
        }

        return summary(from: event)
    }

    /// 修改单个事件实例，不自动改整组重复事件。
    func updateEvent(
        id: String,
        title: String?,
        start: Date?,
        end: Date?,
        location: String?
    ) async throws -> CalendarEventSummary {
        try await requestAuthorizationIfNeeded()

        guard let event = eventStore.event(withIdentifier: id) else {
            throw CalendarServiceError.eventNotFound
        }

        if let title, !title.isEmpty {
            event.title = title
        }
        if let start {
            event.startDate = start
        }
        if let end {
            event.endDate = end
        }
        if let location, !location.isEmpty {
            event.location = location
        }
        do {
            try eventStore.save(event, span: .thisEvent, commit: true)
        } catch {
            throw CalendarServiceError.queryFailed(
                error.localizedDescription
            )
        }

        return summary(from: event)
    }

    /// 删除单个事件实例。重复日程不会整组删除。
    func deleteEvent(id: String) async throws {
        try await requestAuthorizationIfNeeded()

        guard let event = eventStore.event(withIdentifier: id) else {
            throw CalendarServiceError.eventNotFound
        }

        do {
            try eventStore.remove(event, span: .thisEvent, commit: true)
        } catch {
            throw CalendarServiceError.queryFailed(
                error.localizedDescription
            )
        }
    }

    private func events(
        from start: Date,
        to end: Date
    ) -> [CalendarEventSummary] {
        let predicate = eventStore.predicateForEvents(
            withStart: start,
            end: end,
            calendars: nil
        )

        return eventStore
            .events(matching: predicate)
            .sorted { $0.startDate < $1.startDate }
            .map(summary)
    }
    private func summary(
        from event: EKEvent
    ) -> CalendarEventSummary {
        CalendarEventSummary(
            id: event.eventIdentifier ?? "",
            title: event.title?.isEmpty == false
                ? event.title
                : "无标题日程",
            start: event.startDate,
            end: event.endDate,
            isAllDay: event.isAllDay,
            location: event.location,
            calendarTitle: event.calendar.title
        )
    }
}
