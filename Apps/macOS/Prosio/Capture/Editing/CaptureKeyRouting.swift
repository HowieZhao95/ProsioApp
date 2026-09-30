import Foundation

nonisolated enum CaptureKeyRouting {
    enum Action: Equatable { case passThrough, escape, commitText, copy, save, undo, redo, delete, historyOlder, historyNewer }
    static func action(keyCode: UInt16, characters: String?, command: Bool, shift: Bool,
                       textEditing: Bool, hasMarkedText: Bool = false, outputInProgress: Bool = false) -> Action {
        guard !outputInProgress else { return .passThrough }
        if textEditing && hasMarkedText { return .passThrough }
        if keyCode == 53 { return .escape }
        let isReturn = keyCode == 36 || keyCode == 76
        if textEditing {
            if isReturn && command && !hasMarkedText { return .commitText }
            return .passThrough
        }
        if command {
            switch characters?.lowercased() { case "c": return .copy;case "s":return .save;case "z":return shift ? .redo : .undo;default:return .passThrough }
        }
        if isReturn { return .copy }
        if keyCode == 123 { return .historyOlder }
        if keyCode == 124 { return .historyNewer }
        if keyCode == 51 || keyCode == 117 { return .delete }
        return .passThrough
    }
}
