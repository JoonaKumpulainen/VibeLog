import SwiftUI

enum Tokens {
    /// Marks values the user is holding.
    static let held = Color(red: 1, green: 0.71, blue: 0.28)
    /// Used only for recording.
    static let record = Color(red: 0.91, green: 0.21, blue: 0.17)
    static let label = Color.white.opacity(0.55)
    static let value = Color(white: 0.95)
    static let hairline = Color.white.opacity(0.18)

    static let labelFont = Font.system(size: 10, weight: .medium, design: .monospaced)
    static let valueFont = Font.system(size: 15, weight: .regular, design: .monospaced)
    static let lineFont = Font.system(size: 11, weight: .regular, design: .monospaced)
    static let icon = Font.system(size: 19, weight: .regular)
}

/// Where the picture and the controls sit, in portrait screen coordinates. Nothing overlaps: the
/// picture takes the largest fit that leaves room for the controls beneath it.
struct CameraGeometry {
    let picture: CGRect
    let band: CGRect
    /// The band is too short for the toolbar and status line.
    let isCompact: Bool

    private static let smallestBand: CGFloat = 132

    init(screen: CGSize, top: CGFloat, bottom: CGFloat, widescreen: Bool) {
        let aspect: CGFloat = widescreen ? 16.0 / 9 : 4.0 / 3
        let room = screen.height - top - bottom - Self.smallestBand
        let height = min(screen.width * aspect, room)
        let width = height / aspect
        picture = CGRect(x: (screen.width - width) / 2, y: top, width: width, height: height)
        band = CGRect(x: 0, y: top + height, width: screen.width, height: screen.height - top - height)
        isCompact = band.height - bottom < 210
    }
}
