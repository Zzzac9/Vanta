import Foundation

struct ChatMessage: Identifiable, Codable, Equatable {
    enum Role: String, Codable {
        case user
        case assistant
    }

    let id: UUID
    let role: Role

    // 流式回答时，不会每个 token 都创建一个新消息。
    // 而是不断修改同一个助手气泡的 text，所以这里必须是 var。
    var text: String

    init(
        id: UUID = UUID(),
        role: Role,
        text: String
    ) {
        self.id = id
        self.role = role
        self.text = text
    }
}

struct ChatConversation: Identifiable, Codable, Equatable {
    let id: UUID
    let threadID: String
    var title: String
    var messages: [ChatMessage]
    var updatedAt: Date

    static func makeNew(
        threadID: String = UUID().uuidString
    ) -> ChatConversation {
        ChatConversation(
            id: UUID(),
            threadID: threadID,
            title: "新对话",
            messages: [
                ChatMessage(
                    role: .assistant,
                    text: "你好，我是 Vanta。有什么想让我做的吗？"
                )
            ],
            updatedAt: Date()
        )
    }
}

enum ChatHistoryStore {
    private static let key = "vanta.chat.conversations"

    static func load() -> [ChatConversation] {
        guard
            let data = UserDefaults.standard.data(forKey: key),
            let conversations = try? JSONDecoder().decode(
                [ChatConversation].self,
                from: data
            ),
            !conversations.isEmpty
        else {
            // 兼容旧版 App：如果已经有旧 thread_id，继续沿用。
            let oldThreadID = UserDefaults.standard.string(
                forKey: "vanta.chat.thread_id"
            ) ?? UUID().uuidString
            return [.makeNew(threadID: oldThreadID)]
        }

        return conversations
    }

    static func save(_ conversations: [ChatConversation]) {
        guard let data = try? JSONEncoder().encode(conversations) else {
            return
        }
        UserDefaults.standard.set(data, forKey: key)
    }
}
