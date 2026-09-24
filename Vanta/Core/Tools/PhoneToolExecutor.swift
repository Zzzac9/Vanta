import Foundation

struct PhoneToolRequest: Decodable {
    let name: String
    let arguments: [String: String]?
}

struct PhoneWorkoutData: Codable {
    let type: String
    let start: String
    let end: String
    let durationMinutes: Double
    let energyKcal: Double?
}

struct PhoneSleepData: Codable {
    let hours: Double
    let start: String?
    let end: String?
}

struct PhoneCalendarEventData: Codable {
    let id: String
    let title: String
    let start: String
    let end: String
    let isAllDay: Bool
    let location: String?
    let calendarTitle: String
}

struct PhoneToolResultData: Codable {
    let steps: Int?
    let activeEnergyKcal: Double?
    let workout: PhoneWorkoutData?
    let sleep: PhoneSleepData?
    let calendarEvents: [PhoneCalendarEventData]?
    let timeZone: String?
    let currentTime: String?
    let calendarMutation: String?

    init(
        steps: Int? = nil,
        activeEnergyKcal: Double? = nil,
        workout: PhoneWorkoutData? = nil,
        sleep: PhoneSleepData? = nil,
        calendarEvents: [PhoneCalendarEventData]? = nil,
        timeZone: String? = nil,
        currentTime: String? = nil,
        calendarMutation: String? = nil
    ) {
        self.steps = steps
        self.activeEnergyKcal = activeEnergyKcal
        self.workout = workout
        self.sleep = sleep
        self.calendarEvents = calendarEvents
        self.timeZone = timeZone
        self.currentTime = currentTime
        self.calendarMutation = calendarMutation
    }
}

struct PhoneToolResult: Codable {
    let success: Bool
    let data: PhoneToolResultData?
    let error: String?
}

// 写日历前交给 SwiftUI 展示的确认信息。
struct CalendarWriteConfirmation: Identifiable {
    let id = UUID()
    let title: String
    let message: String
    let confirmTitle: String
    let destructive: Bool
}

enum PhoneToolExecutor {
    static func execute(
        _ request: PhoneToolRequest,
        confirmCalendarWrite: (
            (CalendarWriteConfirmation) async -> Bool
        )? = nil
    ) async -> PhoneToolResult {
        do {
            switch request.name {
            case "health.steps":
                let steps = try await HealthService.shared.todaySteps()
                return success(
                    PhoneToolResultData(steps: steps)
                )

            case "health.active_energy":
                let kcal = try await HealthService.shared
                    .todayActiveEnergyKcal()
                return success(
                    PhoneToolResultData(activeEnergyKcal: kcal)
                )

            case "health.latest_workout":
                let workout = try await HealthService.shared.latestWorkout()
                guard let workout else {
                    return success(PhoneToolResultData())
                }

                let formatter = ISO8601DateFormatter()
                return success(
                    PhoneToolResultData(
                        workout: PhoneWorkoutData(
                            type: workout.type,
                            start: formatter.string(from: workout.start),
                            end: formatter.string(from: workout.end),
                            durationMinutes: workout.durationMinutes,
                            energyKcal: workout.energyKcal
                        )
                    )
                )

            case "health.sleep":
                let sleep = try await HealthService.shared.lastNightSleep()
                let formatter = ISO8601DateFormatter()

                return success(
                    PhoneToolResultData(
                        sleep: PhoneSleepData(
                            hours: sleep.hours,
                            start: sleep.start.map(formatter.string),
                            end: sleep.end.map(formatter.string)
                        )
                    )
                )

            case "calendar.context":
                let formatter = ISO8601DateFormatter()
                return success(
                    PhoneToolResultData(
                        timeZone: TimeZone.current.identifier,
                        currentTime: formatter.string(from: Date())
                    )
                )

            case "calendar.today":
                let events = try await CalendarService.shared.todayEvents()
                return success(
                    PhoneToolResultData(
                        calendarEvents: events.map(calendarEventData),
                        timeZone: TimeZone.current.identifier
                    )
                )
            case "calendar.next":
                let event = try await CalendarService.shared.nextEvent()
                let events = event.map { [calendarEventData($0)] } ?? []

                return success(
                    PhoneToolResultData(
                        calendarEvents: events,
                        timeZone: TimeZone.current.identifier
                    )
                )

            case "calendar.create":
                return try await createCalendarEvent(
                    request,
                    confirm: confirmCalendarWrite
                )

            case "calendar.update":
                return try await updateCalendarEvent(
                    request,
                    confirm: confirmCalendarWrite
                )

            case "calendar.delete":
                return try await deleteCalendarEvent(
                    request,
                    confirm: confirmCalendarWrite
                )

            default:
                return PhoneToolResult(
                    success: false,
                    data: nil,
                    error: "iPhone 不认识这个工具：\(request.name)"
                )
            }
        } catch {
            return PhoneToolResult(
                success: false,
                data: nil,
                error: error.localizedDescription
            )
        }
    }
    private static func createCalendarEvent(
        _ request: PhoneToolRequest,
        confirm: ((CalendarWriteConfirmation) async -> Bool)?
    ) async throws -> PhoneToolResult {
        guard
            let title = argument("title", from: request),
            let startText = argument("start_iso", from: request),
            let endText = argument("end_iso", from: request),
            let start = parseISO(startText),
            let end = parseISO(endText),
            end > start
        else {
            return failure("创建日程所需的标题或时间格式不正确")
        }

        let location = argument("location", from: request)
        let approved = await requestApproval(
            confirm,
            confirmation: CalendarWriteConfirmation(
                title: "创建日程？",
                message: calendarWriteMessage(
                    title: title,
                    start: start,
                    end: end,
                    location: location
                ),
                confirmTitle: "创建",
                destructive: false
            )
        )

        guard approved else {
            return failure("用户取消了创建日程")
        }

        let event = try await CalendarService.shared.createEvent(
            title: title,
            start: start,
            end: end,
            location: location
        )

        return success(
            PhoneToolResultData(
                calendarEvents: [calendarEventData(event)],
                timeZone: TimeZone.current.identifier,
                calendarMutation: "created"
            )
        )
    }

