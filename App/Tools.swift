import SwiftUI

/// Monitoring tools, switched on from the monitor panel.
enum Tool: String, CaseIterable, Identifiable {
    case zebras, falseColor, peaking, grid, center, level, punchIn

    var id: String { rawValue }

    var title: String {
        switch self {
        case .zebras: return "Zebras"
        case .falseColor: return "False color"
        case .peaking: return "Focus peaking"
        case .grid: return "Thirds grid"
        case .center: return "Center mark"
        case .level: return "Level"
        case .punchIn: return "Punch-in"
        }
    }

    var shortTitle: String {
        switch self {
        case .zebras: return "ZEBRA"
        case .falseColor: return "FALSE"
        case .peaking: return "PEAK"
        case .grid: return "GRID"
        case .center: return "CENTER"
        case .level: return "LEVEL"
        case .punchIn: return "PUNCH"
        }
    }

    var symbol: String {
        switch self {
        case .zebras: return "circle.lefthalf.striped.horizontal"
        case .falseColor: return "paintpalette"
        case .peaking: return "scope"
        case .grid: return "squareshape.split.3x3"
        case .center: return "plus"
        case .level: return "level"
        case .punchIn: return "plus.magnifyingglass"
        }
    }
}

/// The guides, watching the level themselves.
struct LiveFrameGuides: View {
    @ObservedObject var level: LevelReading
    let grid: Bool
    let center: Bool
    let showsLevel: Bool
    let gravityDegrees: Double

    var body: some View {
        FrameGuides(
            grid: grid, center: center, levelDegrees: showsLevel ? level.degrees : nil,
            gravityDegrees: gravityDegrees)
    }
}

/// Guides drawn on the recorded area. They never reach the file.
struct FrameGuides: View {
    let grid: Bool
    let center: Bool
    let levelDegrees: Double?
    /// The hold's gravity direction, because the guides stay in portrait coordinates.
    let gravityDegrees: Double

    var body: some View {
        Canvas { context, size in
            let line = GraphicsContext.Shading.color(.white.opacity(0.45))
            var path = Path()
            if grid {
                for share in [1.0 / 3, 2.0 / 3] {
                    path.move(to: CGPoint(x: size.width * share, y: 0))
                    path.addLine(to: CGPoint(x: size.width * share, y: size.height))
                    path.move(to: CGPoint(x: 0, y: size.height * share))
                    path.addLine(to: CGPoint(x: size.width, y: size.height * share))
                }
            }
            let middle = CGPoint(x: size.width / 2, y: size.height / 2)
            if center {
                path.move(to: CGPoint(x: middle.x - 12, y: middle.y))
                path.addLine(to: CGPoint(x: middle.x + 12, y: middle.y))
                path.move(to: CGPoint(x: middle.x, y: middle.y - 12))
                path.addLine(to: CGPoint(x: middle.x, y: middle.y + 12))
            }
            context.stroke(path, with: line, lineWidth: 0.5)
            if let levelDegrees {
                let level = abs(levelDegrees) < 0.5
                let angle = -(levelDegrees + gravityDegrees) * .pi / 180
                let reach = min(size.width, size.height) * 0.3
                var bar = Path()
                bar.move(to: CGPoint(x: middle.x - cos(angle) * reach, y: middle.y - sin(angle) * reach))
                bar.addLine(to: CGPoint(x: middle.x + cos(angle) * reach, y: middle.y + sin(angle) * reach))
                context.stroke(bar, with: .color(level ? Tokens.held : .white.opacity(0.7)), lineWidth: 1)
            }
        }
        .allowsHitTesting(false)
    }
}
