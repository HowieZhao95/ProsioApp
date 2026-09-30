import SwiftUI

struct CaptureLibraryView: View {
    let coordinator: CaptureCoordinator
    @State private var pendingDelete: CaptureAsset?
    var body: some View {
        VStack {
            if !coordinator.drafts.assets.isEmpty {
                DisclosureGroup("Recover unfinished screenshots (\(coordinator.drafts.assets.count))") {
                    ForEach(coordinator.drafts.assets) { asset in
                        HStack {
                            Text(asset.sourceName).lineLimit(1)
                            Spacer()
                            Button("Resume") { coordinator.reopenDraft(asset) }
                            Button("Discard",role:.destructive) { try? coordinator.drafts.delete(asset) }
                        }.padding(.vertical,4)
                    }
                }.padding(.horizontal,4)
            }
            if coordinator.store.assets.isEmpty {
                ContentUnavailableView("No screenshots yet", systemImage: "photo.on.rectangle", description: Text("Saved screenshots appear here automatically."))
            } else {
                List(coordinator.store.assets) { asset in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(asset.sourceName).lineLimit(1)
                            Text("\(asset.createdAt.formatted()) · \(asset.pixelWidth) × \(asset.pixelHeight)").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Open") { coordinator.openEditor(asset) }
                        Menu {
                            Button("Copy") { coordinator.copy(asset) }
                            Button("Save…") { coordinator.export(asset) }
                            Button("Delete…", role: .destructive) { pendingDelete = asset }
                        } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).fixedSize()
                    }.padding(.vertical, 4)
                }
            }
            if let message = coordinator.message { Text(message).font(.caption).foregroundStyle(.secondary) }
            if !coordinator.store.recoveryWarnings.isEmpty {
                Text("Some saved screenshots could not be loaded. Their files have been preserved.").font(.caption).foregroundStyle(.orange)
            }
        }.padding(12).frame(minWidth: 480, minHeight: 300)
        .confirmationDialog("Delete this screenshot from Prosio?", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })) {
            Button("Delete", role: .destructive) { if let asset = pendingDelete { coordinator.delete(asset) }; pendingDelete = nil }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        }
    }
}
