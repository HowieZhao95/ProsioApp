import ProsioCore
import SwiftUI

struct GeneralSettingsView: View {
    let environment: AppEnvironment
    @Bindable private var settings: AppSettings

    init(environment: AppEnvironment) {
        self.environment = environment
        self.settings = environment.settings
    }

    private let availableLanguages: [(code: String, name: String)] = [
        ("en-US", "English (US)"),
        ("zh-CN", "Chinese (Simplified)"),
        ("zh-TW", "Chinese (Traditional)"),
        ("ja-JP", "Japanese"),
        ("es-ES", "Spanish"),
        ("fr-FR", "French"),
        ("de-DE", "German"),
    ]

    var body: some View {
        Form {
            Section("Dictation Key") {
                Picker("Trigger key", selection: $settings.triggerKey) {
                    ForEach(TriggerKey.allCases, id: \.self) { key in
                        Text(key.displayName).tag(key)
                    }
                }
                Text("Hold to dictate while speaking, or tap once to toggle continuous dictation.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Engine") {
                Picker("Transcription engine", selection: $settings.enginePreference) {
                    Text("Auto").tag(EnginePreference.auto)
                    Text("Cloud").tag(EnginePreference.cloud)
                    Text("On-device").tag(EnginePreference.local)
                }
                .pickerStyle(.segmented)
                Text(engineDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Language Hints") {
                LanguageHintPicker(selection: $settings.languageHints, available: availableLanguages)
            }

            Section("Appearance") {
                Toggle("Show edge glow while dictating", isOn: $settings.showEdgeGlow)
            }

            Section("Insertion") {
                Toggle("Restore clipboard after pasting", isOn: $settings.restoreClipboard)
            }

            Section("Startup") {
                Toggle("Launch at login", isOn: launchAtLoginBinding)
            }
        }
        .formStyle(.grouped)
    }

    private var engineDescription: String {
        switch settings.enginePreference {
        case .auto: "Uses the cloud model, falling back to on-device recognition when offline."
        case .cloud: "Always uses the cloud model. Requires an internet connection and sign-in."
        case .local: "Always transcribes on-device. Works offline, no account needed."
        }
    }

    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { environment.launchAtLogin },
            set: { environment.launchAtLogin = $0 }
        )
    }
}

private struct LanguageHintPicker: View {
    @Binding var selection: [String]
    let available: [(code: String, name: String)]

    private let columns = [GridItem(.adaptive(minimum: 140), spacing: 8, alignment: .leading)]

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
            ForEach(available, id: \.code) { lang in
                Toggle(isOn: binding(for: lang.code)) {
                    Text(lang.name)
                        .font(.callout)
                }
                .toggleStyle(.button)
            }
        }
    }

    private func binding(for code: String) -> Binding<Bool> {
        Binding(
            get: { selection.contains(code) },
            set: { isOn in
                if isOn {
                    if !selection.contains(code) { selection.append(code) }
                } else {
                    selection.removeAll { $0 == code }
                }
            }
        )
    }
}

#if DEBUG
#Preview {
    GeneralSettingsView(environment: AppEnvironment())
        .frame(width: 620, height: 460)
}
#endif
