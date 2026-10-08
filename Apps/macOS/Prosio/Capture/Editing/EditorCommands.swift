// Adapted from SnipSnipSnip Editor/EditorCommands.swift, fixed commit
// 7919eac9df9d9dec8427dbc0c10aecd32baf5530. Copyright (c) 2026 Oontz; MIT.
import Foundation
import CoreGraphics
nonisolated protocol DocumentCommand {
    var label: String { get }
    func apply(to snapshot: EditorSnapshot) -> EditorSnapshot
}

nonisolated struct AddAnnotationCommand: DocumentCommand {
    let annotation: Annotation

    var label: String { "Add Annotation" }

    func apply(to snapshot: EditorSnapshot) -> EditorSnapshot {
        var updated = snapshot
        updated.annotations.append(annotation)

        updated.selectedAnnotationIDs = [annotation.id]
        return updated
    }
}

nonisolated struct UpdateAnnotationsCommand: DocumentCommand {
    let annotations: [Annotation]

    var label: String { "Update Annotations" }

    func apply(to snapshot: EditorSnapshot) -> EditorSnapshot {
        var updated = snapshot
        let mapped = Dictionary(uniqueKeysWithValues: annotations.map { ($0.id, $0) })

        updated.annotations = updated.annotations.map { annotation in
            mapped[annotation.id] ?? annotation
        }

        updated.selectedAnnotationIDs = updated.selectedAnnotationIDs.filter { id in
            updated.annotations.contains(where: { $0.id == id })
        }
        return updated
    }
}

nonisolated struct UpdateAnnotationCommand: DocumentCommand {
    let annotation: Annotation

    var label: String { "Update Annotation" }

    func apply(to snapshot: EditorSnapshot) -> EditorSnapshot {
        UpdateAnnotationsCommand(annotations: [annotation]).apply(to: snapshot)
    }
}

nonisolated struct DeleteAnnotationsCommand: DocumentCommand {
    let annotationIDs: [UUID]

    var label: String { "Delete Selection" }

    func apply(to snapshot: EditorSnapshot) -> EditorSnapshot {
        let idSet = Set(annotationIDs)
        var updated = snapshot
        updated.annotations.removeAll { idSet.contains($0.id) }
        updated.selectedAnnotationIDs.removeAll { idSet.contains($0) }
        return updated
    }
}

nonisolated struct SetCropCommand: DocumentCommand {
    let rect: CGRect

    var label: String { "Set Crop" }

    func apply(to snapshot: EditorSnapshot) -> EditorSnapshot {
        var updated = snapshot
        updated.cropRect = rect.standardized.integral
        return updated
    }
}


@MainActor
final class EditorHistory {
    private(set) var snapshot: EditorSnapshot
    private var undoSnapshots: [EditorSnapshot] = []
    private var redoSnapshots: [EditorSnapshot] = []
    private var groupedSnapshot: EditorSnapshot?
    func beginGroupedEdit() { if groupedSnapshot == nil { groupedSnapshot = snapshot } }
    func endGroupedEdit() {
        guard let original = groupedSnapshot else { return }
        groupedSnapshot = nil
        if original != snapshot { undoSnapshots.append(original); redoSnapshots.removeAll() }
    }
    var canUndo: Bool { !undoSnapshots.isEmpty }; var canRedo: Bool { !redoSnapshots.isEmpty }
    init(snapshot: EditorSnapshot) { self.snapshot=snapshot }
    func apply(_ command: any DocumentCommand) {
        let next=command.apply(to:snapshot); guard next != snapshot else { return }
        if groupedSnapshot == nil { undoSnapshots.append(snapshot); redoSnapshots.removeAll() }
        snapshot=next
    }
    func setSelection(_ ids: [UUID]) { snapshot.selectedAnnotationIDs=ids }
    func undo() { endGroupedEdit(); guard let s=undoSnapshots.popLast() else { return }; redoSnapshots.append(snapshot); snapshot=s }
    func redo() { endGroupedEdit(); guard let s=redoSnapshots.popLast() else { return }; undoSnapshots.append(snapshot); snapshot=s }
}

/// One undo step replaces translations without disturbing user annotations.
nonisolated struct SetCaptureTranslationCommand: DocumentCommand {
    let annotations: [Annotation]
    let crop: CGRect
    var label: String { "Translate Screenshot" }
    func apply(to snapshot: EditorSnapshot) -> EditorSnapshot {
        var result = snapshot
        result.annotations.removeAll { $0.isTranslation && $0.renderBounds.intersects(crop) }
        result.annotations.append(contentsOf: annotations)
        result.selectedAnnotationIDs = []
        return result
    }
}
