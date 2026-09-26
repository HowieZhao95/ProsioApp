import AppKit
import ProsioCore
import SwiftUI

/// Menu bar popover. Owned by mac-ui agent. INIT SIGNATURE FROZEN.
///
/// Native, calm macOS 26 style, ~320pt wide, SF Symbols only (mode badges are the one exception —
/// they mirror the capsule's own emoji chips so the two stay visually consistent). Strings are
/// plain literals so they're picked up by `Resources/Localizable.xcstrings` (en + zh-Hans)
/// automatically — no explicit table/bundle needed.
struct MenuBarContentView: View {
    let environment: AppEnvironment

    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    permissionsBanner
                    hotkeyStatusLine
                    HowToUseSection(triggerKeySymbol: environment.settings.triggerKey.shortSymbol)
                        .environment(\.howToUseDefaultExpanded, environment.history.items.count < 10)
                    Divider().padding(.leading, 14)
                    TranslateRow(
                        enabled: Binding(
                            get: { environment.settings.translateEnabled },
                            set: { environment.settings.translateEnabled = $0 }
                        ),
                        target: Binding(
                            get: { environment.settings.translateTarget },
                            set: { environment.settings.translateTarget = $0 }
                        )
                    )
                    AccountRow(isSignedIn: environment.isSignedIn)
                    Divider().padding(.leading, 14)
                    RecentHistorySection(
                        items: Array(environment.history.items.prefix(8)),
                        hasMore: environment.history.items.count > 8,
                        onCopy: { copy($0) },
                        onCopyTranscript: { copy($0, useTranscript: true) },
                        onDelete: { try? environment.history.delete(id: $0.id) },
                        onClearAll: { try? environment.history.clear() },
                        onShowAll: {
                            NotificationCenter.default.post(name: .prosioOpenSettingsHistoryTab, object: nil)
                            openSettings()
                        }
                    )
                }
            }
            Divider()
            footer
        }
        .frame(width: 320)
        // The header/footer are OUTSIDE the ScrollView so they're always visible; this caps the
        // WHOLE popover (not just the scrolling middle) to the screen's actual available height —
        // without it, on a screen with little vertical room (e.g. a fullscreen app active, popover
        // anchored near y=0) AppKit can end up clipping from the top, hiding the header entirely
        // rather than just scrolling the middle section as intended.
        .frame(maxHeight: maxPopoverHeight)
    }

    private var maxPopoverHeight: CGFloat {
        let screenHeight = NSScreen.main?.visibleFrame.height ?? 560
        return min(560, screenHeight - 40)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "waveform")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.secondary)
            Text("Prosio")
                .font(.system(size: 13, weight: .semibold))
            Spacer()
            StatusPill(state: pillState)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var pillState: MenuBarPillState {
        if !environment.permissions.allRequiredGranted { return .permissionsNeeded }
        switch environment.controller.phase {
        case .listening: return .listening
        case .finalizing, .composing, .inserting: return .working
        case .answering: return .answerReady
        default: return .ready
        }
    }

    @ViewBuilder
    private var permissionsBanner: some View {
        if !environment.permissions.allRequiredGranted {
            Button("Grant permissions…") { environment.showOnboarding() }
                .buttonStyle(.link)
                .font(.system(size: 11))
                .padding(.horizontal, 14)
                .padding(.top, 2)
        }
    }

    // MARK: - Hotkey status (mac-system: HotkeyStatus)

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
                .font(.system(size: 11))
                .foregroundStyle(.orange)
                .padding(.horizontal, 14)
                .padding(.top, 2)
        case .fnKeyConflict:
            statusLine("\u{1F310} is set to start macOS Dictation, not Prosio.", buttonTitle: "Open Keyboard Settings") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.keyboard") {
                    NSWorkspace.shared.open(url)
                }
            }
        }
    }

    private func statusLine(_ message: String, buttonTitle: String, action: @escaping () -> Void) -> some View {
        HStack(spacing: 6) {
            Text(message)
                .font(.system(size: 11))
                .foregroundStyle(.orange)
            Button(buttonTitle, action: action)
                .buttonStyle(.link)
                .font(.system(size: 11))
        }
        .padding(.horizontal, 14)
        .padding(.top, 2)
    }

    // MARK: - Actions

    private func copy(_ item: HistoryItem, useTranscript: Bool = false) {
        let text = (useTranscript ? item.transcript : nil) ?? item.text
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 14) {
            SettingsLink {
                Text("Settings…")
            }
            .buttonStyle(.plain)
            .keyboardShortcut(",", modifiers: .command)

            #if DEBUG
            Menu("Debug") {
                Button("HUD Showcase") { environment.hud?.showcase() }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            #endif

            Spacer()

            Button("Quit Prosio") { NSApp.terminate(nil) }
                .buttonStyle(.plain)
                .keyboardShortcut("q", modifiers: .command)
        }
        .font(.system(size: 12))
        .padding(12)
    }
}

