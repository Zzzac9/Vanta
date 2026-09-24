import Foundation

struct RemoteMemory: Identifiable, Decodable {
    let id: String
    let content: String
    let createdAt: String

    enum CodingKeys: String, CodingKey {
        case id
        case content
        case createdAt = "created_at"
    }
}

enum VantaAPIError: LocalizedError {
    case invalidURL
    case invalidResponse
    case serverError(Int)
    case emptyReply
    case streamError(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "后端地址格式不正确"
        case .invalidResponse:
            return "后端返回了无法识别的响应"
        case .serverError(let code):
            return "后端请求失败（HTTP \(code)）"
        case .emptyReply:
            return "后端没有返回回复内容"
        case .streamError(let message):
            return "流式响应失败：\(message)"
        }
    }
}

// iOS 的网络层：把 Swift 数据编码成 JSON，发送给 FastAPI，再解析 reply。
struct VantaAPIClient {
    private struct ChatRequest: Encodable {
        let message: String
        let threadID: String

        // Swift 属性用驼峰命名，后端字段使用 snake_case。
        enum CodingKeys: String, CodingKey {
            case message
            case threadID = "thread_id"
        }
    }

    private struct ChatResponse: Decodable {
        let status: String?
        let reply: String
        let toolRequest: PhoneToolRequest?

        enum CodingKeys: String, CodingKey {
            case status
            case reply
            case toolRequest = "tool_request"
        }
    }

    // 后端的 NDJSON 流每一行都是一个 StreamEvent。
    // type 决定这一行是 token、工具请求、完成还是错误。
    private struct StreamEvent: Decodable {
        let type: String
        let delta: String?
        let message: String?
        let toolRequest: PhoneToolRequest?

        enum CodingKeys: String, CodingKey {
            case type
            case delta
            case message
            case toolRequest = "tool_request"
        }
    }

    private struct ToolResumeRequest: Encodable {
        let threadID: String
        let result: PhoneToolResult

        enum CodingKeys: String, CodingKey {
            case threadID = "thread_id"
            case result
        }
    }

    /// 真正的网络流式聊天。
    /// 后端生成一个 token，这里的 onToken 就立刻收到一个 token。
    static func streamChat(
        message: String,
        threadID: String,
        baseURL: String,
        onToken: @escaping (String) -> Void,
        confirmCalendarWrite: @escaping (
            CalendarWriteConfirmation
        ) async -> Bool
    ) async throws {
        var request = try makeChatStreamRequest(
            message: message,
            threadID: threadID,
            baseURL: baseURL
        )

        var toolHopCount = 0

        while true {
            let toolRequest = try await consumeStream(
                request: request,
                onToken: onToken
            )

            // nil 表示后端发来了 done，这一轮对话已经完成。
            guard let toolRequest else {
                return
            }

            toolHopCount += 1
            guard toolHopCount <= 5 else {
                throw VantaAPIError.invalidResponse
            }

            // 读取工具直接执行；Calendar 写工具会通过回调让 SwiftUI 先向用户确认。
            let toolResult = await PhoneToolExecutor.execute(
                toolRequest,
                confirmCalendarWrite: confirmCalendarWrite
            )
            request = try makeResumeStreamRequest(
                threadID: threadID,
                toolResult: toolResult,
                baseURL: baseURL
            )
        }
    }

    static func chat(
        message: String,
        threadID: String,
        baseURL: String
    ) async throws -> String {
        // 第一次请求先让 LangGraph 正常运行。
        var result = try await sendChat(
            message: message,
            threadID: threadID,
            baseURL: baseURL
        )

        // Agent 如果需要 iPhone 本地能力，会通过 interrupt 返回 tool_request。
        // iPhone 执行工具后再调用 /chat/resume，让同一个 Graph 继续往下跑。
        var toolHopCount = 0
        while result.status == "requires_tool" {
            guard let toolRequest = result.toolRequest else {
                throw VantaAPIError.invalidResponse
            }

            toolHopCount += 1
            guard toolHopCount <= 3 else {
                throw VantaAPIError.invalidResponse
            }

            let toolResult = await PhoneToolExecutor.execute(toolRequest)
            result = try await resumeChat(
                threadID: threadID,
                toolResult: toolResult,
                baseURL: baseURL
            )
        }

        let reply = result.reply.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !reply.isEmpty else {
            throw VantaAPIError.emptyReply
        }
        return reply
    }

