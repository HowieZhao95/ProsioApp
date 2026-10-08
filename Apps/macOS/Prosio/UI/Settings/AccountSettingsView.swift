import ProsioCore
import SwiftUI

/// Signed in: email (`environment.signedInEmail`, mirrored from `BackendClient.signedInEmail` —
/// persisted server-side, current whenever `isSignedIn` is) + usage this month (`fetchUsage()`,
/// loaded via `.task`, row hidden entirely on error) + Sign out. Signed out: a clean one-field
/// sign-in form. "Backend URL" lives in a `#if DEBUG`-only collapsed "Developer" section.
struct AccountSettingsView: View {
    let environment: AppEnvironment
    @Bindable private var settings: AppSettings

    init(environment: AppEnvironment) {
        self.environment = environment
        self.settings = environment.settings
    }

    @State private var email = ""
    @State private var isSigningIn = false
    @State private var errorMessage: String?
    @State private var usage: UsageStatus?

    var body: some View {
        Form {
            if environment.isSignedIn {
                Section {
                    HStack(spacing: 10) {
                        Image(systemName: "checkmark.seal.fill")
                            .foregroundStyle(.green)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Signed in")
                                .font(.callout)
                            if let email = environment.signedInEmail {
                                Text(email)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Button("Sign Out", role: .destructive) { environment.signOut() }
                    }

                    if let usage {
                        usageRow(usage)
                    }
                }
                .task(id: environment.isSignedIn) {
                    guard environment.isSignedIn else { usage = nil; return }
                    do {
                        usage = try await environment.backend.fetchUsage()
                    } catch {
                        // Hide the row entirely on error rather than showing a broken/stale number.
                        usage = nil
                    }
                }
            } else {
                Section {
                    Text("Sign in for cloud-polished transcription, translation, and Ask.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    TextField("Email", text: $email)
                        .textFieldStyle(.roundedBorder)
                        .disableAutocorrection(true)
                        .onSubmit(signIn)
                    HStack {
                        Button(action: signIn) {
                            if isSigningIn {
                                ProgressView().controlSize(.small)
                            } else {
                                Text("Sign In")
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(email.trimmingCharacters(in: .whitespaces).isEmpty || isSigningIn)

                        if let errorMessage {
                            Text(errorMessage)
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                    }
                }
            }

            #if DEBUG
            DisclosureGroup("Developer") {
                TextField("Backend URL", text: backendURLBinding)
                    .textFieldStyle(.roundedBorder)
                    .disableAutocorrection(true)
                Text("更改服务地址后，请重新启动 Prosio。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            #endif
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private func usageRow(_ usage: UsageStatus) -> some View {
        let usedMinutes = Int((usage.audioSecondsUsed / 60).rounded())
        VStack(alignment: .leading, spacing: 4) {
            if let limitSeconds = usage.audioSecondsLimit, limitSeconds > 0 {
                let limitMinutes = Int((limitSeconds / 60).rounded())
                Text("\(usedMinutes) / \(limitMinutes) min used this month")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ProgressView(value: min(usage.audioSecondsUsed, limitSeconds), total: limitSeconds)
                    .progressViewStyle(.linear)
                    .tint(.accentColor)
            } else {
                Text("Used \(usedMinutes) min this month")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.top, 2)
    }

    #if DEBUG
    private var backendURLBinding: Binding<String> {
        Binding(
            get: { settings.backendURL.absoluteString },
            set: { newValue in
                if let url = URL(string: newValue) { settings.backendURL = url }
            }
        )
    }
    #endif

    private func signIn() {
        let trimmed = email.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !isSigningIn else { return }
        errorMessage = nil
        isSigningIn = true
        Task {
            do {
                try await environment.signIn(email: trimmed)
            } catch {
                errorMessage = error.localizedDescription
            }
            isSigningIn = false
        }
    }
}

#if DEBUG
#Preview {
    AccountSettingsView(environment: AppEnvironment())
        .frame(width: 520, height: 460)
}
#endif
