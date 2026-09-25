import ProsioCore
import SwiftUI

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

    var body: some View {
        Form {
            Section("Backend") {
                TextField("Backend URL", text: backendURLBinding)
                    .textFieldStyle(.roundedBorder)
                    .disableAutocorrection(true)
            }

            Section("Account") {
                if environment.backend.isSignedIn {
                    HStack {
                        Image(systemName: "checkmark.seal.fill")
                            .foregroundStyle(.green)
                        Text("Signed in")
                        Spacer()
                        Button("Sign Out", role: .destructive) { environment.signOut() }
                    }
                } else {
                    TextField("Email", text: $email)
                        .textFieldStyle(.roundedBorder)
                        .disableAutocorrection(true)
                        .onSubmit(signIn)

                    HStack {
                        Button(action: signIn) {
                            if isSigningIn {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Text("Sign In")
                            }
                        }
                        .disabled(email.trimmingCharacters(in: .whitespaces).isEmpty || isSigningIn)

                        if let errorMessage {
                            Text(errorMessage)
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private var backendURLBinding: Binding<String> {
        Binding(
            get: { settings.backendURL.absoluteString },
            set: { newValue in
                if let url = URL(string: newValue) { settings.backendURL = url }
            }
        )
    }

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
        .frame(width: 620, height: 460)
}
#endif