    private static func updateCalendarEvent(
        _ request: PhoneToolRequest,
        confirm: ((CalendarWriteConfirmation) async -> Bool)?
    ) async throws -> PhoneToolResult {
        guard let eventID = argument("event_id", from: request) else {
            return failure("缺少要修改的 event_id")
        }

        let current = try await CalendarService.shared.event(id: eventID)
        let title = argument("title", from: request)
        let start = optionalDateArgument("start_iso", from: request)
        let end = optionalDateArgument("end_iso", from: request)
        let location = argument("location", from: request)

        let targetStart = start ?? current.start
        let targetEnd = end ?? current.end
        guard targetEnd > targetStart else {
            return failure("修改后的结束时间必须晚于开始时间")
        }

        let approved = await requestApproval(
            confirm,
            confirmation: CalendarWriteConfirmation(
                title: "修改日程？",
                message: calendarWriteMessage(
                    title: title ?? current.title,
                    start: targetStart,
                    end: targetEnd,
                    location: location ?? current.location
                ),
                confirmTitle: "修改",
                destructive: false
            )
        )
        guard approved else {
            return failure("用户取消了修改日程")
        }

        let updated = try await CalendarService.shared.updateEvent(
            id: eventID,
            title: title,
            start: start,
            end: end,
            location: location
        )

        return success(
            PhoneToolResultData(
                calendarEvents: [calendarEventData(updated)],
                timeZone: TimeZone.current.identifier,
                calendarMutation: "updated"
            )
        )
    }

    private static func deleteCalendarEvent(
        _ request: PhoneToolRequest,
        confirm: ((CalendarWriteConfirmation) async -> Bool)?
    ) async throws -> PhoneToolResult {
        guard let eventID = argument("event_id", from: request) else {
            return failure("缺少要删除的 event_id")
        }

        let event = try await CalendarService.shared.event(id: eventID)
        let approved = await requestApproval(
            confirm,
            confirmation: CalendarWriteConfirmation(
                title: "删除日程？",
                message: calendarWriteMessage(
                    title: event.title,
                    start: event.start,
                    end: event.end,
                    location: event.location
                ),
                confirmTitle: "删除",
                destructive: true
            )
        )
        guard approved else {
            return failure("用户取消了删除日程")
        }

        try await CalendarService.shared.deleteEvent(id: eventID)

        return success(
            PhoneToolResultData(
                timeZone: TimeZone.current.identifier,
                calendarMutation: "deleted"
            )
        )
    }

    private static func requestApproval(
        _ confirm: ((CalendarWriteConfirmation) async -> Bool)?,
        confirmation: CalendarWriteConfirmation
    ) async -> Bool {
        // 没有 UI 确认回调时，写操作默认拒绝。
        // 这样以后即使别的调用路径误触发，也不会静默修改日历。
        guard let confirm else {
            return false
        }

        return await confirm(confirmation)
    }

    private static func argument(
        _ key: String,
        from request: PhoneToolRequest
    ) -> String? {
        guard
            let value = request.arguments?[key]?
                .trimmingCharacters(in: .whitespacesAndNewlines),
            !value.isEmpty
        else {
            return nil
        }

        return value
    }
    private static func parseISO(_ value: String) -> Date? {
        ISO8601DateFormatter().date(from: value)
    }

    private static func optionalDateArgument(
        _ key: String,
        from request: PhoneToolRequest
    ) -> Date? {
        guard let value = argument(key, from: request) else {
            return nil
        }
        return parseISO(value)
    }

    private static func calendarWriteMessage(
        title: String,
        start: Date,
        end: Date,
        location: String?
    ) -> String {
        var lines = [
            title,
            "开始：\(start.formatted(date: .abbreviated, time: .shortened))",
            "结束：\(end.formatted(date: .abbreviated, time: .shortened))",
        ]

        if let location, !location.isEmpty {
            lines.append("地点：\(location)")
        }

        return lines.joined(separator: "\n")
    }

    private static func calendarEventData(
        _ event: CalendarEventSummary
    ) -> PhoneCalendarEventData {
        let formatter = ISO8601DateFormatter()

        return PhoneCalendarEventData(
            id: event.id,
            title: event.title,
            start: formatter.string(from: event.start),
            end: formatter.string(from: event.end),
            isAllDay: event.isAllDay,
            location: event.location,
            calendarTitle: event.calendarTitle
        )
    }

    private static func success(
        _ data: PhoneToolResultData
    ) -> PhoneToolResult {
        PhoneToolResult(
            success: true,
            data: data,
            error: nil
        )
    }

    private static func failure(
        _ message: String
    ) -> PhoneToolResult {
        PhoneToolResult(
            success: false,
            data: nil,
            error: message
        )
    }
}
