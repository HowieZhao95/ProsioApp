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
                Text("Hold \(environment.settings.triggerKey.shortSymbol) to dictate · tap to toggle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
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
