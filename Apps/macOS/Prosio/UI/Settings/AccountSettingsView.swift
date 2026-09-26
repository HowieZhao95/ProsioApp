import ProsioCore
import SwiftUI

/// Signed in: email (remembered locally at sign-in time — `BackendClient` doesn't expose who's
/// currently signed in, only whether) + Sign out. Signed out: a clean one-field sign-in form.
/// "Backend URL" moved into a `#if DEBUG`-only collapsed "Developer" section.
///
/// Usage-this-month was requested but skipped: `GET /api/usage` exists per `docs/API.md`, but
/// `BackendClient` (frozen, core-owned) only exposes `reportUsage` (`POST`) — no method to fetch
/// it. Flagged in the task report; not something I can add without a contract change.
struct AccountSettingsView: View {
    let environment: AppEnvironment
    @Bindable private var settings: AppSettings

    init(environment: AppEnvironment) {
        self.environment = environment
        self.settings = environment.settings
    }

    @AppStorage("prosio.lastSignedInEmail") private var lastSignedInEmail = ""

    @State private var email = ""
    @State private var isSigningIn = false
    @State private var errorMessage: String?

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
                            if !lastSignedInEmail.isEmpty {
                                Text(lastSignedInEmail)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Button("Sign Out", role: .destructive) { environment.signOut() }
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
            }
            #endif
        }
        .formStyle(.grouped)
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
                lastSignedInEmail = trimmed
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
