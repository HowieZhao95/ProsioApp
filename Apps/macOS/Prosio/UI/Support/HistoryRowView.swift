import AppKit
import ProsioCore
import SwiftUI

/// One history entry, shared by the menu bar popover's "Recent" list and Settings ▸ History —
/// same row design in both places, per the Settings audit. Click anywhere copies the full text
/// (green checkmark for 1.2s); hover reveals a trailing copy icon; context menu adds Copy What I
/// Said (only when the compose step actually changed the text) and Delete.
struct HistoryRowView: View {
    let item: HistoryItem
    var onCopy: () -> Void
    var onCopyTranscript: () -> Void
    var onDelete: () -> Void

    @State private var isHovering = false
    @State private var justCopied = false

    private static let formatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    var body: some View {
        Button(action: performCopy) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(flattenedPreview)
                        .font(.system(size: 12))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .truncationMode(.tail)
                    HStack(spacing: 4) {
                        if let name = meaningfulAppName {
                            if let icon = appIcon {
                                Image(nsImage: icon)
                                    .resizable()
                                    .frame(width: 14, height: 14)
                            }
                            Text(name)
                        }
                        Text(Self.formatter.localizedString(for: item.createdAt, relativeTo: .now))
                        if let badge = modeBadge {
                            Text(badge)
                        }
                    }
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                trailingAffordance
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background(isHovering ? Color.primary.opacity(0.06) : .clear)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .contextMenu {
            Button("Copy", action: onCopy)
            if showsCopyTranscript {
                Button("Copy What I Said", action: onCopyTranscript)
            }
            Button("Delete", role: .destructive, action: onDelete)
        }
    }

    @ViewBuilder
    private var trailingAffordance: some View {
        if justCopied {
            Image(systemName: "checkmark")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.green)
                .accessibilityLabel("Copied")
        } else if isHovering {
            Image(systemName: "doc.on.doc")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .accessibilityLabel("Copy")
        }
    }

    private func performCopy() {
        onCopy()
        withAnimation(.easeOut(duration: 0.15)) { justCopied = true }
        Task {
            try? await Task.sleep(for: .seconds(1.2))
            withAnimation(.easeOut(duration: 0.15)) { justCopied = false }
        }
    }

    /// Only meaningful when the compose step actually changed the text (edit/write/translate) —
    /// scene-adapted-only or plain dictation has `transcript == nil` or `transcript == text`.
    private var showsCopyTranscript: Bool {
        guard let transcript = item.transcript else { return false }
        return transcript != item.text
    }

    private var meaningfulAppName: String? {
        guard let name = item.appName, !name.isEmpty else { return nil }
        let lowered = name.lowercased()
        if lowered == "loginwindow" { return nil }
        if item.appBundleID == "app.prosio.mac" || lowered == "prosio" { return nil }
        return name
    }

    /// Only looked up (and only shown) once the app name itself is meaningful — no point showing
    /// a blank/generic icon next to a hidden name, and no point resolving one `NSWorkspace` never
    /// has a URL for anyway.
    private var appIcon: NSImage? {
        guard meaningfulAppName != nil else { return nil }
        return AppIconCache.icon(for: item.appBundleID)
    }

    /// Collapses the preview to real content: blank lines dropped, each remaining line's leading
    /// list marker ("- "/"* "/"+ "/"1. ") stripped, then joined with a single space — so a
    /// Markdown list like "老王：\n\n- 我下周请三天假\n- 工作已经交接给小李了" reads as one flowing
    /// line instead of "老王：" followed by visible blank space.
    private var flattenedPreview: String {
        item.text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .map(Self.stripListMarker)
            .joined(separator: " ")
    }

    private static func stripListMarker(_ line: String) -> String {
        for bullet in ["- ", "* ", "+ "] {
            if line.hasPrefix(bullet) { return String(line.dropFirst(bullet.count)) }
        }
        guard let dotIndex = line.firstIndex(of: "."), line.distance(from: line.startIndex, to: dotIndex) <= 3 else { return line }
        let prefix = line[line.startIndex..<dotIndex]
        guard !prefix.isEmpty, prefix.allSatisfy(\.isNumber) else { return line }
        let afterDot = line.index(after: dotIndex)
        guard afterDot < line.endIndex, line[afterDot] == " " else { return line }
        return String(line[line.index(after: afterDot)...])
    }

    /// Edit/Ask/Write get the same emoji as the capsule's mode chip. Translate has no reliable
    /// per-item signal on `HistoryItem` — `DictationIntent` has no `.translate` case (a
    /// translate-classified session still reports `.dictate`, see `Contracts.swift`) — so it's
    /// omitted here rather than guessed.
    private var modeBadge: String? {
        switch item.intent {
        case .edit: "✏️"
        case .ask: "✨"
        case .write: "✍️"
        case .dictate, nil: nil
        }
    }
}

/// Tiny memoizing cache — `NSWorkspace` app-icon lookups are cheap once resolved but there's no
/// reason to repeat them on every row re-render.
enum AppIconCache {
    private static var cache: [String: NSImage] = [:]

    static func icon(for bundleID: String?) -> NSImage? {
        guard let bundleID else { return nil }
        if let cached = cache[bundleID] { return cached }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        cache[bundleID] = icon
        return icon
    }
}

#if DEBUG
#Preview {
    VStack(spacing: 0) {
        HistoryRowView(
            item: HistoryItem(text: "Let's meet Thursday at 3pm instead", appBundleID: "com.apple.Notes", appName: "Notes", engineID: "x", durationSeconds: 3, insertion: .pasted),
            onCopy: {}, onCopyTranscript: {}, onDelete: {}
        )
        HistoryRowView(
            item: HistoryItem(text: "老王：\n\n- 我下周请三天假，工作已经交接给小李了。\n- 谢谢！", appBundleID: "com.apple.MobileSMS", appName: "Messages", engineID: "x", durationSeconds: 3, insertion: .pasted, intent: .write, transcript: "帮我回复老王说下周请三天假"),
            onCopy: {}, onCopyTranscript: {}, onDelete: {}
        )
    }
    .frame(width: 320)
}
#endif
