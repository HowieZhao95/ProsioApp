import SwiftUI

/// Apple-Intelligence-style palette shared by the edge glow and capsule glyph.
enum ProsioPalette {
    static let pink = Color(red: 1.0, green: 0.404, blue: 0.470)
    static let orange = Color(red: 1.0, green: 0.729, blue: 0.443)
    static let blueViolet = Color(red: 0.553, green: 0.600, blue: 1.0)
    static let lilac = Color(red: 0.737, green: 0.510, blue: 0.953)
    static let softPink = Color(red: 0.961, green: 0.725, blue: 0.918)
    static let peach = Color(red: 1.0, green: 0.839, blue: 0.647)

    /// Looping color sequence for the rotating angular gradient (first == last for a seamless wrap).
    static let glow: [Color] = [pink, orange, peach, lilac, blueViolet, softPink, pink]

    static let error: [Color] = [
        Color(red: 1.0, green: 0.35, blue: 0.35),
        Color(red: 1.0, green: 0.55, blue: 0.4),
        Color(red: 1.0, green: 0.35, blue: 0.35),
    ]

    static func gradient(errorTinted: Bool) -> [Color] {
        errorTinted ? error : glow
    }
}
