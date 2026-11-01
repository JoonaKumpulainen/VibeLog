import SwiftUI
import UIKit

enum ControlDial: CaseIterable, Identifiable {
    case iso, shutter, whiteBalance, focus

    var id: Self { self }
}

/// The value buttons under the viewfinder, and the dial for the chosen one.
struct ControlStrip: View {
    @EnvironmentObject private var model: AppModel
    @State private var selected: ControlDial?
    let iconAngle: Double

    var body: some View {
        VStack(spacing: 6) {
            Group {
                if let selected {
                    HStack(spacing: 12) {
                        lockButton(selected)
                        dial(selected)
                    }
                } else {
                    Color.clear
                }
            }
            .frame(height: 52)
            HStack(spacing: 8) {
                ForEach(ControlDial.allCases) { chip($0) }
            }
            .frame(height: 44)
        }
        .padding(.horizontal, 16)
    }

    private func chip(_ control: ControlDial) -> some View {
        let held = isHeld(control)
        return Button {
            withAnimation(.easeOut(duration: 0.15)) {
                selected = selected == control ? nil : control
            }
        } label: {
            VStack(spacing: 0) {
                Text(title(control))
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.white.opacity(0.6))
                Text(value(control))
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(held ? Color.yellow : Color.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .rotationEffect(.degrees(iconAngle))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                .white.opacity(selected == control ? 0.2 : 0.1),
                in: RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title(control))
        .accessibilityValue(value(control))
    }

    private func title(_ control: ControlDial) -> String {
        switch control {
        case .iso: return "ISO"
        case .shutter: return "Shutter"
        case .whiteBalance: return "White"
        case .focus: return "Focus"
        }
    }

    private func value(_ control: ControlDial) -> String {
        switch control {
        case .iso: return "\(Int(model.iso))"
        case .shutter: return model.shutterLabel
        case .whiteBalance: return "\(Int(model.temperature)) K"
        case .focus:
            if model.focusLocked { return String(format: "%.2f", model.lensPosition) }
            return model.focusTapped ? "Tap" : "Auto"
        }
    }

    private func isHeld(_ control: ControlDial) -> Bool {
        switch control {
        case .iso, .shutter: return model.exposureLocked
        case .whiteBalance: return model.whiteBalanceLocked
        case .focus: return model.focusLocked || model.focusTapped
        }
    }

    private func lockButton(_ control: ControlDial) -> some View {
        let held = isHeld(control)
        return Button {
            switch control {
            case .iso, .shutter: model.exposureLocked.toggle()
            case .whiteBalance: model.whiteBalanceLocked.toggle()
            case .focus:
                if held { model.releaseFocus() } else { model.focusLocked = true }
            }
        } label: {
            Image(systemName: held ? "lock.fill" : "lock.open")
                .font(.body)
                .foregroundStyle(held ? Color.yellow : Color.white)
                .rotationEffect(.degrees(iconAngle))
                .frame(width: 44, height: 44)
        }
        .buttonStyle(.plain)
        // Switching continuous autofocus on lost 8 frames in a take.
        .disabled(control == .focus && held && model.isRecording)
        .accessibilityLabel(held ? "Unlock \(title(control))" : "Lock \(title(control))")
    }

    @ViewBuilder
    private func dial(_ control: ControlDial) -> some View {
        switch control {
        case .iso:
            let range = model.options?.isoRange ?? 50...12800
            Dial(
                value: Binding(
                    get: { log2(Double(model.iso)) },
                    set: { value in
                        model.iso = Float(pow(2, value))
                        if !model.exposureLocked { model.exposureLocked = true }
                    }),
                range: log2(Double(range.lowerBound))...log2(Double(range.upperBound)),
                step: 1.0 / 6, label: "ISO", valueText: value(.iso))
        case .shutter:
            Dial(
                value: Binding(
                    get: { model.shutterStops },
                    set: { value in
                        model.shutterStops = value
                        if !model.exposureLocked { model.exposureLocked = true }
                    }),
                range: AppModel.slowestShutterStops...13, step: 1.0 / 6, label: "Shutter",
                valueText: value(.shutter))
        case .whiteBalance:
            Dial(
                value: Binding(
                    get: { Double(model.temperature) },
                    set: { value in
                        model.temperature = Float(value)
                        if !model.whiteBalanceLocked { model.whiteBalanceLocked = true }
                    }),
                range: 2500...9000, step: 100, label: "White balance", valueText: value(.whiteBalance))
        case .focus:
            Dial(
                value: Binding(
                    get: { Double(model.lensPosition) },
                    set: { value in
                        model.lensPosition = Float(value)
                        model.focusTapped = false
                        if !model.focusLocked { model.focusLocked = true }
                    }),
                range: 0...1, step: 0.01, label: "Focus", valueText: value(.focus))
        }
    }
}

/// A horizontal ruler that moves under a fixed center mark.
struct Dial: View {
    @EnvironmentObject private var model: AppModel
    @Binding var value: Double
    @State private var dragStart: Double?
    let range: ClosedRange<Double>
    let step: Double
    let label: String
    let valueText: String

    private let spacing = 8.0

    init(
        value: Binding<Double>, range: ClosedRange<Double>, step: Double, label: String,
        valueText: String
    ) {
        _value = value
        self.range = range
        self.step = step
        self.label = label
        self.valueText = valueText
    }

    var body: some View {
        Canvas { context, size in
            let halfCount = Int(size.width / 2 / spacing) + 1
            let center = (value / step).rounded()
            for offset in -halfCount...halfCount {
                let tick = center + Double(offset)
                guard range.contains(tick * step) else { continue }
                let x = size.width / 2 + (tick - value / step) * spacing
                let major = Int(tick) % 6 == 0
                let height = major ? size.height * 0.55 : size.height * 0.3
                var path = Path()
                path.move(to: CGPoint(x: x, y: (size.height - height) / 2))
                path.addLine(to: CGPoint(x: x, y: (size.height + height) / 2))
                context.stroke(path, with: .color(.white.opacity(major ? 0.9 : 0.45)), lineWidth: 1)
            }
        }
        .overlay {
            Rectangle().fill(.yellow).frame(width: 2)
        }
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 2)
                .onChanged { drag in
                    let start = dragStart ?? value
                    dragStart = start
                    let moved = start - Double(drag.translation.width) / spacing * step
                    value = min(max(moved, range.lowerBound), range.upperBound)
                }
                .onEnded { _ in dragStart = nil }
        )
        .sensoryFeedback(.selection, trigger: Int((value / step).rounded())) { _, _ in
            dragStart != nil && !model.isRecording
        }
        .accessibilityElement()
        .accessibilityLabel(label)
        .accessibilityValue(valueText)
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: value = min(value + step * 3, range.upperBound)
            case .decrement: value = max(value - step * 3, range.lowerBound)
            @unknown default: break
            }
        }
    }
}

/// The interface stays portrait, so icons turn with the phone instead.
final class DeviceOrientation: ObservableObject {
    @Published private(set) var iconAngle = 0.0
    private var observer: NSObjectProtocol?

    init() {
        UIDevice.current.beginGeneratingDeviceOrientationNotifications()
        observer = NotificationCenter.default.addObserver(
            forName: UIDevice.orientationDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            switch UIDevice.current.orientation {
            case .portrait: self?.iconAngle = 0
            case .landscapeLeft: self?.iconAngle = 90
            case .landscapeRight: self?.iconAngle = -90
            default: break
            }
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }
}