    private static func consumeStream(
        request: URLRequest,
        onToken: @escaping (String) -> Void
    ) async throws -> PhoneToolRequest? {
        // data(for:) 要等完整响应结束；bytes(for:) 可以边下载边读取。
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        try validate(response)

        // 后端使用 NDJSON：每一行就是一个独立 JSON 事件。
        for try await line in bytes.lines {
            guard !line.isEmpty else { continue }
            guard let data = line.data(using: .utf8) else {
                throw VantaAPIError.invalidResponse
            }

            let event = try JSONDecoder().decode(StreamEvent.self, from: data)

            switch event.type {
            case "token":
                if let delta = event.delta, !delta.isEmpty {
                    onToken(delta)
                }

            case "tool_request":
                guard let toolRequest = event.toolRequest else {
                    throw VantaAPIError.invalidResponse
                }
                return toolRequest

            case "done":
                return nil

            case "error":
                throw VantaAPIError.streamError(
                    event.message ?? "后端流式执行失败"
                )

            default:
                continue
            }
        }

        // 正常流一定会以 done 或 tool_request 结束。
        throw VantaAPIError.invalidResponse
    }

    private static func makeChatStreamRequest(
        message: String,
        threadID: String,
        baseURL: String
    ) throws -> URLRequest {
        let url = try makeURL(baseURL: baseURL, path: "/chat/stream")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 120
        request.httpBody = try JSONEncoder().encode(
            ChatRequest(message: message, threadID: threadID)
        )
        return request
    }

    private static func makeResumeStreamRequest(
        threadID: String,
        toolResult: PhoneToolResult,
        baseURL: String
    ) throws -> URLRequest {
        let url = try makeURL(baseURL: baseURL, path: "/chat/resume/stream")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 120
        request.httpBody = try JSONEncoder().encode(
            ToolResumeRequest(threadID: threadID, result: toolResult)
        )
        return request
    }

    private static func sendChat(
        message: String,
        threadID: String,
        baseURL: String
    ) async throws -> ChatResponse {
        let url = try makeURL(baseURL: baseURL, path: "/chat")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30
        request.httpBody = try JSONEncoder().encode(
            ChatRequest(message: message, threadID: threadID)
        )

        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response)
        return try JSONDecoder().decode(ChatResponse.self, from: data)
    }

    private static func resumeChat(
        threadID: String,
        toolResult: PhoneToolResult,
        baseURL: String
    ) async throws -> ChatResponse {
        let url = try makeURL(baseURL: baseURL, path: "/chat/resume")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30
        request.httpBody = try JSONEncoder().encode(
            ToolResumeRequest(
                threadID: threadID,
                result: toolResult
            )
        )

        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response)
        return try JSONDecoder().decode(ChatResponse.self, from: data)
    }

    // 读取后端 SQLite 中真正的长期记忆。
    static func fetchMemories(baseURL: String) async throws -> [RemoteMemory] {
        let url = try makeURL(baseURL: baseURL, path: "/memories")
        let (data, response) = try await URLSession.shared.data(from: url)
        try validate(response)
        return try JSONDecoder().decode([RemoteMemory].self, from: data)
    }

    static func deleteMemory(id: String, baseURL: String) async throws {
        let url = try makeURL(baseURL: baseURL, path: "/memories/\(id)")
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        let (_, response) = try await URLSession.shared.data(for: request)
        try validate(response)
    }

    static func deleteThread(threadID: String, baseURL: String) async throws {
        let encoded = threadID.addingPercentEncoding(
            withAllowedCharacters: .urlPathAllowed
        ) ?? threadID
        let url = try makeURL(baseURL: baseURL, path: "/threads/\(encoded)")
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        let (_, response) = try await URLSession.shared.data(for: request)
        try validate(response)
    }

    private static func makeURL(baseURL: String, path: String) throws -> URL {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: "\(trimmed)\(path)") else {
            throw VantaAPIError.invalidURL
        }
        return url
    }

    private static func validate(_ response: URLResponse) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw VantaAPIError.invalidResponse
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            throw VantaAPIError.serverError(httpResponse.statusCode)
        }
    }
}
