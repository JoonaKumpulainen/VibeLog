import SwiftUI

enum Tokens {
    /// Marks values the user is holding.
    static let held = Color(red: 1, green: 0.71, blue: 0.28)
    /// Something that can end or spoil a take.
    static let warning = Color(red: 1, green: 0.45, blue: 0.15)
    /// Used only for recording.
    static let record = Color(red: 0.91, green: 0.21, blue: 0.17)
    static let label = Color.white.opacity(0.62)
    static let value = Color(white: 0.95)
    static let hairline = Color.white.opacity(0.22)
    static let opaquePanel = Color(white: 0.09)
    static let panelRadius: CGFloat = 7

    static let labelFont = Font.system(size: 10, weight: .medium, design: .monospaced)
    static let valueFont = Font.system(size: 14, weight: .medium, design: .monospaced)
    static let lineFont = Font.system(size: 11, weight: .medium, design: .monospaced)
    static let clockFont = Font.system(size: 13, weight: .medium, design: .monospaced)
}

/// Where the picture sits, in portrait screen coordinates. Nothing overlaps it in any hold. Its
/// top and bottom edges come from the 4:3 frame, so 16:9 only narrows the picture.
struct CameraGeometry {
    let picture: CGRect

    static let topBarDepth: CGFloat = 36
    static let controlBarDepth: CGFloat = 46
    static let monitorDepth: CGFloat = 104

    /// Share of the spare height above the picture. Estimated, not measured from the Camera app.
    private static let topShare: CGFloat = 0.3
    private static let smallestTop = topBarDepth + 4
    /// Record row, the control bar and an open dial.
    private static let smallestBottom: CGFloat = 68 + 8 + controlBarDepth + 6 + 58 + 6

    init(screen: CGSize, top: CGFloat, bottom: CGFloat, widescreen: Bool) {
        let upper = top + Self.smallestTop
        let lower = bottom + Self.smallestBottom
        let height = min(screen.width * 4 / 3, screen.height - upper - lower)
        let spare = screen.height - height
        let y = min(max(spare * Self.topShare, upper), spare - lower)
        let width = height / (widescreen ? 16.0 / 9 : 4.0 / 3)
        picture = CGRect(x: (screen.width - width) / 2, y: y, width: width, height: height)
    }
}

/// Smoked glass behind every control. Diagnostics can swap it for a flat fill, to measure what
/// sampling the live picture costs during a recording.
struct InstrumentPanel: ViewModifier {
    @AppStorage("glassPanels") private var useGlass = true

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: Tokens.panelRadius)
        Group {
            if useGlass {
                if #available(iOS 26.0, *) {
                    content.glassEffect(.regular.tint(.black.opacity(0.45)), in: shape)
                } else {
                    content.background(.ultraThinMaterial, in: shape)
                }
            } else {
                content.background(Color.black.opacity(0.62), in: shape)
            }
        }
        .overlay(shape.strokeBorder(Tokens.hairline, lineWidth: 0.5))
    }
}

extension View {
    func instrumentPanel() -> some View { modifier(InstrumentPanel()) }

    /// Turns content to the hold without moving it. Sideways, `depth` limits its width to what
    /// the control has room for once turned.
    func upright(_ hold: Hold, depth: CGFloat) -> some View {
        frame(maxWidth: hold.isLandscape ? depth : .infinity)
            .turnedToHold()
    }
}

/// Corner brackets on the recorded area.
struct FrameMarks: Shape {
    func path(in rect: CGRect) -> Path {
        let inset = rect.insetBy(dx: 10, dy: 10)
        let arm: CGFloat = 14
        var path = Path()
        for (x, y, dx, dy) in [
            (inset.minX, inset.minY, arm, arm), (inset.maxX, inset.minY, -arm, arm),
            (inset.minX, inset.maxY, arm, -arm), (inset.maxX, inset.maxY, -arm, -arm),
        ] {
            path.move(to: CGPoint(x: x + dx, y: y))
            path.addLine(to: CGPoint(x: x, y: y))
            path.addLine(to: CGPoint(x: x, y: y + dy))
        }
        return path
    }
}
