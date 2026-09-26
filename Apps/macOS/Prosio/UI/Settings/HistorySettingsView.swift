import AppKit
import ProsioCore
import SwiftUI

/// Settings ▸ History — same row design as the menu bar's "Recent" (`HistoryRowView`), per the
/// Settings audit.
struct HistorySettingsView: View {
    let history: HistoryStore
    @Bindable private var settings: AppSettings

    init(history: HistoryStore, settings: AppSettings) {
        self.history = history
        self.settings = settings
    }

    @State private var confirmClearAll = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Toggle("Save history on this Mac", isOn: $settings.historyEnabled)
                Spacer()
                Button("Clear All", role: .destructive) { confirmClearAll = true }
                    .disabled(history.items.isEmpty)
            }
            .padding(16)

            if history.items.isEmpty {
                emptyState
            } else {
                List {
                    ForEach(history.items) { item in
                        HistoryRowView(
                            item: item,
                            onCopy: { copy(item) },
                            onCopyTranscript: { copy(item, useTranscript: true) },
                            onDelete: { try? history.delete(id: item.id) }
                        )
                        .listRowInsets(EdgeInsets())
                    }
                }
                .listStyle(.inset)
            }

            Text("History never leaves this Mac.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
        }
        .confirmationDialog("Clear all dictation history?", isPresented: $confirmClearAll, titleVisibility: .visible) {
            Button("Clear All", role: .destructive) { try? history.clear() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes all \(history.items.count) saved dictations. This cannot be undone.")
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
            Text("No dictation history yet")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func copy(_ item: HistoryItem, useTranscript: Bool = false) {
        let text = (useTranscript ? item.transcript : nil) ?? item.text
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}

#if DEBUG
#Preview {
    let history = HistoryStore(fileURL: nil)
    try? history.append(HistoryItem(text: "Let's ship the HUD by Friday", appBundleID: "com.apple.Notes", appName: "Notes", engineID: "gateway.gemini-3.5-transcribe-live", durationSeconds: 4.2, insertion: .pasted))
    try? history.append(HistoryItem(text: "老王：\n\n- 我下周请三天假，工作已经交接给小李了。\n- 谢谢！", appBundleID: "com.apple.MobileSMS", appName: "Messages", engineID: "gateway.gemini-3.5-transcribe-live", durationSeconds: 3, insertion: .pasted, intent: .write, transcript: "帮我回复老王说下周请三天假"))
    return HistorySettingsView(history: history, settings: AppSettings())
        .frame(width: 520, height: 460)
}

#Preview("Empty") {
    HistorySettingsView(history: HistoryStore(fileURL: nil), settings: AppSettings())
        .frame(width: 520, height: 460)
}
#endif
