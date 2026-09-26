import ProsioCore
import SwiftUI

/// "Words Prosio should always get right" — consumer-grade: add + delete only, no inline
/// rename/notes (the underlying `DictionaryEntry.note` field still exists but isn't exposed here).
struct DictionarySettingsView: View {
    let dictionary: DictionaryStore

    @State private var newTerm = ""

    private var sorted: [DictionaryEntry] {
        dictionary.entries.sorted { $0.term.localizedCaseInsensitiveCompare($1.term) == .orderedAscending }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Words Prosio should always get right")
                .font(.headline)
                .padding([.horizontal, .top], 16)
            Text("Names, product names, jargon — anything worth spelling out.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .padding(.bottom, 8)

            HStack {
                TextField("Add a word…", text: $newTerm)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(addTerm)
                Button("Add", action: addTerm)
                    .disabled(newTerm.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 8)

            if sorted.isEmpty {
                emptyState
            } else {
                List {
                    ForEach(sorted) { entry in
                        Text(entry.term)
                            .contextMenu {
                                Button("Delete", role: .destructive) { delete(entry) }
                            }
                            .swipeActions {
                                Button("Delete", role: .destructive) { delete(entry) }
                            }
                    }
                }
                .listStyle(.inset)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "text.book.closed")
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
            Text("No words yet")
                .foregroundStyle(.secondary)
            Text("For example: your name, a coworker's name, your product's name, or industry jargon.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 260)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func addTerm() {
        let term = newTerm.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return }
        try? dictionary.add(term: term)
        newTerm = ""
    }

    private func delete(_ entry: DictionaryEntry) {
        try? dictionary.delete(id: entry.id)
    }
}

#if DEBUG
#Preview {
    let store = DictionaryStore(fileURL: nil)
    try? store.add(term: "Prosio")
    try? store.add(term: "Vercel")
    try? store.add(term: "Gemini")
    return DictionarySettingsView(dictionary: store)
        .frame(width: 520, height: 460)
}

#Preview("Empty") {
    DictionarySettingsView(dictionary: DictionaryStore(fileURL: nil))
        .frame(width: 520, height: 460)
}
#endif
