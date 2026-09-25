import AppKit
import ProsioCore
import SwiftUI

struct HistorySettingsView: View {
    let history: HistoryStore
    @Bindable private var settings: AppSettings

    init(history: HistoryStore, settings: AppSettings) {
        self.history = history
        self.settings = settings
    }

    @State private var searchText = ""
    @State private var confirmClearAll = false

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }()

    private var filtered: [HistoryItem] {
        guard !searchText.isEmpty else { return history.items }
        return history.items.filter {
            $0.text.localizedCaseInsensitiveContains(searchText)
                || ($0.appName?.localizedCaseInsensitiveContains(searchText) ?? false)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Toggle("Keep history", isOn: $settings.historyEnabled)
                Spacer()
                Button("Clear All", role: .destructive) { confirmClearAll = true }
                    .disabled(history.items.isEmpty)
            }
            .padding(16)

            if filtered.isEmpty {
                emptyState
            } else {
                List {
                    ForEach(filtered) { item in
                        row(for: item)
                    }
                }
                .listStyle(.inset)
            }
        }
        .searchable(text: $searchText, prompt: "Search history")
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
            Text(history.items.isEmpty ? "No dictation history yet" : "No matches")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func row(for item: HistoryItem) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 3) {
                Text(item.text)
                    .lineLimit(2)
                HStack(spacing: 8) {
                    if let appName = item.appName {
                        Label(appName, systemImage: "app.badge")
                    }
                    Text(Self.timeFormatter.string(from: item.createdAt))
                    Text(item.engineID)
                        .lineLimit(1)
                    outcomeBadge(item.insertion)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                copy(item)
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.borderless)
        }
        .contentShape(Rectangle())
        .padding(.vertical, 2)
        .contextMenu {
            Button("Copy") { copy(item) }
            Button("Delete", role: .destructive) { try? history.delete(id: item.id) }
        }
        .swipeActions {
            Button("Delete", role: .destructive) { try? history.delete(id: item.id) }
        }
    }

    private func outcomeBadge(_ outcome: InsertionOutcome) -> some View {
        let text: String
        let color: Color
        switch outcome {
        case .pasted: text = "Pasted"; color = .green
        case .accessibility: text = "Inserted"; color = .green
        case .copiedToClipboard: text = "Copied"; color = .blue
        case .failed: text = "Failed"; color = .red
        }
        return Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }

    private func copy(_ item: HistoryItem) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(item.text, forType: .string)
    }
}

#if DEBUG
#Preview {
    let history = HistoryStore(fileURL: nil)
    try? history.append(HistoryItem(text: "Let's ship the HUD by Friday", appName: "Notes", engineID: "gateway.gemini-3.5-transcribe-live", durationSeconds: 4.2, insertion: .pasted))
    try? history.append(HistoryItem(text: "Copy this into the changelog", appName: "Xcode", engineID: "apple.speechanalyzer", durationSeconds: 2.1, insertion: .copiedToClipboard))
    return HistorySettingsView(history: history, settings: AppSettings())
        .frame(width: 620, height: 460)
}
#endif
