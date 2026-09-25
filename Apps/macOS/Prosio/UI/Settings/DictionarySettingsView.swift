import ProsioCore
import SwiftUI

struct DictionarySettingsView: View {
    let dictionary: DictionaryStore

    @State private var searchText = ""
    @State private var newTerm = ""
    @State private var editingID: DictionaryEntry.ID?
    @State private var editingText = ""

    private var filtered: [DictionaryEntry] {
        let entries = dictionary.entries.sorted { $0.term.localizedCaseInsensitiveCompare($1.term) == .orderedAscending }
        guard !searchText.isEmpty else { return entries }
        return entries.filter { $0.term.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                TextField("Add a name or term…", text: $newTerm)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(addTerm)
                Button("Add", action: addTerm)
                    .disabled(newTerm.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding([.horizontal, .top], 16)
            .padding(.bottom, 8)

            if filtered.isEmpty {
                emptyState
            } else {
                List {
                    ForEach(filtered) { entry in
                        row(for: entry)
                    }
                }
                .listStyle(.inset)
            }
        }
        .searchable(text: $searchText, prompt: "Search dictionary")
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "text.book.closed")
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
            Text(dictionary.entries.isEmpty ? "No terms yet" : "No matches")
                .foregroundStyle(.secondary)
            if dictionary.entries.isEmpty {
                Text("Add names, jargon or spellings you want recognized correctly.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 260)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func row(for entry: DictionaryEntry) -> some View {
        if editingID == entry.id {
            HStack {
                TextField("Term", text: $editingText)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { commitEdit(entry) }
                Button("Save") { commitEdit(entry) }
                Button("Cancel") { editingID = nil }
            }
        } else {
            HStack {
                Text(entry.term)
                Spacer()
                if let note = entry.note, !note.isEmpty {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { beginEdit(entry) }
            .contextMenu {
                Button("Edit") { beginEdit(entry) }
                Button("Delete", role: .destructive) { delete(entry) }
            }
            .swipeActions {
                Button("Delete", role: .destructive) { delete(entry) }
                Button("Edit") { beginEdit(entry) }.tint(.blue)
            }
        }
    }

    private func addTerm() {
        let term = newTerm.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return }
        try? dictionary.add(term: term)
        newTerm = ""
    }

    private func beginEdit(_ entry: DictionaryEntry) {
        editingID = entry.id
        editingText = entry.term
    }

    private func commitEdit(_ entry: DictionaryEntry) {
        defer { editingID = nil }
        let text = editingText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        var updated = entry
        updated.term = text
        updated.updatedAt = .now
        try? dictionary.update(updated)
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
        .frame(width: 620, height: 460)
}

#Preview("Empty") {
    DictionarySettingsView(dictionary: DictionaryStore(fileURL: nil))
        .frame(width: 620, height: 460)
}
#endif