// MARK: - Status pill

enum MenuBarPillState: Equatable {
    case ready
    case listening
    case working
    case answerReady
    case permissionsNeeded
}

/// Header status pill. Only `.listening` (and `.permissionsNeeded`) carry a strong tint — the
/// previous design tinted the whole "busy" range (listening/finalizing/inserting) red, which read
/// as alarming even while just quietly finalizing; now the red only ever shows while the mic is
/// actually open.
struct StatusPill: View {
    var state: MenuBarPillState

    var body: some View {
        Group {
            switch state {
            case .ready:
                Text("Ready")
                    .foregroundStyle(.secondary)
            case .listening:
                tinted(Text("Listening…"), color: .red)
            case .working:
                ShimmerLabel(text: "Working…")
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.secondary.opacity(0.12), in: Capsule())
            case .answerReady:
                tinted(Text("Answer ready"), color: .accentColor)
            case .permissionsNeeded:
                tinted(Text("Permissions needed"), color: .orange)
            }
        }
        .font(.system(size: 11, weight: .semibold))
    }

    private func tinted(_ text: Text, color: Color) -> some View {
        text
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.15), in: Capsule())
    }
}

/// Small shimmer sweep for the "Working…" pill — same lightweight technique as the capsule's
/// `ShimmerText` (a moving gradient masked to the text), kept local since this one's tiny (11pt)
/// and doesn't need the capsule's truncation/width handling.
private struct ShimmerLabel: View {
    var text: String
    @State private var animate = false

    var body: some View {
        Text(text)
            .foregroundStyle(.secondary)
            .overlay(
                GeometryReader { geo in
                    LinearGradient(colors: [.clear, Color.primary.opacity(0.5), .clear], startPoint: .leading, endPoint: .trailing)
                        .frame(width: geo.size.width * 0.5)
                        .offset(x: animate ? geo.size.width * 1.25 : -geo.size.width * 0.75)
                        .animation(.linear(duration: 1.1).repeatForever(autoreverses: false), value: animate)
                }
                .mask(Text(text))
                .allowsHitTesting(false)
            )
            .onAppear { animate = true }
            .onDisappear { animate = false }
    }
}

// MARK: - How to use

/// Expanded by default until the user has completed 10 sessions (a rough proxy: history entries),
/// then collapsed — unless the user has explicitly toggled it themselves, in which case that
/// choice always wins from then on (remembered in `UserDefaults`/`@AppStorage`).
private struct HowToUseSection: View {
    var triggerKeySymbol: String

    @AppStorage("prosio.howToUseExpanded") private var expandedStored = true
    @AppStorage("prosio.howToUseHasUserOverride") private var hasUserOverride = false
    @Environment(\.howToUseDefaultExpanded) private var defaultExpanded

