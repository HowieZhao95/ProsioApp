import SwiftUI

private enum SettingsTab: Hashable {
    case general, dictionary, history, account, presentation, notes
}

/// Settings window: General, Dictionary, History, Account. Owned by mac-ui agent. INIT SIGNATURE FROZEN.
///
/// Reduced from 6 tabs to 4 in the consumer-facing audit: Permissions folded into a banner on
/// General (only shown when something's missing), Modes removed (Translate/"match writing to the
/// app" moved into General; per-app scene overrides and the voice-command examples removed from
/// UI — the latter now live in the menu bar's "How to use").
struct SettingsRootView: View {
    let environment: AppEnvironment

    @State private var selectedTab: SettingsTab = .general

    var body: some View {
        TabView(selection: $selectedTab) {
            GeneralSettingsView(environment: environment)
                .tag(SettingsTab.general)
                .tabItem { Label("General", systemImage: "gearshape") }

            NotesSettingsView(notes: environment.notes)
                .tag(SettingsTab.notes)
                .tabItem { Label("便签", systemImage: "note.text") }

            PresentationSettingsView(coordinator: environment.presentation)
                .tag(SettingsTab.presentation)
                .tabItem { Label("演示", systemImage: "cursorarrow.rays") }

            DictionarySettingsView(dictionary: environment.dictionary)
                .tag(SettingsTab.dictionary)
                .tabItem { Label("Dictionary", systemImage: "text.book.closed") }

            HistorySettingsView(history: environment.history, settings: environment.settings)
                .tag(SettingsTab.history)
                .tabItem { Label("History", systemImage: "clock.arrow.circlepath") }

            AccountSettingsView(environment: environment)
                .tag(SettingsTab.account)
                .tabItem { Label("Cloud", systemImage: "key") }
        }
        .frame(width: 520, height: 460)
        // The window title tracks the selected tab's own (localized) name.
        .navigationTitle(title(for: selectedTab))
        // The menu bar's "Show all…" (Recent history) posts this to deep-link here.
        .onReceive(NotificationCenter.default.publisher(for: .prosioOpenSettingsHistoryTab)) { _ in
            selectedTab = .history
        }
        .onReceive(NotificationCenter.default.publisher(for: .prosioOpenSettingsNotesTab)) { _ in
            selectedTab = .notes
        }
        .onAppear {
            if environment.openCloudSettings {
                selectedTab = .account
                environment.openCloudSettings = false
            }
        }
        .onChange(of: environment.openCloudSettings) { _, open in
            if open {
                selectedTab = .account
                environment.openCloudSettings = false
            }
        }
    }

    private func title(for tab: SettingsTab) -> LocalizedStringKey {
        switch tab {
        case .notes: "便签"
        case .general: "General"
        case .dictionary: "Dictionary"
        case .history: "History"
        case .account: "Cloud"
        case .presentation: "演示"
        }
    }
}

#if DEBUG
#Preview {
    SettingsRootView(environment: AppEnvironment())
}
#endif
