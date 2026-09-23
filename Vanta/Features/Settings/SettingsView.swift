import SwiftUI

struct SettingsView: View {
    @AppStorage("vanta.backend.url") private var backendURL = "http://192.168.0.10:8000"
    @AppStorage("vanta.user.name") private var userName = ""

    var body: some View {
        Form {
            Section("个人信息") {
                TextField("你的称呼", text: $userName)
            }

            Section {
                TextField("后端地址", text: $backendURL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            } header: {
                Text("连接")
            } footer: {
                Text("真机请填写 Mac 的局域网地址，例如 http://192.168.1.23:8000。")
            }

            Section("关于") {
                LabeledContent("应用", value: "Vanta")
                LabeledContent("版本", value: "1.0")
                LabeledContent("运行模式", value: "Mac FastAPI")
            }
        }
        .navigationTitle("设置")
    }
}

#Preview {
    NavigationStack {
        SettingsView()
    }
}