    var body: some View {
        DisclosureGroup(isExpanded: expandedBinding) {
            VStack(alignment: .leading, spacing: 10) {
                HowToRow(icon: "keyboard", title: "Dictate", example: "Press \(triggerKeySymbol), speak, press \(triggerKeySymbol) again")
                HowToRow(icon: "pencil", title: "Edit", example: "Select text, then say how to change it")
                HowToRow(icon: "sparkles", title: "Ask", example: "“提问，…” or just ask a question")
                HowToRow(icon: "globe", title: "Translate", example: "“翻译成英文：…”")
                HowToRow(icon: "square.and.pencil", title: "Write", example: "“帮我回复他说明天可以…”")
            }
            .padding(.top, 8)
            .padding(.bottom, 4)
        } label: {
            Text("How to use")
                .font(.system(size: 12, weight: .semibold))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private var expandedBinding: Binding<Bool> {
        Binding(
            get: { hasUserOverride ? expandedStored : defaultExpanded },
            set: { newValue in
                hasUserOverride = true
                expandedStored = newValue
            }
        )
    }
}

/// Test seam: real usage reads live session history via `HowToUseDefaultExpandedKey`'s default
/// (`environment.history.items.count < 10`, wired in `MenuBarContentView`'s `.environment`
/// modifier below); previews can override it directly without needing a populated `HistoryStore`.
private struct HowToUseDefaultExpandedKey: EnvironmentKey {
    static let defaultValue = true
}

private extension EnvironmentValues {
    var howToUseDefaultExpanded: Bool {
        get { self[HowToUseDefaultExpandedKey.self] }
        set { self[HowToUseDefaultExpandedKey.self] = newValue }
    }
}

private struct HowToRow: View {
    var icon: String
    var title: LocalizedStringKey
    var example: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                Text(example)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Translate row

/// Fixes the previous clipped/white toggle: an inline `Label` inside a `.switch`-style `Toggle`
/// at `.mini` size doesn't lay out cleanly. This uses `.small` with `.labelsHidden()` and a plain
/// leading `Text`, matching a normal settings-row layout.
private struct TranslateRow: View {
    @Binding var enabled: Bool
    @Binding var target: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "globe")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 16)
            Text("Translate to")
                .font(.system(size: 12))
            Picker("", selection: $target) {
                ForEach(TranslateLanguages.all) { language in
                    Text(language.shortCode).tag(language.code)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()
            // Deliberately NOT disabled when off — the user should be able to pick a target
            // language before ever turning translation on, without it looking greyed-out/broken.
            Spacer()
            Toggle("", isOn: $enabled)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .accessibilityLabel("Translate while dictating")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
    }
}

// MARK: - Account

/// A single subtle row, shown only when signed out — nothing when signed in, per the redesign
/// (no persistent "signed in" chrome needed).
struct AccountRow: View {
    var isSignedIn: Bool

    var body: some View {
        if !isSignedIn {
            HStack(spacing: 8) {
                Image(systemName: "person.crop.circle.badge.exclamationmark")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                Text("Sign in to enable cloud polishing")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Spacer()
                SettingsLink {
                    Text("Sign in")
                }
                .buttonStyle(.link)
                .font(.system(size: 12))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
        }
    }
}

// MARK: - Recent (history)

struct RecentHistorySection: View {
    var items: [HistoryItem]
    var hasMore: Bool
    var onCopy: (HistoryItem) -> Void
    var onCopyTranscript: (HistoryItem) -> Void
    var onDelete: (HistoryItem) -> Void
    var onClearAll: () -> Void
    var onShowAll: () -> Void

    @State private var confirmClearAll = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Recent")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if !items.isEmpty {
                    Button("Clear") { confirmClearAll = true }
                        .buttonStyle(.link)
                        .font(.system(size: 11))
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .padding(.bottom, 4)

            if items.isEmpty {
                Text("No dictations yet")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
            } else {
                VStack(spacing: 0) {
                    ForEach(items) { item in
                        HistoryRowView(item: item, onCopy: { onCopy(item) }, onCopyTranscript: { onCopyTranscript(item) }, onDelete: { onDelete(item) })
                    }
                }
                if hasMore {
                    Button("Show all…", action: onShowAll)
                        .buttonStyle(.link)
                        .font(.system(size: 11))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                }
            }
        }
        .padding(.bottom, 4)
        .confirmationDialog("Clear all recent dictations?", isPresented: $confirmClearAll, titleVisibility: .visible) {
            Button("Clear All", role: .destructive, action: onClearAll)
            Button("Cancel", role: .cancel) {}
        }
    }
}

// `HistoryRowView` + `AppIconCache` live in `UI/Support/HistoryRowView.swift`, shared with
// Settings ▸ History.

extension Notification.Name {
    /// Posted by the menu bar's "Show all…" to ask `SettingsRootView` to switch to the History tab.
    static let prosioOpenSettingsHistoryTab = Notification.Name("prosio.openSettingsHistoryTab")
}

#if DEBUG
#Preview("Live") {
    MenuBarContentView(environment: AppEnvironment())
}

