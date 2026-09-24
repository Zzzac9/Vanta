import SwiftUI
import Foundation

struct AssistantView: View {
    @State private var conversations: [ChatConversation]
    @State private var selectedConversationID: UUID
    @State private var input = ""
    @State private var pendingConversationIDs: Set<UUID> = []
    @State private var showingConversationList = false

    // Calendar 写操作到达手机后，会先挂起在这里等待用户点“确认/取消”。
    @State private var pendingCalendarConfirmation: CalendarWriteConfirmation?
    @State private var calendarConfirmationContinuation:
        CheckedContinuation<Bool, Never>?

    @FocusState private var isInputFocused: Bool
    @AppStorage("vanta.backend.url")
    private var backendURL = "http://192.168.0.10:8000"

    init() {
        let loaded = ChatHistoryStore.load()
        _conversations = State(initialValue: loaded)
        _selectedConversationID = State(
            initialValue: loaded.first!.id
        )
    }

    private var currentIndex: Int? {
        conversations.firstIndex {
            $0.id == selectedConversationID
        }
    }

    private var currentConversation: ChatConversation? {
        guard let currentIndex else { return nil }
        return conversations[currentIndex]
    }

    private var currentMessageCount: Int {
        currentConversation?.messages.count ?? 0
    }

    // 消息数量不会随着 token 增加，所以单独观察最后一条消息文本。
    // 这样流式回答变长时，聊天区也能跟着自动滚到底部。
    private var currentLastMessageText: String {
        currentConversation?.messages.last?.text ?? ""
    }

