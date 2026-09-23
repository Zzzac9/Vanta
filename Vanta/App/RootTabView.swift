import SwiftUI

struct RootTabView: View {
    @State private var selection: AppTab = .assistant

    var body: some View {
        TabView(selection: $selection) {
            Tab("助手", systemImage: "sparkles", value: .assistant) {
                NavigationStack {
                    AssistantView()
                }
            }

            Tab("记忆", systemImage: "brain.head.profile", value: .memory) {
                NavigationStack {
                    MemoryView()
                }
            }

            Tab("设置", systemImage: "gearshape", value: .settings) {
                NavigationStack {
                    SettingsView()
                }
            }
        }
    }
}

private enum AppTab: Hashable {
    case assistant
    case memory
    case settings
}

#Preview {
    RootTabView()
}

