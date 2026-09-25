import AppKit
import SwiftUI

/// First-run permissions walkthrough. Owned by mac-ui agent. INIT SIGNATURE FROZEN.
/// mac-system agent presents it in a window when `permissions.allRequiredGranted == false`.
struct OnboardingView: View {
    let environment: AppEnvironment
    var onFinish: () -> Void

    @State private var step: OnboardingStep = .welcome
    @State private var tryItText: String = ""

    var body: some View {
        VStack(spacing: 0) {
            progressDots
            Spacer(minLength: 12)
            content
                .padding(.horizontal, 40)
                .animation(.easeInOut(duration: 0.25), value: step)
            Spacer(minLength: 12)
            navigation
        }
        .frame(width: 520, height: 420)
        .task {
            while !Task.isCancelled {
                environment.permissions.refresh()
                checkAutoAdvance()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    // MARK: - Steps

    private var permissionKind: PermissionKind? {
        switch step {
        case .microphone: .microphone
        case .accessibility: .accessibility
        case .inputMonitoring: .inputMonitoring
        case .speechRecognition: .speechRecognition
        default: nil
        }
    }

    private func checkAutoAdvance() {
        guard let kind = permissionKind, environment.permissions.statuses[kind] == .granted else { return }
        let stepAtCheck = step
        Task {
            try? await Task.sleep(for: .milliseconds(450))
            if step == stepAtCheck { advance() }
        }
    }

    private func advance() {
        guard let next = OnboardingStep(rawValue: step.rawValue + 1) else { return }
        withAnimation { step = next }
    }

    private func goBack() {
        guard let previous = OnboardingStep(rawValue: step.rawValue - 1) else { return }
        withAnimation { step = previous }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch step {
        case .welcome:
            VStack(spacing: 16) {
                Image(systemName: "waveform.circle.fill")
                    .font(.system(size: 56))
                    .foregroundStyle(
                        LinearGradient(colors: [ProsioPalette.pink, ProsioPalette.blueViolet], startPoint: .topLeading, endPoint: .bottomTrailing)
                    )
                Text("Welcome to Prosio")
                    .font(.title.bold())
                Text("Dictate anywhere on your Mac. Hold a key, speak, and your words appear right where you're typing.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            }
        case .microphone, .accessibility, .inputMonitoring, .speechRecognition:
            if let kind = permissionKind {
                PermissionStepView(
                    kind: kind,
                    status: environment.permissions.statuses[kind] ?? .notDetermined,
                    isOptional: kind == .speechRecognition,
                    onRequest: { Task { await environment.permissions.request(kind) } },
                    onOpenSettings: { environment.permissions.openSystemSettings(for: kind) }
                )
            }
        case .keyboardTip:
            VStack(spacing: 16) {
                Image(systemName: "globe")
                    .font(.system(size: 48))
                    .foregroundStyle(.secondary)
                Text("One More Thing")
                    .font(.title2.bold())
                Text("If you use the \(environment.settings.triggerKey.shortSymbol) key, set it to “Do Nothing” in Keyboard settings so Prosio can use it for dictation.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                Button("Open Keyboard Settings…") { openKeyboardSettings() }
            }
        case .tryIt:
            VStack(spacing: 16) {
                Text("Try It")
                    .font(.title2.bold())
                Text("Hold \(environment.settings.triggerKey.shortSymbol) and speak into the field below.")
                    .foregroundStyle(.secondary)
                TextField("Your dictation will appear here…", text: $tryItText, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(3...5)
            }
        case .done:
            VStack(spacing: 16) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 56))
                    .foregroundStyle(.green)
                Text("You're All Set")
                    .font(.title.bold())
                Text("Look for Prosio in your menu bar any time.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var progressDots: some View {
        HStack(spacing: 6) {
            ForEach(OnboardingStep.allCases, id: \.self) { candidate in
                Circle()
                    .fill(candidate.rawValue <= step.rawValue ? Color.accentColor : Color.secondary.opacity(0.25))
                    .frame(width: 6, height: 6)
            }
        }
        .padding(.top, 20)
    }

    private var navigation: some View {
        HStack {
            if step != .welcome && step != .done {
                Button("Back", action: goBack)
            }
            Spacer()
            if step == .speechRecognition, (environment.permissions.statuses[.speechRecognition] ?? .notDetermined) != .granted {
                Button("Skip", action: advance)
            }
            Button(primaryButtonTitle, action: primaryAction)
                .keyboardShortcut(.defaultAction)
        }
        .padding(20)
    }

    private var primaryButtonTitle: String {
        switch step {
        case .welcome: "Get Started"
        case .done: "Done"
        case .microphone, .accessibility, .inputMonitoring, .speechRecognition:
            (environment.permissions.statuses[permissionKind!] ?? .notDetermined) == .granted ? "Continue" : "Continue Anyway"
        case .keyboardTip, .tryIt: "Continue"
        }
    }

    private func primaryAction() {
        if step == .done {
            onFinish()
        } else {
            advance()
        }
    }

    private func openKeyboardSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }
}

private enum OnboardingStep: Int, CaseIterable {
    case welcome, microphone, accessibility, inputMonitoring, speechRecognition, keyboardTip, tryIt, done
}

private struct PermissionStepView: View {
    let kind: PermissionKind
    let status: PermissionStatus
    let isOptional: Bool
    var onRequest: () -> Void
    var onOpenSettings: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: icon)
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.title2.bold())
            Text(description)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            if isOptional {
                Text("Optional — used for on-device dictation when offline.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            switch status {
            case .granted:
                Label("Granted", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            case .denied:
                Button("Open System Settings…", action: onOpenSettings)
            case .notDetermined:
                Button("Grant Access…", action: onRequest)
            }
        }
    }

    private var icon: String {
        switch kind {
        case .microphone: "mic.fill"
        case .accessibility: "figure.wave"
        case .inputMonitoring: "keyboard"
        case .speechRecognition: "waveform"
        }
    }

    private var title: String {
        switch kind {
        case .microphone: "Microphone Access"
        case .accessibility: "Accessibility Access"
        case .inputMonitoring: "Input Monitoring"
        case .speechRecognition: "Speech Recognition"
        }
    }

    private var description: String {
        switch kind {
        case .microphone: "Prosio listens only while you hold the dictation key."
        case .accessibility: "Lets Prosio insert text and find your cursor in other apps."
        case .inputMonitoring: "Lets Prosio detect when you hold the dictation key, system-wide."
        case .speechRecognition: "Enables on-device transcription when you're offline."
        }
    }
}

#if DEBUG
#Preview {
    OnboardingView(environment: AppEnvironment(), onFinish: {})
}
#endif
