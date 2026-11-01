import SwiftUI

enum Tokens {
    /// Marks values the user is holding.
    static let held = Color(red: 1, green: 0.71, blue: 0.28)
    /// Used only for recording.
    static let record = Color(red: 0.91, green: 0.21, blue: 0.17)
    static let label = Color.white.opacity(0.62)
    static let value = Color(white: 0.95)
    static let hairline = Color.white.opacity(0.22)
    static let panelRadius: CGFloat = 7

    static let labelFont = Font.system(size: 10, weight: .medium, design: .monospaced)
    static let valueFont = Font.system(size: 14, weight: .medium, design: .monospaced)
    static let lineFont = Font.system(size: 11, weight: .medium, design: .monospaced)
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
