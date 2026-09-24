import SwiftUI
import Foundation

struct MemoryView: View {
    @State private var memories: [RemoteMemory] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @AppStorage("vanta.backend.url")
    private var backendURL = "http://192.168.0.10:8000"

    var body: some View {
        Group {
            if isLoading && memories.isEmpty {
                ProgressView("正在读取长期记忆…")
            } else if let errorMessage, memories.isEmpty {
                ContentUnavailableView(
                    "无法读取记忆",
                    systemImage: "exclamationmark.triangle",
                    description: Text(errorMessage)
                )
            } else if memories.isEmpty {
                ContentUnavailableView(
                    "暂无长期记忆",
                    systemImage: "brain.head.profile",
                    description: Text(
                        "在聊天中让 Vanta“记住”某件事后，会显示在这里。"
                    )
                )
            } else {
                memoryList
            }
        }
        .navigationTitle("记忆")
        .toolbar {
            Button {
                Task {
                    await loadMemories()
                }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .accessibilityLabel("刷新")
        }
        .task {
            await loadMemories()
        }
    }

    private var memoryList: some View {
        List {
            ForEach(memories) { memory in
                VStack(alignment: .leading, spacing: 6) {
                    Text(memory.content)

                    Text(formattedDate(memory.createdAt))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
                .swipeActions {
                    Button(role: .destructive) {
                        deleteMemory(memory)
                    } label: {
                        Label("删除", systemImage: "trash")
                    }
                }
            }
        }
        .refreshable {
            await loadMemories()
        }
    }

    private func loadMemories() async {
        isLoading = true
        errorMessage = nil

        do {
            memories = try await VantaAPIClient.fetchMemories(
                baseURL: backendURL
            )
        } catch {
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }

    private func deleteMemory(_ memory: RemoteMemory) {
        memories.removeAll { $0.id == memory.id }

        Task {
            do {
                try await VantaAPIClient.deleteMemory(
                    id: memory.id,
                    baseURL: backendURL
                )
            } catch {
                errorMessage = error.localizedDescription
                await loadMemories()
            }
        }
    }

    private func formattedDate(_ value: String) -> String {
        guard let date = ISO8601DateFormatter().date(from: value) else {
            return value
        }

        return date.formatted(
            date: .abbreviated,
            time: .shortened
        )
    }
}

#Preview {
    NavigationStack {
        MemoryView()
    }
}
