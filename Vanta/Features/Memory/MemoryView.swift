import SwiftUI
import Foundation

struct MemoryView: View {
    @State private var memories: [MemoryItem] = MemoryStore.load()
    @State private var newMemory = ""

    var body: some View {
        List {
            if memories.isEmpty {
                ContentUnavailableView(
                    "暂无记忆",
                    systemImage: "brain.head.profile",
                    description: Text("你可以先手动添加一些信息，之后会由 Vanta 自动管理长期记忆。")
                )
            } else {
                ForEach(memories) { memory in
                    VStack(alignment: .leading, spacing: 5) {
                        Text(memory.text)
                        Text(memory.createdAt.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 3)
                }
                .onDelete(perform: deleteMemories)
            }
        }
        .navigationTitle("记忆")
        .toolbar {
            EditButton()
        }
        .safeAreaInset(edge: .bottom) {
            HStack(spacing: 10) {
                TextField("添加一条记忆…", text: $newMemory)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(addMemory)

                Button(action: addMemory) {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 28))
                }
                .disabled(newMemory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            .background(.bar)
        }
    }

    private func addMemory() {
        let text = newMemory.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        memories.insert(MemoryItem(text: text, createdAt: Date()), at: 0)
        newMemory = ""
        MemoryStore.save(memories)
    }

    private func deleteMemories(at offsets: IndexSet) {
        memories.remove(atOffsets: offsets)
        MemoryStore.save(memories)
    }
}

private struct MemoryItem: Identifiable, Codable {
    let id: UUID
    let text: String
    let createdAt: Date

    init(id: UUID = UUID(), text: String, createdAt: Date) {
        self.id = id
        self.text = text
        self.createdAt = createdAt
    }
}

private enum MemoryStore {
    static let key = "vanta.local.memories"

    static func load() -> [MemoryItem] {
        guard
            let data = UserDefaults.standard.data(forKey: key),
            let items = try? JSONDecoder().decode([MemoryItem].self, from: data)
        else {
            return []
        }
        return items
    }

    static func save(_ items: [MemoryItem]) {
        guard let data = try? JSONEncoder().encode(items) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}

#Preview {
    NavigationStack {
        MemoryView()
    }
}
