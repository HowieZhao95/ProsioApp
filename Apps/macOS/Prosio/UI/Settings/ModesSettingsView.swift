import ProsioCore
import SwiftUI

/// P1 modes: Translate, "adapt writing to the app" (+ per-app scene overrides), and how Ask/Edit/
/// Translate are actually triggered. P1.1: there's only ever one hotkey (dictation, fn by
/// default), and no fixed trigger words either — a semantic classifier infers what the user wants
/// from what they actually said, in any language, once they stop speaking.
struct ModesSettingsView: View {
    let environment: AppEnvironment
    @Bindable private var settings: AppSettings

    init(environment: AppEnvironment) {
        self.environment = environment
        self.settings = environment.settings
    }

    var body: some View {
        Form {
            Section("Translate") {
                Toggle("Translate while dictating", isOn: $settings.translateEnabled)
                Picker("Target language", selection: $settings.translateTarget) {
                    ForEach(TranslateLanguages.all) { language in
                        Text(language.name).tag(language.code)
                    }
                }
                .disabled(!settings.translateEnabled)
                Text("Everything you dictate is translated into the target language before it's inserted. There's a quick on/off toggle in the menu bar too.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Writing Style") {
                Toggle("Adapt writing to the app", isOn: $settings.adaptToApp)
                Text("Lightly adjusts tone and formatting for where you're typing — an email reads differently than a chat message, code comment, or document.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                perAppOverrides
            }

            Section("Voice Commands") {
                Text("Just say what you want — Prosio figures out whether to type it, answer it, or translate it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                voiceCommandRow(example: "“What's the capital of Portugal?”", mode: "Ask", detail: "streams an answer into a card you can insert or copy.")
                voiceCommandRow(example: "“帮我翻成日语：明天见”", mode: "Translate", detail: "types the Japanese translation for this one utterance.")
                voiceCommandRow(example: "select text, then “shorter please”", mode: "Edit", detail: "rewrites the selection to match the instruction.")
                voiceCommandRow(example: "“你明天有空吗？”", mode: "Dictate", detail: "typed as-is — it's a question to someone else, not to Prosio.")
                Text("Press \(settings.triggerKey.shortSymbol) again while the answer card is open to ask a follow-up.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func voiceCommandRow(example: String, mode: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(example)
                    .font(.system(size: 12, weight: .medium))
                Image(systemName: "arrow.right")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Text(mode)
                    .font(.system(size: 12, weight: .semibold))
            }
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    // MARK: - Per-app scene overrides

    private struct OverrideRow: Identifiable {
        let bundleID: String
        let appName: String
        var id: String { bundleID }
    }

    @ViewBuilder
    private var perAppOverrides: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !overrideRows.isEmpty {
                ForEach(overrideRows) { row in
                    HStack {
                        Text(row.appName)
                            .font(.callout)
                        Spacer()
                        ScenePicker(selection: sceneBinding(for: row.bundleID))
                        Button {
                            settings.sceneOverrides.removeValue(forKey: row.bundleID)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                    }
                }
            }

            Menu {
                if addableApps.isEmpty {
                    Text("No recent apps yet")
                } else {
                    ForEach(addableApps) { app in
                        Button(app.appName) {
                            settings.sceneOverrides[app.bundleID] = .general
                        }
                    }
                }
            } label: {
                Label("Add App…", systemImage: "plus")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .font(.caption)
        }
        .padding(.top, 4)
    }

    private var overrideRows: [OverrideRow] {
        settings.sceneOverrides.keys.sorted().map { OverrideRow(bundleID: $0, appName: appName(for: $0)) }
    }

    private var addableApps: [OverrideRow] {
        var seen = Set(settings.sceneOverrides.keys)
        var result: [OverrideRow] = []
        for item in environment.history.items {
            guard let bundleID = item.appBundleID, !seen.contains(bundleID) else { continue }
            seen.insert(bundleID)
            result.append(OverrideRow(bundleID: bundleID, appName: item.appName ?? bundleID))
        }
        return result
    }

    private func appName(for bundleID: String) -> String {
        environment.history.items.first(where: { $0.appBundleID == bundleID })?.appName ?? bundleID
    }

    private func sceneBinding(for bundleID: String) -> Binding<WritingScene?> {
        Binding(
            get: { settings.sceneOverrides[bundleID] },
            set: { newValue in
                if let newValue {
                    settings.sceneOverrides[bundleID] = newValue
                } else {
                    settings.sceneOverrides.removeValue(forKey: bundleID)
                }
            }
        )
    }
}

/// "Automatic" (nil — no override, the classifier decides) plus the five fixed `WritingScene`s.
private struct ScenePicker: View {
    @Binding var selection: WritingScene?

    private static let automaticTag = "automatic"

    var body: some View {
        Picker(
            "",
            selection: Binding(
                get: { selection?.rawValue ?? Self.automaticTag },
                set: { raw in selection = raw == Self.automaticTag ? nil : WritingScene(rawValue: raw) }
            )
        ) {
            Text("Automatic").tag(Self.automaticTag)
            ForEach(WritingScene.allCases, id: \.self) { scene in
                Text(name(for: scene)).tag(scene.rawValue)
            }
        }
        .labelsHidden()
        .frame(width: 140)
    }

    private func name(for scene: WritingScene) -> String {
        switch scene {
        case .general: "General"
        case .email: "Email"
        case .chat: "Chat"
        case .code: "Code"
        case .document: "Document"
        }
    }
}

#if DEBUG
#Preview {
    ModesSettingsView(environment: AppEnvironment())
        .frame(width: 620, height: 460)
}
#endif
