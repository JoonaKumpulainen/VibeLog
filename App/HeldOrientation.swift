import CoreMotion
import SwiftUI

/// How the phone is held. The interface stays portrait, so the camera session and monitor never
/// rotate; only the controls turn to match.
enum Hold: Equatable {
    case portrait, landscapeLeft, landscapeRight, upsideDown

    /// Null while the phone is flat or between two holds, which keeps the last hold.
    init?(x: Double, y: Double, z: Double) {
        guard abs(z) < 0.85 else { return nil }
        if abs(x) > abs(y) + 0.3 {
            self = x < 0 ? .landscapeLeft : .landscapeRight
        } else if abs(y) > abs(x) + 0.3 {
            self = y < 0 ? .portrait : .upsideDown
        } else {
            return nil
        }
    }

    var isLandscape: Bool { self == .landscapeLeft || self == .landscapeRight }

    /// Clockwise turn that brings the controls upright. Landscape left has the top of the phone
    /// pointing left.
    var angle: Double {
        switch self {
        case .portrait: return 0
        case .landscapeLeft: return 90
        case .landscapeRight: return -90
        case .upsideDown: return 180
        }
    }

    /// Clockwise turn for playback. The sensor's upright hold is landscape left.
    var clipRotation: Int {
        switch self {
        case .landscapeLeft: return 0
        case .portrait: return 90
        case .landscapeRight: return 180
        case .upsideDown: return 270
        }
    }

    var label: String {
        switch self {
        case .portrait: return "portrait"
        case .landscapeLeft: return "landscape left"
        case .landscapeRight: return "landscape right"
        case .upsideDown: return "upside down"
        }
    }
}

/// Reads gravity directly, because device orientation stops changing under the rotation lock.
final class HoldTracker: ObservableObject {
    @Published private(set) var hold = Hold.portrait

    private let motion = CMMotionManager()
    private let queue = OperationQueue()
    private var last = Hold.portrait

    init() {
        queue.qualityOfService = .utility
        queue.maxConcurrentOperationCount = 1
        motion.accelerometerUpdateInterval = 0.2
        motion.startAccelerometerUpdates(to: queue) { [weak self] data, _ in
            guard let self, let gravity = data?.acceleration,
                let next = Hold(x: gravity.x, y: gravity.y, z: gravity.z), next != self.last
            else { return }
            self.last = next
            DispatchQueue.main.async { self.hold = next }
        }
    }

    deinit {
        motion.stopAccelerometerUpdates()
    }
}

/// Lays its content out as if the screen were turned to the hold, then turns it back.
struct HeldLayout<Content: View>: View {
    let hold: Hold
    let screen: CGSize
    let insets: EdgeInsets
    @ViewBuilder let content: (EdgeInsets) -> Content

    var body: some View {
        let size = hold.isLandscape ? CGSize(width: screen.height, height: screen.width) : screen
        content(heldInsets)
            .frame(width: size.width, height: size.height)
            .rotationEffect(.degrees(hold.angle))
            .frame(width: screen.width, height: screen.height)
    }

    private var heldInsets: EdgeInsets {
        switch hold {
        case .portrait: return insets
        case .landscapeLeft:
            return EdgeInsets(top: insets.trailing, leading: insets.top, bottom: insets.leading, trailing: insets.bottom)
        case .landscapeRight:
            return EdgeInsets(top: insets.leading, leading: insets.bottom, bottom: insets.trailing, trailing: insets.top)
        case .upsideDown:
            return EdgeInsets(top: insets.bottom, leading: insets.trailing, bottom: insets.top, trailing: insets.leading)
        }
    }
}
