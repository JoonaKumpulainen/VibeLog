import QuartzCore
import SwiftUI
import UIKit

/// A level bar drawn straight onto layers from the audio queue. It moves about twelve times a
/// second without touching the main thread or SwiftUI, which have cost frames during a take.
final class AudioBar {
    let root = CALayer()
    private let zones = CALayer()
    private let green = CALayer()
    private let yellow = CALayer()
    private let red = CALayer()
    private let fill = CALayer()
    private let held = CALayer()
    private let lock = NSLock()
    private var width: CGFloat = 0
    private var shownDB = AudioBar.floorDB
    private var heldDB = AudioBar.floorDB
    private var holdTicks = 0

    private static let floorDB: Float = -60
    /// Green runs to here, for speech and most sound.
    private static let yellowDB: Float = -12
    /// Close to clipping.
    private static let redDB: Float = -3
    private static let fallPerTick: Float = 2.5
    private static let ticksHeld = 18

    init() {
        root.backgroundColor = UIColor(Tokens.surface).cgColor
        green.backgroundColor = UIColor(red: 0.25, green: 0.85, blue: 0.45, alpha: 1).cgColor
        yellow.backgroundColor = UIColor(red: 1, green: 0.8, blue: 0.2, alpha: 1).cgColor
        red.backgroundColor = UIColor(Tokens.record).cgColor
        fill.backgroundColor = UIColor.black.cgColor
        fill.anchorPoint = CGPoint(x: 0, y: 0.5)
        held.backgroundColor = UIColor.white.cgColor
        for zone in [green, yellow, red] { zones.addSublayer(zone) }
        zones.mask = fill
        root.addSublayer(zones)
        root.addSublayer(held)
    }

    private static func share(_ db: Float) -> CGFloat {
        CGFloat(min(max((db - floorDB) / -floorDB, 0), 1))
    }

    func layout(in bounds: CGRect) {
        lock.lock()
        defer { lock.unlock() }
        width = bounds.width
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        root.frame = bounds
        zones.frame = bounds
        let yellowFrom = Self.share(Self.yellowDB) * bounds.width
        let redFrom = Self.share(Self.redDB) * bounds.width
        green.frame = CGRect(x: 0, y: 0, width: yellowFrom, height: bounds.height)
        yellow.frame = CGRect(x: yellowFrom, y: 0, width: redFrom - yellowFrom, height: bounds.height)
        red.frame = CGRect(x: redFrom, y: 0, width: bounds.width - redFrom, height: bounds.height)
        fill.bounds = bounds
        fill.position = CGPoint(x: 0, y: bounds.midY)
        held.bounds = CGRect(x: 0, y: 0, width: 2, height: bounds.height)
        draw()
        CATransaction.commit()
    }

    /// Rises at once and falls gradually, with a mark that holds the recent peak.
    func show(peak: Float) {
        lock.lock()
        defer { lock.unlock() }
        let db = 20 * log10(max(peak, 0.000_01))
        shownDB = max(db, shownDB - Self.fallPerTick)
        if db >= heldDB {
            heldDB = db
            holdTicks = Self.ticksHeld
        } else if holdTicks > 0 {
            holdTicks -= 1
        } else {
            heldDB = max(heldDB - Self.fallPerTick, Self.floorDB)
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        draw()
        CATransaction.commit()
    }

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        shownDB = Self.floorDB
        heldDB = Self.floorDB
        holdTicks = 0
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        draw()
        CATransaction.commit()
    }

    private func draw() {
        fill.setAffineTransform(CGAffineTransform(scaleX: max(Self.share(shownDB), 0.001), y: 1))
        held.position = CGPoint(x: Self.share(heldDB) * width, y: root.bounds.midY)
    }
}

private struct AudioBarView: UIViewRepresentable {
    let bar: AudioBar

    final class Host: UIView {
        let bar: AudioBar

        init(bar: AudioBar) {
            self.bar = bar
            super.init(frame: .zero)
            layer.addSublayer(bar.root)
        }

        required init?(coder: NSCoder) { nil }

        override func layoutSubviews() {
            super.layoutSubviews()
            bar.layout(in: bounds)
        }
    }

    func makeUIView(context: Context) -> Host { Host(bar: bar) }

    func updateUIView(_ view: Host, context: Context) {}
}

/// The level bar, beside the loudest level of the last second in dB. The number comes from the
/// once-a-second update, so it can use SwiftUI.
struct AudioMeter: View {
    @EnvironmentObject private var model: AppModel

    private var label: String {
        guard model.audioPeak > 0.001 else { return "-60 dB" }
        return "\(Int((20 * log10(model.audioPeak)).rounded())) dB"
    }

    var body: some View {
        HStack(spacing: 6) {
            Text(label)
                .font(Tokens.labelFont)
                .foregroundStyle(model.audioPeak >= 0.99 ? Tokens.warning : Tokens.value)
                .fixedSize()
                .turnedToHold()
                .frame(width: 40)
            AudioBarView(bar: model.audioBar)
                .frame(height: 8)
        }
        .frame(minWidth: 132, maxWidth: 190)
        .accessibilityElement()
        .accessibilityLabel("Microphone level")
        .accessibilityValue(label)
    }
}
