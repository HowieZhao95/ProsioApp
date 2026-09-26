import SwiftUI

/// Settings window: General, Dictionary, History, Account, Permissions. Owned by mac-ui agent. INIT SIGNATURE FROZEN.
struct SettingsRootView: View {
    let environment: AppEnvironment

    var body: some View {
        TabView {
            GeneralSettingsView(environment: environment)
                .tabItem { Label("General", systemImage: "gearshape") }

            ModesSettingsView(environment: environment)
                .tabItem { Label("Modes", systemImage: "wand.and.stars") }

            DictionarySettingsView(dictionary: environment.dictionary)
                .tabItem { Label("Dictionary", systemImage: "text.book.closed") }

            HistorySettingsView(history: environment.history, settings: environment.settings)
                .tabItem { Label("History", systemImage: "clock.arrow.circlepath") }

            AccountSettingsView(environment: environment)
                .tabItem { Label("Account", systemImage: "person.crop.circle") }

            PermissionsSettingsView(permissions: environment.permissions)
                .tabItem { Label("Permissions", systemImage: "lock.shield") }
        }
        .frame(width: 620, height: 460)
    }
}

#if DEBUG
#Preview {
    SettingsRootView(environment: AppEnvironment())
}
#endif
