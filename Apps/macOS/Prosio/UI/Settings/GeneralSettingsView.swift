import ProsioCore
import SwiftUI

/// Consumer-grade General tab: the permissions banner replaces the old dedicated Permissions tab
/// (only shown when something's actually missing), and Translate/"match writing to the app" moved
/// here from the removed Modes tab. Deliberately does NOT expose: "restore clipboard after
/// pasting" (always on — `AppSettings.restoreClipboard` keeps its `true` default, just unused by
/// this UI), per-app scene overrides, voice-command examples (those live in the menu bar's "How to
/// use"), or raw language codes.
struct GeneralSettingsView: View {
    let environment: AppEnvironment
    @Bindable private var settings: AppSettings

    init(environment: AppEnvironment) {
        self.environment = environment
        self.settings = environment.settings
    }

    var body: some View {
        Form {
            PermissionBanner(permissions: environment.permissions)

            Section("Shortcut") {
                Picker("Dictation key", selection: $settings.triggerKey) {
                    ForEach(TriggerKey.allCases, id: \.self) { key in
                        Text(key.displayName).tag(key)
                    }
                }
                Text("Press once to start, again to finish.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("I speak") {
                LanguageHintPicker(selection: $settings.languageHints)
            }

            Section("Translate") {
                Toggle("Translate what I say", isOn: $settings.translateEnabled)
                Picker("To", selection: $settings.translateTarget) {
                    ForEach(TranslateLanguages.all) { language in
                        Text(language.name).tag(language.code)
                    }
                }
            }

            Section {
                Toggle("Match writing to the app", isOn: $settings.adaptToApp)
                Text("More formal in Mail, casual in chats.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Launch at login", isOn: launchAtLoginBinding)
            }
        }
        .formStyle(.grouped)
        .onAppear { environment.permissions.refresh() }
    }

    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { environment.launchAtLogin },
            set: { environment.launchAtLogin = $0 }
        )
    }
}

/// One sentence + a "Fix" button — only appears when microphone or accessibility access is
/// actually missing (the two `PermissionsManager.allRequiredGranted` checks). Replaces the old
/// standalone Permissions tab, which listed all four kinds unconditionally.
private struct PermissionBanner: View {
    let permissions: PermissionsManager

    var body: some View {
        if let missing {
            Section {
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(message(for: missing))
                        .font(.callout)
                    Spacer()
                    Button("Fix") { fix(missing) }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                }
            }
        }
    }

    /// Reports the first missing one — a single sentence reads better than stacking two banners,
    /// and fixing one typically re-triggers the other's own System Settings prompt anyway.
    private var missing: PermissionKind? {
        if permissions.statuses[.microphone] != .granted { return .microphone }
        if permissions.statuses[.accessibility] != .granted { return .accessibility }
        return nil
    }

    private func message(for kind: PermissionKind) -> String {
        switch kind {
        case .microphone: "Prosio needs microphone access to hear you."
        case .accessibility: "Prosio needs accessibility access to type for you."
        default: ""
        }
    }

    private func fix(_ kind: PermissionKind) {
        if permissions.statuses[kind] == .notDetermined {
            Task { await permissions.request(kind) }
        } else {
            permissions.openSystemSettings(for: kind)
        }
    }
}

/// Friendly language names (no raw BCP-47 codes shown) — reuses the same list as Translate/the
/// menu bar so "I speak" and "Translate to" always offer the same languages. A flowing, left-
/// aligned wrap (via `FlowLayout`) rather than a fixed 3-column grid, since chip widths vary a lot
/// between languages and a rigid grid leaves awkward gaps.
private struct LanguageHintPicker: View {
    @Binding var selection: [String]

    var body: some View {
        FlowLayout(spacing: 8) {
            ForEach(TranslateLanguages.all) { language in
                LanguageChip(
                    name: language.name,
                    isSelected: selection.contains(language.code),
                    action: { toggle(language.code) }
                )
            }
        }
    }

    private func toggle(_ code: String) {
        if selection.contains(code) {
            // Never let the list go empty — on-device recognition needs at least one hint.
            guard selection.count > 1 else { return }
            selection.removeAll { $0 == code }
        } else {
            selection.append(code)
        }
    }
}

private struct LanguageChip: View {
    var name: String
    var isSelected: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 11))
                }
                Text(name)
                    .font(.callout)
            }
            .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                Capsule().fill(isSelected ? Color.accentColor.opacity(0.15) : Color.clear)
            )
            .overlay(
                Capsule().strokeBorder(isSelected ? Color.accentColor.opacity(0.4) : Color.secondary.opacity(0.35), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

/// Minimal left-to-right, top-to-bottom wrapping layout — chips flow naturally and only take the
/// width they need, instead of being forced into fixed columns with big leftover gaps.
private struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var rowWidth: CGFloat = 0
        var totalWidth: CGFloat = 0
        var totalHeight: CGFloat = 0
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if rowWidth > 0, rowWidth + spacing + size.width > maxWidth {
                totalHeight += rowHeight + spacing
                totalWidth = max(totalWidth, rowWidth)
                rowWidth = 0
                rowHeight = 0
            }
            rowWidth += (rowWidth > 0 ? spacing : 0) + size.width
            rowHeight = max(rowHeight, size.height)
        }
        totalHeight += rowHeight
        totalWidth = max(totalWidth, rowWidth)
        return CGSize(width: totalWidth, height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let maxWidth = bounds.width
        var x: CGFloat = bounds.minX
        var y: CGFloat = bounds.minY
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x - bounds.minX + size.width > maxWidth {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

#if DEBUG
#Preview {
    GeneralSettingsView(environment: AppEnvironment())
        .frame(width: 520, height: 460)
}
#endif
