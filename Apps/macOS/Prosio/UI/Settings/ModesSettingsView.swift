import ProsioCore
import SwiftUI

/// P1 modes: Translate, "adapt writing to the app" (+ per-app scene overrides), and the Ask key.
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

            Section("Ask Key") {
                Picker("Ask key", selection: $settings.askTriggerKey) {
                    ForEach(TriggerKey.allCases, id: \.self) { key in
                        Text(key.displayName).tag(key)
                    }
                }
                if settings.askTriggerKey == settings.triggerKey {
                    Label("Must be different from the dictation key.", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                } else {
                    Text("Press \(settings.askTriggerKey.shortSymbol) to ask a question instead of dictating; the answer streams into a card you can insert or copy.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
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
