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

/// Where the picture and the controls sit, in portrait screen coordinates. Nothing overlaps. The
/// picture's top and bottom edges come from the 4:3 frame and split the spare height as the Camera
/// app does, so 16:9 only narrows the picture and the controls never move.
struct CameraGeometry {
    let picture: CGRect
    let topBand: CGRect
    let band: CGRect
    /// Stays put in every hold and aspect, so the thumb always finds it.
    let recordCenter: CGPoint

    /// The record button's row, measured in from the phone's bottom edge.
    static let actionDepth: CGFloat = 92

    /// Share of the spare height above the picture. Estimated, not measured from the Camera app.
    private static let topShare: CGFloat = 0.3
    private static let statusDepth: CGFloat = 36
    private static let controlDepth: CGFloat = actionDepth + 98

    init(screen: CGSize, top: CGFloat, bottom: CGFloat, widescreen: Bool) {
        let aspect: CGFloat = widescreen ? 16.0 / 9 : 4.0 / 3
        let smallestTop = top + Self.statusDepth
        let smallestBottom = bottom + Self.controlDepth
        let height = min(screen.width * 4 / 3, screen.height - smallestTop - smallestBottom)
        let spare = screen.height - height
        let y = min(max(spare * Self.topShare, smallestTop), spare - smallestBottom)
        let width = height / aspect
        picture = CGRect(x: (screen.width - width) / 2, y: y, width: width, height: height)
        topBand = CGRect(x: 0, y: 0, width: screen.width, height: y)
        band = CGRect(x: 0, y: y + height, width: screen.width, height: screen.height - y - height)
        recordCenter = CGPoint(x: screen.width / 2, y: screen.height - bottom - Self.actionDepth / 2)
    }
}
