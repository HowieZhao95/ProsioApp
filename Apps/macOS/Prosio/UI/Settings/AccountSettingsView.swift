import ProsioCore
import SwiftUI

/// Cloud provider keys. Secrets stay in the Keychain; model names stay in settings.
struct AccountSettingsView: View {
    let environment: AppEnvironment
    @Bindable private var settings: AppSettings

    init(environment: AppEnvironment) {
        self.environment = environment
        self.settings = environment.settings
    }

    @State private var openRouterKey = ""
    @State private var sonioxKey = ""
    @State private var openRouterStatus: String?
    @State private var sonioxStatus: String?
    @State private var checkingOpenRouter = false
    @State private var checkingSoniox = false

    var body: some View {
        Form {
            Section {
                Text("软件免费。填写后，听写润色和会议增强按你自己的账单计费。不填写时，本机听写和本地会议稿仍然可用。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section("OpenRouter") {
                SecureField("OpenRouter Key", text: $openRouterKey)
                    .textFieldStyle(.roundedBorder)
                TextField("转写模型", text: $settings.transcriptionModel)
                    .textFieldStyle(.roundedBorder)
                TextField("写作模型", text: $settings.composeModel)
                    .textFieldStyle(.roundedBorder)
                TextField("备用写作模型", text: $settings.composeFallbackModel)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Link("获取 OpenRouter Key", destination: OpenRouterClient.openRouterKeysURL)
                    Spacer()
                    Button(checkingOpenRouter ? "测试中…" : "测试连接") { testOpenRouter() }
                        .disabled(checkingOpenRouter || openRouterKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button("保存") { save(.openRouter, openRouterKey) }
                }
                if let openRouterStatus {
                    Text(openRouterStatus).font(.caption).foregroundStyle(.secondary)
                }
            }

            Section("Soniox") {
                SecureField("Soniox Key", text: $sonioxKey)
                    .textFieldStyle(.roundedBorder)
                Text("用于会议增强。Key 需要异步转写和文件上传权限。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Link("获取 Soniox Key", destination: SonioxClient.consoleURL)
                    Spacer()
                    Button(checkingSoniox ? "测试中…" : "测试连接") { testSoniox() }
                        .disabled(checkingSoniox || sonioxKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button("保存") { save(.soniox, sonioxKey) }
                }
                if let sonioxStatus {
                    Text(sonioxStatus).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            openRouterKey = KeychainStore.load(.openRouter) ?? ""
            sonioxKey = KeychainStore.load(.soniox) ?? ""
        }
    }

    private func save(_ account: ProviderCredential, _ secret: String) {
        environment.saveProviderKey(secret, account: account)
        if account == .openRouter { openRouterStatus = secret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "已清除 OpenRouter Key。" : "已保存 OpenRouter Key。" }
        else { sonioxStatus = secret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "已清除 Soniox Key。" : "已保存 Soniox Key。" }
    }

    private func testOpenRouter() {
        let secret = openRouterKey.trimmingCharacters(in: .whitespacesAndNewlines)
        checkingOpenRouter = true
        Task {
            let message = await environment.openRouter.testKey(secret)
            checkingOpenRouter = false
            openRouterStatus = message
        }
    }

    private func testSoniox() {
        let secret = sonioxKey.trimmingCharacters(in: .whitespacesAndNewlines)
        checkingSoniox = true
        Task {
            let message = await environment.soniox.testKey(secret)
            checkingSoniox = false
            sonioxStatus = message
        }
    }
}

#if DEBUG
#Preview {
    AccountSettingsView(environment: AppEnvironment())
}
#endif