    private var isCurrentConversationThinking: Bool {
        pendingConversationIDs.contains(selectedConversationID)
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(currentConversation?.messages ?? []) { message in
                        MessageBubble(message: message)
                            .id(message.id)
                    }
                }
                .padding(.vertical)
            }
            .contentShape(Rectangle())
            .scrollDismissesKeyboard(.immediately)
            .onTapGesture {
                isInputFocused = false
            }
            .onChange(of: currentMessageCount) {
                guard let lastID = currentConversation?.messages.last?.id else {
                    return
                }
                withAnimation {
                    proxy.scrollTo(lastID, anchor: .bottom)
                }
            }
            .onChange(of: currentLastMessageText) {
                guard let lastID = currentConversation?.messages.last?.id else {
                    return
                }
                // token 到得很频繁，这里不做动画，避免一边生成一边抖动。
                proxy.scrollTo(lastID, anchor: .bottom)
            }
        }

        .navigationTitle(currentConversation?.title ?? "助手")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    showingConversationList = true
                } label: {
                    Image(systemName: "line.3.horizontal")
                }
                .accessibilityLabel("对话列表")
            }

            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    createConversation()
                } label: {
                    Image(systemName: "square.and.pencil")
                }
                .accessibilityLabel("新建对话")
            }
        }
        .sheet(isPresented: $showingConversationList) {
            ConversationListView(
                conversations: conversations,
                selectedConversationID: selectedConversationID,
                onSelect: selectConversation,
                onCreate: createConversation,
                onDelete: deleteConversation
            )
        }
        .alert(item: $pendingCalendarConfirmation) { confirmation in
            let confirmButton: Alert.Button = confirmation.destructive
                ? .destructive(Text(confirmation.confirmTitle)) {
                    resolveCalendarConfirmation(true)
                }
                : .default(Text(confirmation.confirmTitle)) {
                    resolveCalendarConfirmation(true)
                }

            return Alert(
                title: Text(confirmation.title),
                message: Text(confirmation.message),
                primaryButton: confirmButton,
                secondaryButton: .cancel {
                    resolveCalendarConfirmation(false)
                }
            )
        }
        .safeAreaInset(edge: .bottom) {
            inputBar
        }
    }

    private var inputBar: some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField("给 Vanta 发消息…", text: $input, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...5)
                .focused($isInputFocused)
                .padding(.leading, 16)
                .padding(.vertical, 10)
                .onSubmit(sendMessage)

            Button(action: sendMessage) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 30))
            }
            .padding(.trailing, 10)
            .padding(.bottom, 7)
            .disabled(
                input.trimmingCharacters(
                    in: .whitespacesAndNewlines
                ).isEmpty || isCurrentConversationThinking
            )
        }
        .frame(minHeight: 44)
        .background(Color(uiColor: .secondarySystemBackground))
        .clipShape(
            RoundedRectangle(
                cornerRadius: 22,
                style: .continuous
            )
        )
        .overlay {
            RoundedRectangle(
                cornerRadius: 22,
                style: .continuous
            )
            .stroke(Color.secondary.opacity(0.15), lineWidth: 1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private func createConversation() {
        let conversation = ChatConversation.makeNew()
        conversations.insert(conversation, at: 0)
        selectedConversationID = conversation.id
        input = ""
        showingConversationList = false
        ChatHistoryStore.save(conversations)
    }

    private func selectConversation(_ id: UUID) {
        selectedConversationID = id
        input = ""
        showingConversationList = false
        isInputFocused = false
    }

    private func deleteConversation(_ id: UUID) {
        guard let index = conversations.firstIndex(where: { $0.id == id }) else {
            return
        }

        let threadID = conversations[index].threadID
        conversations.remove(at: index)

        if conversations.isEmpty {
            let replacement = ChatConversation.makeNew()
            conversations = [replacement]
            selectedConversationID = replacement.id
        } else if selectedConversationID == id {
            selectedConversationID = conversations[0].id
        }

        ChatHistoryStore.save(conversations)

        // UI 删除后，再通知后端清掉对应 LangGraph Checkpoint。
        Task {
            try? await VantaAPIClient.deleteThread(
                threadID: threadID,
                baseURL: backendURL
            )
        }
    }

    private func sendMessage() {
        let text = input.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard
            !text.isEmpty,
            !isCurrentConversationThinking,
            let index = currentIndex
        else {
            return
        }

        let conversationID = conversations[index].id
        let threadID = conversations[index].threadID
        let assistantMessageID = UUID()

        conversations[index].messages.append(
            ChatMessage(role: .user, text: text)
        )

        // 先放一个空的助手消息进去。
        // 后面每收到一个 token，都只修改这个气泡，而不是不断新增气泡。
        conversations[index].messages.append(
            ChatMessage(
                id: assistantMessageID,
                role: .assistant,
                text: ""
            )
        )

        if conversations[index].title == "新对话" {
            conversations[index].title = makeTitle(from: text)
        }

        conversations[index].updatedAt = Date()
        input = ""
        pendingConversationIDs.insert(conversationID)
        ChatHistoryStore.save(conversations)

        Task {
            do {
                try await VantaAPIClient.streamChat(
                    message: text,
                    threadID: threadID,
                    baseURL: backendURL,
                    onToken: { delta in
                        guard
                            let latestIndex = conversations.firstIndex(
                                where: { $0.id == conversationID }
                            ),
                            let messageIndex = conversations[latestIndex].messages.firstIndex(
                                where: { $0.id == assistantMessageID }
                            )
                        else {
                            return
                        }

                        // @State 里的 text 一变化，SwiftUI 会自动重绘这个消息气泡。
                        conversations[latestIndex].messages[messageIndex].text += delta
                        conversations[latestIndex].updatedAt = Date()
                    },
                    confirmCalendarWrite: { confirmation in
                        // 这里会真正等待用户点 Alert，再把 Bool 返回给 ToolExecutor。
                        await requestCalendarConfirmation(confirmation)
                    }
                )
            } catch {
                if
                    let latestIndex = conversations.firstIndex(
                        where: { $0.id == conversationID }
                    ),
                    let messageIndex = conversations[latestIndex].messages.firstIndex(
                        where: { $0.id == assistantMessageID }
                    )
                {
                    let hasPartialReply = !conversations[latestIndex]
                        .messages[messageIndex]
                        .text
                        .isEmpty

                    let prefix = hasPartialReply ? "\n\n" : ""
                    conversations[latestIndex].messages[messageIndex].text +=
                        "\(prefix)连接失败：\(error.localizedDescription)"
                }
            }

            // 不要每个 token 都写 UserDefaults，会产生很多无意义磁盘写入。
            // 等这一轮完整结束后再持久化一次即可。
            if let latestIndex = conversations.firstIndex(
                where: { $0.id == conversationID }
            ) {
                conversations[latestIndex].updatedAt = Date()
                ChatHistoryStore.save(conversations)
            }

            pendingConversationIDs.remove(conversationID)
        }
    }

    private func requestCalendarConfirmation(
        _ confirmation: CalendarWriteConfirmation
    ) async -> Bool {
        // withCheckedContinuation 可以把“按钮回调”包装成 async/await。
        // ToolExecutor 会暂停在这里，直到用户明确选择确认或取消。
        await withCheckedContinuation { continuation in
            pendingCalendarConfirmation = confirmation
            calendarConfirmationContinuation = continuation
        }
    }

    private func resolveCalendarConfirmation(_ approved: Bool) {
        let continuation = calendarConfirmationContinuation

        // 先清空状态，再 resume，避免同一个 continuation 被意外恢复两次。
        calendarConfirmationContinuation = nil
        pendingCalendarConfirmation = nil
        continuation?.resume(returning: approved)
    }

    private func makeTitle(from text: String) -> String {
        let oneLine = text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if oneLine.count <= 18 {
            return oneLine
        }

        return String(oneLine.prefix(18)) + "…"
    }
}

private struct MessageBubble: View {
    let message: ChatMessage

    var body: some View {
        HStack {
            if message.role == .user {
                Spacer(minLength: 50)
            }

            Group {
                if message.role == .assistant && message.text.isEmpty {
                    // 刚发出请求但第一个 token 还没回来时，先显示加载状态。
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("Vanta 正在思考…")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text(message.text)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                message.role == .user
                ? Color.accentColor
                : Color.secondary.opacity(0.14)
            )
            .foregroundStyle(
                message.role == .user
                ? Color.white
                : Color.primary
            )
            .clipShape(
                RoundedRectangle(cornerRadius: 18)
            )

            if message.role == .assistant {
                Spacer(minLength: 50)
            }
        }
        .padding(.horizontal)
    }
}

private struct ConversationListView: View {
    let conversations: [ChatConversation]
    let selectedConversationID: UUID
    let onSelect: (UUID) -> Void
    let onCreate: () -> Void
    let onDelete: (UUID) -> Void

    @Environment(\.dismiss) private var dismiss

    private var sortedConversations: [ChatConversation] {
        conversations.sorted {
            $0.updatedAt > $1.updatedAt
        }
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(sortedConversations) { conversation in
                    Button {
                        onSelect(conversation.id)
                    } label: {
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(conversation.title)
                                    .lineLimit(1)

                                Text(
                                    conversation.updatedAt.formatted(
                                        date: .abbreviated,
                                        time: .shortened
                                    )
                                )
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            }

                            Spacer()

                            if conversation.id == selectedConversationID {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .swipeActions {
                        Button(role: .destructive) {
                            onDelete(conversation.id)
                        } label: {
                            Label("删除", systemImage: "trash")
                        }
                    }
                }
            }
            .navigationTitle("对话")

            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("完成") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: onCreate) {
                        Image(systemName: "square.and.pencil")
                    }
                    .accessibilityLabel("新建对话")
                }
            }
        }
    }
}

#Preview {
    NavigationStack {
        AssistantView()
    }
}
