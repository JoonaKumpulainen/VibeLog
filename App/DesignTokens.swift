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
    /// Behind whatever is selected.
    static let surface = Color(white: 0.16)
    static let panelRadius: CGFloat = 8

    static let labelFont = Font.system(size: 10, weight: .medium, design: .monospaced)
    static let valueFont = Font.system(size: 14, weight: .medium, design: .monospaced)
    /// The values that change while shooting. Their size follows the hold, so they never shrink
    /// one by one.
    static let readoutFont = Font.system(size: 20, weight: .medium, design: .monospaced)
    static let sidewaysReadoutFont = Font.system(size: 16, weight: .medium, design: .monospaced)
    static let smallValueFont = Font.system(size: 13, weight: .medium, design: .monospaced)
    static let lineFont = Font.system(size: 11, weight: .medium, design: .monospaced)
    static let statusFont = Font.system(size: 12, weight: .medium, design: .monospaced)
    static let markFont = Font.system(size: 9, weight: .medium, design: .monospaced)
    static let clockFont = Font.system(size: 28, weight: .semibold, design: .monospaced)
    static let sidewaysClockFont = Font.system(size: 22, weight: .semibold, design: .monospaced)
    static let noticeTitleFont = Font.title3.weight(.semibold)
    static let noticeFont = Font.subheadline
}

/// Where the picture sits, in portrait screen coordinates. Nothing overlaps it in any hold. Its
/// top and bottom edges come from the 4:3 frame, so 16:9 only narrows the picture until Full view.
struct CameraGeometry {
    let picture: CGRect

    static let controlBarDepth: CGFloat = 58
    static let recordDepth: CGFloat = 72
    /// The row above the control bar: the tools, a dial or the monitor tools.
    static let trayDepth: CGFloat = 50
    /// The tray and control bar, which a notice covers.
    static let noticeDepth: CGFloat = trayDepth + 3 + controlBarDepth
    /// The space above the picture, with the Dynamic Island in the middle.
    static let statusDepth: CGFloat = 99
    /// Status blocks are square, so they fit in every hold.
    static let statusSide: CGFloat = 81
    static let statusLineWidth: CGFloat = 72
    static let statusLineGap: CGFloat = 3
    /// The most Full view keeps beneath the picture.
    static let fullViewDepth: CGFloat = 80

    /// Share of the spare height above the picture. Estimated, not measured from the Camera app.
    private static let topShare: CGFloat = 0.3
    /// Record row, the control bar and the tray.
    private static let smallestBottom: CGFloat = recordDepth + 5 + noticeDepth + 4

    /// Full view leaves the 4:3 frame and fills the width, with only a strip beneath the picture.
    init(screen: CGSize, top: CGFloat, bottom: CGFloat, widescreen: Bool, fullView: Bool) {
        if fullView {
            let height = min(screen.width * 16 / 9, screen.height - top - Self.fullViewDepth)
            let width = height * 9 / 16
            picture = CGRect(x: (screen.width - width) / 2, y: top, width: width, height: height)
            return
        }
        let upper = max(top + 4, Self.statusDepth)
        let lower = bottom + Self.smallestBottom
        let height = min(screen.width * 4 / 3, screen.height - upper - lower)
        let spare = screen.height - height
        let y = min(max(spare * Self.topShare, upper), spare - lower)
        let width = height / (widescreen ? 16.0 / 9 : 4.0 / 3)
        picture = CGRect(x: (screen.width - width) / 2, y: y, width: width, height: height)
    }
}

extension View {
    /// Turns content to the hold without moving it. Sideways, `depth` limits its width to what
    /// the control has room for once turned.
    func upright(_ hold: Hold, depth: CGFloat) -> some View {
        frame(maxWidth: hold.isLandscape ? depth : .infinity)
            .turnedToHold()
    }
}