// MARK: - Scenario previews (parameter-driven subviews, no AppEnvironment needed)

private func previewItem(_ text: String, app: String?, bundleID: String? = "com.apple.mail", minutesAgo: Double = 4, intent: DictationIntent? = nil, transcript: String? = nil) -> HistoryItem {
    HistoryItem(
        createdAt: .now.addingTimeInterval(-minutesAgo * 60),
        text: text,
        appBundleID: bundleID,
        appName: app,
        engineID: "gateway.gemini-3.5-transcribe",
        durationSeconds: 4,
        insertion: .pasted,
        intent: intent,
        transcript: transcript
    )
}

private struct PopoverPreviewShell<Content: View>: View {
    var pill: MenuBarPillState
    var isSignedIn: Bool
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "waveform").font(.system(size: 14, weight: .semibold)).foregroundStyle(.secondary)
                Text("Prosio").font(.system(size: 13, weight: .semibold))
                Spacer()
                StatusPill(state: pill)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            Divider()
            HowToUseSectionPreviewWrapper()
            Divider().padding(.leading, 14)
            TranslateRowPreviewWrapper()
            AccountRow(isSignedIn: isSignedIn)
            Divider().padding(.leading, 14)
            content
            Divider()
            HStack(spacing: 14) {
                Text("Settings…").font(.system(size: 12))
                Spacer()
                Text("Quit Prosio").font(.system(size: 12))
            }
            .padding(12)
        }
        .frame(width: 320)
    }
}

private struct HowToUseSectionPreviewWrapper: View {
    var body: some View { HowToUseSection(triggerKeySymbol: "🌐").environment(\.howToUseDefaultExpanded, true) }
}

private struct TranslateRowPreviewWrapper: View {
    @State private var enabled = true
    @State private var target = "en-US"
    var body: some View { TranslateRow(enabled: $enabled, target: $target) }
}

#Preview("Idle, signed in") {
    PopoverPreviewShell(pill: .ready, isSignedIn: true) {
        RecentHistorySection(
            items: [
                // Regression check: a Markdown-list write reply should flatten to one real line,
                // not "老王：" followed by visible blank space.
                previewItem("老王：\n\n- 我下周请三天假，工作已经交接给小李了。\n- 谢谢！", app: "Messages", bundleID: "com.apple.MobileSMS", intent: .write, transcript: "帮我回复老王说下周请三天假，工作交接给小李了"),
                previewItem("Let's meet Thursday at 3pm instead", app: "Notes", bundleID: "com.apple.Notes", minutesAgo: 20),
                previewItem("Sounds good, see you then!", app: "Messages", bundleID: "com.apple.MobileSMS", minutesAgo: 40, intent: .edit, transcript: "make this sound more casual"),
                // No bundle ID at all — icon + name both correctly absent, not a blank icon.
                previewItem("just a note to self", app: nil, bundleID: nil, minutesAgo: 90),
            ],
            hasMore: false,
            onCopy: { _ in }, onCopyTranscript: { _ in }, onDelete: { _ in }, onClearAll: {}, onShowAll: {}
        )
    }
}

#Preview("Listening") {
    PopoverPreviewShell(pill: .listening, isSignedIn: true) {
        RecentHistorySection(items: [], hasMore: false, onCopy: { _ in }, onCopyTranscript: { _ in }, onDelete: { _ in }, onClearAll: {}, onShowAll: {})
    }
}

#Preview("Not signed in") {
    PopoverPreviewShell(pill: .ready, isSignedIn: false) {
        RecentHistorySection(
            items: [previewItem("帮我翻成日语：明天见", app: "Notes", bundleID: "com.apple.Notes", intent: .write, transcript: "帮我回复他说明天可以，但会晚半小时到")],
            hasMore: false,
            onCopy: { _ in }, onCopyTranscript: { _ in }, onDelete: { _ in }, onClearAll: {}, onShowAll: {}
        )
    }
}

#Preview("Empty history") {
    PopoverPreviewShell(pill: .ready, isSignedIn: true) {
        RecentHistorySection(items: [], hasMore: false, onCopy: { _ in }, onCopyTranscript: { _ in }, onDelete: { _ in }, onClearAll: {}, onShowAll: {})
    }
}
#endif
