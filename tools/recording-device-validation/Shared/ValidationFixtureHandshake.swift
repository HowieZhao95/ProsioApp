import Foundation

nonisolated struct ValidationFixtureHandshake: Codable, Sendable {
    let processID: Int32
    let windowID: UInt32
    let bundleID: String
    let createdAt: Date
    let hostTimeMicroseconds: Int64

    func validate(expectedPID: Int32, expectedBundleID: String) throws {
        guard processID == expectedPID, bundleID == expectedBundleID, windowID > 0 else {
            throw NSError(domain: "RecordingDeviceValidation", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "验收窗口身份不匹配，未开始捕获。"])
        }
    }
}

nonisolated struct ValidationFixtureControl: Codable, Sendable {
    let testToneEnabled: Bool
}

nonisolated struct ValidationSignalEvent: Codable, Sendable {
    let date: Date
    let hostTimeMicroseconds: Int64
    let kind: String
    let frequencyHz: Double
    let scheduledFrames: Int
}

nonisolated enum ValidationFixtureOwner {
    static func parentIsPresent(expectedParentPID: Int32, currentParentPID: Int32) -> Bool {
        expectedParentPID > 1 && currentParentPID == expectedParentPID
    }
}
