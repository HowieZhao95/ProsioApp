import Foundation

nonisolated struct CaptureOutputFailure: LocalizedError {
    let original: String
    let rollback: String?
    var errorDescription: String? {
        if let rollback { return "\(original) The temporary history item could not be removed: \(rollback)" }
        return original
    }
}
nonisolated enum CaptureOutputTransaction {
    /// External output must succeed before this new history item is retained.
    /// Failure rolls back only the asset created by this transaction, never existing items.
    @MainActor static func perform(document: EditableCaptureDocument,store: CaptureAssetStore,
        external: @MainActor (CaptureAsset) async throws -> Void) async throws -> CaptureAsset {
        let asset=try await store.saveDocument(document,preserveFullSource:true)
        do { try Task.checkCancellation();try await external(asset);store.pruneHistory(keeping:50);return asset }
        catch {
            let original=error.localizedDescription
            do { try store.delete(asset) } catch { throw CaptureOutputFailure(original:original,rollback:error.localizedDescription) }
            throw CaptureOutputFailure(original:original,rollback:nil)
        }
    }
}
