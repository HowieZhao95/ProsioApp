import AppKit
import ProsioCore
import SwiftUI

/// Menu bar popover. Owned by mac-ui agent. INIT SIGNATURE FROZEN.
struct MenuBarContentView: View {
    let environment: AppEnvironment

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            historyList
            Divider()
            footer
        }
        .frame(width: 300)
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "waveform")
                    .foregroundStyle(statusTint)
                Text("Prosio")
                    .font(.headline)
                Spacer()
                Text(statusText)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(statusTint)
            }
            if !environment.permissions.allRequiredGranted {
                Button("Grant permissions…") { environment.showOnboarding() }
                    .buttonStyle(.link)
                    .font(.caption)
            } else {
                Text("\(environment.settings.triggerKey.shortSymbol) to talk — ask, translate or dictate")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            translateToggleLine
            hotkeyStatusLine
            signInStatusLine
        }
        .padding(12)
    }

    // MARK: - Translate quick toggle (P1)

    private var translateToggleLine: some View {
        HStack(spacing: 6) {
            Toggle(isOn: translateEnabledBinding) {
                HStack(spacing: 4) {
                    Image(systemName: "globe")
                    Text("Translate")
                }
                .font(.caption)
            }
            .toggleStyle(.switch)
            .controlSize(.mini)

            if environment.settings.translateEnabled {
                Text("→ \(TranslateLanguages.shortCode(for: environment.settings.translateTarget))")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
    }

    private var translateEnabledBinding: Binding<Bool> {
        Binding(
            get: { environment.settings.translateEnabled },
            set: { environment.settings.translateEnabled = $0 }
        )
    }

    // MARK: - Hotkey / sign-in status (mac-system: HotkeyStatus, isSignedIn)

    @ViewBuilder
    private var hotkeyStatusLine: some View {
        switch environment.hotkeyStatus {
        case .ready:
            EmptyView()
        case .missingAccessibility:
            statusLine("Accessibility is off — the hotkey can't work.", buttonTitle: "Open Settings") {
                environment.permissions.openSystemSettings(for: .accessibility)
            }
        case .tapDisabled:
            Text("Hotkey temporarily disabled — recovering…")
                .font(.caption2)
                .foregroundStyle(.orange)
        case .fnKeyConflict:
            statusLine("\u{1F310} is set to start macOS Dictation, not Prosio.", buttonTitle: "Open Keyboard Settings") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.keyboard") {
                    NSWorkspace.shared.open(url)
                }
            }
        }
    }

    @ViewBuilder
    private var signInStatusLine: some View {
        if !environment.isSignedIn {
            HStack(spacing: 6) {
                Text("Not signed in — cloud polishing off")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                SettingsLink {
                    Text("Sign in")
                }
                .buttonStyle(.link)
                .font(.caption2)
            }
        }
    }

    private func statusLine(_ message: String, buttonTitle: String, action: @escaping () -> Void) -> some View {
        HStack(spacing: 6) {
            Text(message)
                .font(.caption2)
                .foregroundStyle(.orange)
            Button(buttonTitle, action: action)
                .buttonStyle(.link)
                .font(.caption2)
        }
    }

    private var statusText: String {
        if !environment.permissions.allRequiredGranted { return "Permissions needed" }
        return environment.controller.isBusy ? "Listening…" : "Ready"
    }

    private var statusTint: Color {
        if !environment.permissions.allRequiredGranted { return .orange }
        return environment.controller.isBusy ? .pink : .secondary
    }

    // MARK: - History

    private var historyList: some View {
        Group {
            let recent = Array(environment.history.items.prefix(5))
            if recent.isEmpty {
                Text("No dictations yet")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(12)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(recent) { item in
                        MenuBarHistoryRow(item: item) { copy(item) }
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    private func copy(_ item: HistoryItem) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(item.text, forType: .string)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 14) {
            SettingsLink {
                Text("Settings…")
            }
            .buttonStyle(.plain)

            #if DEBUG
            Button("HUD Showcase") { environment.hud?.showcase() }
                .buttonStyle(.plain)
            #endif

            Spacer()

            Button("Quit") { NSApp.terminate(nil) }
                .buttonStyle(.plain)
        }
        .font(.callout)
        .padding(12)
    }
}

private struct MenuBarHistoryRow: View {
    let item: HistoryItem
    var onTap: () -> Void

    private static let formatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 1) {
                Text(item.text)
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(.primary)
                HStack(spacing: 4) {
                    if let appName = item.appName {
                        Text(appName)
                    }
                    Text(Self.formatter.localizedString(for: item.createdAt, relativeTo: .now))
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
    }
}

#if DEBUG
#Preview {
    MenuBarContentView(environment: AppEnvironment())
}
#endif
