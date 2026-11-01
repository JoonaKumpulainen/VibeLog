import SwiftUI

enum Tokens {
    /// Marks values the user is holding.
    static let held = Color(red: 1, green: 0.71, blue: 0.28)
    /// Something that can end or spoil a take.
    static let warning = Color(red: 1, green: 0.45, blue: 0.15)
    /// Used only for recording.
    static let record = Color(red: 0.91, green: 0.21, blue: 0.17)
    /// The record color, lifted to read as text on black.
    static let recordText = Color(red: 1, green: 0.35, blue: 0.31)
    static let label = Color.white.opacity(0.62)
    static let value = Color(white: 0.95)
    static let hairline = Color.white.opacity(0.22)
    static let opaquePanel = Color(white: 0.09)
    static let panelRadius: CGFloat = 7

    static let labelFont = Font.system(size: 10, weight: .medium, design: .monospaced)
    static let valueFont = Font.system(size: 14, weight: .medium, design: .monospaced)
    static let lineFont = Font.system(size: 11, weight: .medium, design: .monospaced)
    static let statusFont = Font.system(size: 12, weight: .medium, design: .monospaced)
    static let markFont = Font.system(size: 9, weight: .medium, design: .monospaced)
    static let clockFont = Font.system(size: 28, weight: .semibold, design: .monospaced)
    static let sidewaysClockFont = Font.system(size: 22, weight: .semibold, design: .monospaced)
    static let noticeTitleFont = Font.system(size: 19, weight: .semibold)
    static let noticeFont = Font.system(size: 14)
}

/// Where the picture sits, in portrait screen coordinates. Nothing overlaps it in any hold. Its
/// top and bottom edges come from the 4:3 frame, so 16:9 only narrows the picture until Full view.
struct CameraGeometry {
    let picture: CGRect

    static let controlBarDepth: CGFloat = 46
    static let recordDepth: CGFloat = 68
    /// The row above the control bar: a dial or the monitor tools.
    static let trayDepth: CGFloat = 58
    /// The tool row and control bar, which a notice covers.
    static let noticeDepth: CGFloat = 44 + 8 + controlBarDepth
    /// The status blocks beside the Dynamic Island are square, so they fit in every hold.
    static let statusTop: CGFloat = 14
    static let statusSide: CGFloat = 81
    /// The most Full view keeps beneath the picture.
    static let fullViewDepth: CGFloat = 76

    /// Share of the spare height above the picture. Estimated, not measured from the Camera app.
    private static let topShare: CGFloat = 0.3
    private static let smallestTop = statusTop + statusSide + 4
    /// Record row, the control bar and an open tray.
    private static let smallestBottom: CGFloat = recordDepth + 8 + controlBarDepth + 8 + trayDepth + 4

    /// Full view leaves the 4:3 frame and fills the width, with only a strip beneath the picture.
    init(screen: CGSize, top: CGFloat, bottom: CGFloat, widescreen: Bool, fullView: Bool) {
        if fullView {
            let height = min(screen.width * 16 / 9, screen.height - top - Self.fullViewDepth)
            let width = height * 9 / 16
            picture = CGRect(x: (screen.width - width) / 2, y: top, width: width, height: height)
            return
        }
        let upper = max(top + 4, Self.smallestTop)
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
