import SwiftUI

struct PermissionsSettingsView: View {
    let permissions: PermissionsManager

    var body: some View {
        Form {
            ForEach(PermissionKind.allCases, id: \.self) { kind in
                row(for: kind)
            }
        }
        .formStyle(.grouped)
        .onAppear { permissions.refresh() }
    }

    private func row(for kind: PermissionKind) -> some View {
        let status = permissions.statuses[kind] ?? .notDetermined
        return HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title(for: kind))
                Text(subtitle(for: kind))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            statusView(status)
            actionButton(for: kind, status: status)
        }
        .padding(.vertical, 2)
    }

    private func title(for kind: PermissionKind) -> String {
        switch kind {
        case .microphone: "Microphone"
        case .accessibility: "Accessibility"
        case .inputMonitoring: "Input Monitoring"
        case .speechRecognition: "Speech Recognition"
        }
    }

    private func subtitle(for kind: PermissionKind) -> String {
        switch kind {
        case .microphone: "Required to hear your dictation."
        case .accessibility: "Required to insert text and locate the caret."
        case .inputMonitoring: "Required to detect the dictation key."
        case .speechRecognition: "Used for on-device transcription when offline."
        }
    }

    @ViewBuilder
    private func statusView(_ status: PermissionStatus) -> some View {
        switch status {
        case .granted:
            Label("Granted", systemImage: "checkmark.circle.fill")
                .labelStyle(.iconOnly)
                .foregroundStyle(.green)
        case .denied:
            Label("Denied", systemImage: "xmark.circle.fill")
                .labelStyle(.iconOnly)
                .foregroundStyle(.red)
        case .notDetermined:
            Label("Not determined", systemImage: "questionmark.circle.fill")
                .labelStyle(.iconOnly)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func actionButton(for kind: PermissionKind, status: PermissionStatus) -> some View {
        switch status {
        case .granted:
            EmptyView()
        case .notDetermined:
            Button("Grant") { Task { await permissions.request(kind) } }
        case .denied:
            Button("Open Settings") { permissions.openSystemSettings(for: kind) }
        }
    }
}

#if DEBUG
#Preview {
    PermissionsSettingsView(permissions: PermissionsManager())
        .frame(width: 620, height: 460)
}
#endif
