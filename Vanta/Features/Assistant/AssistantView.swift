import SwiftUI
import Foundation

struct AssistantView: View {
    @State private var messages: [ChatMessage] = [
        ChatMessage(role: .assistant, text: "你好，我是 Vanta。现在已经连接到你的 Mac 后端。")
    ]
    @State private var input = ""
    @State private var isThinking = false
    @FocusState private var isInputFocused: Bool
    @AppStorage("vanta.backend.url") private var backendURL = "http://192.168.0.10:8000"
    // threadID 会持久化在本机；同一个 ID 对应 LangGraph 中同一段短期会话。
    @AppStorage("vanta.chat.thread_id") private var threadID = UUID().uuidString

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(messages) { message in
                        MessageBubble(message: message)
                            .id(message.id)
                    }

                    if isThinking {
                        HStack {
                            ProgressView()
                            Text("Vanta 正在思考…")
                                .foregroundStyle(.secondary)
                            Spacer()
                        }
                        .padding(.horizontal)
                    }
                }
                .padding(.vertical)
            }
            .contentShape(Rectangle())
            .scrollDismissesKeyboard(.immediately)
            .onTapGesture {
                isInputFocused = false
            }
            .onChange(of: messages.count) {
                guard let lastID = messages.last?.id else { return }
                withAnimation {
                    proxy.scrollTo(lastID, anchor: .bottom)
                }
            }
        }
        .navigationTitle("助手")
        .toolbar {
            if messages.count > 1 {
                Button("清空") {
                    // 清空 UI 的同时更换 threadID，避免后端继续带入上一段会话历史。
                    threadID = UUID().uuidString
                    messages = [ChatMessage(role: .assistant, text: "对话已清空。有什么想让我做的吗？")]
                }
            }
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
            .disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isThinking)
        }
        .frame(minHeight: 44)
        .background(Color(uiColor: .secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(Color.secondary.opacity(0.15), lineWidth: 1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private func sendMessage() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isThinking else { return }

        messages.append(ChatMessage(role: .user, text: text))
        input = ""
        isThinking = true

        // 网络请求异步执行；等待后端时界面仍然可以正常响应。
        Task {
            do {
                let reply = try await VantaAPIClient.chat(
                    message: text,
                    threadID: threadID,
                    baseURL: backendURL
                )
                messages.append(ChatMessage(role: .assistant, text: reply))
            } catch {
                messages.append(ChatMessage(
                    role: .assistant,
                    text: "连接失败：\(error.localizedDescription)\n\n请确认 Mac 后端正在运行，并检查“设置”里的后端地址。"
                ))
            }
            isThinking = false
        }
    }
}

private struct ChatMessage: Identifiable {
    enum Role {
        case user
        case assistant
    }

    let id = UUID()
    let role: Role
    let text: String
}

private struct MessageBubble: View {
    let message: ChatMessage

    var body: some View {
        HStack {
            if message.role == .user {
                Spacer(minLength: 50)
            }

            Text(message.text)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(message.role == .user ? Color.accentColor : Color.secondary.opacity(0.14))
                .foregroundStyle(message.role == .user ? Color.white : Color.primary)
                .clipShape(RoundedRectangle(cornerRadius: 18))

            if message.role == .assistant {
                Spacer(minLength: 50)
            }
        }
        .padding(.horizontal)
    }
}

#Preview {
    NavigationStack {
        AssistantView()
    }
}
