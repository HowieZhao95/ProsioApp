import CoreGraphics
import Foundation

nonisolated struct EditableCaptureDocument: @unchecked Sendable {
    let baseImage: CGImage
    let snapshot: EditorSnapshot
    let kind: CaptureKind
    let sourceName: String
    let sourceRect: CGRect
    let capturedAt: Date

    /// Persist only the current crop source pixels. Stored geometry is relative to that image.
    /// Off-crop source pixels from the frozen desktop are never written to disk.
    func restrictedToSelection() throws -> EditableCaptureDocument {
        let crop = snapshot.cropRect.standardized.integral
        let bounds=CGRect(x:0,y:0,width:baseImage.width,height:baseImage.height)
        guard bounds.contains(crop),crop.width>0,crop.height>0,let image=baseImage.cropping(to:crop) else { throw EditorRenderError.invalidCrop }
        let sx=sourceRect.width/CGFloat(baseImage.width),sy=sourceRect.height/CGFloat(baseImage.height)
        let source=CGRect(x:sourceRect.minX+crop.minX*sx,y:sourceRect.minY+crop.minY*sy,width:crop.width*sx,height:crop.height*sy)
        let annotations=snapshot.annotations.filter { $0.renderBounds.intersects(crop) }.map { $0.translated(by:CGSize(width:-crop.minX,height:-crop.minY)) }
        return EditableCaptureDocument(baseImage:image,snapshot:EditorSnapshot(cropRect:CGRect(origin:.zero,size:CGSize(width:image.width,height:image.height)),annotations:annotations),kind:kind,sourceName:sourceName,sourceRect:source,capturedAt:capturedAt)
    }
}
nonisolated struct EditableCaptureManifest: Codable {
    let version: Int
    let snapshot: EditorSnapshot
}

/// Output is one in-flight operation. Cancel/failure returns to editing; only success exits.
nonisolated struct CaptureOutputState: Equatable {
    enum Phase: Equatable { case editing, outputting, finished, cancelled }
    private(set) var phase: Phase = .editing
    mutating func begin() -> Bool { guard phase == .editing else { return false }; phase = .outputting; return true }
    mutating func failedOrSaveCancelled() { if phase == .outputting { phase = .editing } }
    mutating func succeeded() { if phase == .outputting { phase = .finished } }
    mutating func cancelSession() { phase = .cancelled }
}
