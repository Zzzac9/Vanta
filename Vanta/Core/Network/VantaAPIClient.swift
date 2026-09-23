import Foundation

enum VantaAPIError: LocalizedError {
    case invalidURL
    case invalidResponse
    case serverError(Int)
    case emptyReply

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
        let reply: String
    }

    static func chat(
        message: String,
        threadID: String,
        baseURL: String
    ) async throws -> String {
        let trimmedBaseURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))

        guard let url = URL(string: "\(trimmedBaseURL)/chat") else {
            throw VantaAPIError.invalidURL
        }

        // /chat 当前使用 JSON POST，请求体包含 message 和 thread_id。
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 20
        request.httpBody = try JSONEncoder().encode(
            ChatRequest(message: message, threadID: threadID)
        )

        // URLSession 的 async/await 会挂起当前 Task，不会阻塞界面主线程。
        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw VantaAPIError.invalidResponse
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            throw VantaAPIError.serverError(httpResponse.statusCode)
        }

        let result = try JSONDecoder().decode(ChatResponse.self, from: data)
        let reply = result.reply.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !reply.isEmpty else {
            throw VantaAPIError.emptyReply
        }

        return reply
    }
}
