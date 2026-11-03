import QuartzCore
import SwiftUI
import UIKit

/// Left and right level bars drawn straight onto layers from the audio queue. They move about
/// twelve times a second without touching the main thread or SwiftUI, which have cost frames
/// during a take. Mono shows the same level on both.
final class AudioBar {
    let root = CALayer()
    private let channels = [Channel(letter: "L"), Channel(letter: "R")]
    private let lock = NSLock()
    private var width: CGFloat = 0

    static let floorDB: Float = -60
    /// Green runs to here, for speech and most sound.
    static let yellowDB: Float = -12
    /// Close to clipping.
    static let redDB: Float = -3
    static let fallPerTick: Float = 2.5
    static let ticksHeld = 18
    static let barGap: CGFloat = 3

    /// One bar: colored zones shown up to the level, a mark for the recent peak, and its letter,
    /// dark where the bar is lit and faint where it isn't.
    private final class Channel {
        let root = CALayer()
        let zones = CALayer()
        let green = CALayer()
        let yellow = CALayer()
        let red = CALayer()
        let fill = CALayer()
        let held = CALayer()
        let litLetter = CATextLayer()
        let dimLetter = CATextLayer()
        var shownDB = AudioBar.floorDB
        var heldDB = AudioBar.floorDB
        var holdTicks = 0

        init(letter: String) {
            root.backgroundColor = UIColor(Tokens.surface).cgColor
            green.backgroundColor = UIColor(red: 0.25, green: 0.85, blue: 0.45, alpha: 1).cgColor
            yellow.backgroundColor = UIColor(red: 1, green: 0.8, blue: 0.2, alpha: 1).cgColor
            red.backgroundColor = UIColor(Tokens.record).cgColor
            fill.backgroundColor = UIColor.black.cgColor
            fill.anchorPoint = CGPoint(x: 0, y: 0.5)
            held.backgroundColor = UIColor.white.cgColor
            for (layer, color) in [(litLetter, UIColor(white: 0, alpha: 0.55)), (dimLetter, UIColor(white: 1, alpha: 0.3))] {
                layer.string = letter
                layer.font = UIFont.monospacedSystemFont(ofSize: 8, weight: .bold)
                layer.fontSize = 8
                layer.alignmentMode = .center
                layer.foregroundColor = color.cgColor
                layer.contentsScale = UIScreen.main.scale
            }
            root.addSublayer(dimLetter)
            for zone in [green, yellow, red, litLetter] { zones.addSublayer(zone) }
            zones.mask = fill
            root.addSublayer(zones)
            root.addSublayer(held)
        }

        func layout(_ bounds: CGRect) {
            root.frame = bounds
            let local = CGRect(origin: .zero, size: bounds.size)
            zones.frame = local
            let yellowFrom = AudioBar.share(AudioBar.yellowDB) * local.width
            let redFrom = AudioBar.share(AudioBar.redDB) * local.width
            green.frame = CGRect(x: 0, y: 0, width: yellowFrom, height: local.height)
            yellow.frame = CGRect(x: yellowFrom, y: 0, width: redFrom - yellowFrom, height: local.height)
            red.frame = CGRect(x: redFrom, y: 0, width: local.width - redFrom, height: local.height)
            fill.bounds = local
            fill.position = CGPoint(x: 0, y: local.midY)
            held.bounds = CGRect(x: 0, y: 0, width: 2, height: local.height)
            // A square at the bar's start, so the letter can turn in place.
            let letter = CGRect(x: 2, y: (local.height - 10) / 2, width: 10, height: 10)
            for layer in [litLetter, dimLetter] {
                layer.bounds = CGRect(origin: .zero, size: letter.size)
                layer.position = CGPoint(x: letter.midX, y: letter.midY + 0.5)
            }
        }

        func show(peak: Float) {
            let db = 20 * log10(max(peak, 0.000_01))
            shownDB = max(db, shownDB - AudioBar.fallPerTick)
            if db >= heldDB {
                heldDB = db
                holdTicks = AudioBar.ticksHeld
            } else if holdTicks > 0 {
                holdTicks -= 1
            } else {
                heldDB = max(heldDB - AudioBar.fallPerTick, AudioBar.floorDB)
            }
        }

        func reset() {
            shownDB = AudioBar.floorDB
            heldDB = AudioBar.floorDB
            holdTicks = 0
        }

        func draw(width: CGFloat) {
            fill.setAffineTransform(CGAffineTransform(scaleX: max(AudioBar.share(shownDB), 0.001), y: 1))
            held.position = CGPoint(x: AudioBar.share(heldDB) * width, y: root.bounds.midY)
        }
    }

    init() {
        for channel in channels { root.addSublayer(channel.root) }
    }

    static func share(_ db: Float) -> CGFloat {
        CGFloat(min(max((db - floorDB) / -floorDB, 0), 1))
    }

    func layout(in bounds: CGRect) {
        lock.lock()
        defer { lock.unlock() }
        width = bounds.width
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        root.frame = bounds
        let height = (bounds.height - Self.barGap) / 2
        channels[0].layout(CGRect(x: 0, y: 0, width: bounds.width, height: height))
        channels[1].layout(CGRect(x: 0, y: height + Self.barGap, width: bounds.width, height: height))
        draw()
        CATransaction.commit()
    }

    /// Turns the letters upright for the hold, like the rest of the controls.
    func turnLetters(degrees: Double) {
        lock.lock()
        defer { lock.unlock() }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let turn = CATransform3DMakeRotation(CGFloat(degrees * .pi / 180), 0, 0, 1)
        for channel in channels {
            channel.litLetter.transform = turn
            channel.dimLetter.transform = turn
        }
        CATransaction.commit()
    }

    /// Rises at once and falls gradually, with a mark that holds the recent peak.
    func show(left: Float, right: Float) {
        lock.lock()
        defer { lock.unlock() }
        channels[0].show(peak: left)
        channels[1].show(peak: right)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        draw()
        CATransaction.commit()
    }

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        for channel in channels { channel.reset() }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        draw()
        CATransaction.commit()
    }

    private func draw() {
        for channel in channels { channel.draw(width: width) }
    }
}

private struct AudioBarView: UIViewRepresentable {
    let bar: AudioBar
    let turn: Double

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

    func updateUIView(_ view: Host, context: Context) {
        bar.turnLetters(degrees: turn)
    }
}

/// The level bar, beside the loudest level of the last second in dB. The number comes from the
/// once-a-second update, so it can use SwiftUI.
struct AudioMeter: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.heldTurn) private var turn

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
            AudioBarView(bar: model.audioBar, turn: turn)
                .frame(height: 21)
        }
        .frame(minWidth: 96, maxWidth: 190)
        .accessibilityElement()
        .accessibilityLabel("Microphone level")
        .accessibilityValue(label)
    }
}
