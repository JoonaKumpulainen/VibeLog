import SwiftUI

enum ControlDial: CaseIterable, Identifiable {
    case shutter, iso, whiteBalance, focus

    var id: Self { self }
}

/// The read-out row, and the dial for the chosen value above it.
struct ControlPanels: View {
    @EnvironmentObject private var model: AppModel
    @Binding var selected: ControlDial?

    var body: some View {
        VStack(spacing: 6) {
            if let selected {
                dialPanel(selected)
                    .transition(.opacity)
            }
            HStack(spacing: 0) {
                cell(title: "FPS", value: "30", held: false)
                ForEach(ControlDial.allCases) { control in
                    divider
                    Button {
                        withAnimation(.easeOut(duration: 0.15)) {
                            selected = selected == control ? nil : control
                        }
                    } label: {
                        cell(title: title(control), value: value(control), held: isHeld(control))
                            .background(selected == control ? Tokens.hairline : Color.clear)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(name(control))
                    .accessibilityValue(value(control))
                }
            }
            .frame(height: 46)
            .instrumentPanel()
        }
    }

    private var divider: some View {
        Rectangle().fill(Tokens.hairline).frame(width: 0.5)
    }

    private func cell(title: String, value: String, held: Bool) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .font(Tokens.labelFont)
                .foregroundStyle(Tokens.label)
            Text(value)
                .font(Tokens.valueFont)
                .foregroundStyle(held ? Tokens.held : Tokens.value)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private func title(_ control: ControlDial) -> String {
        switch control {
        case .iso: return "ISO"
        case .shutter: return "SHT"
        case .whiteBalance: return "WB"
        case .focus: return "FOC"
        }
    }

    private func name(_ control: ControlDial) -> String {
        switch control {
        case .iso: return "ISO"
        case .shutter: return "Shutter"
        case .whiteBalance: return "White balance"
        case .focus: return "Focus"
        }
    }

    private func value(_ control: ControlDial) -> String {
        switch control {
        case .iso: return "\(Int(model.iso))"
        case .shutter: return model.shutterLabel
        case .whiteBalance: return "\(Int((model.temperature / 10).rounded()) * 10)"
        case .focus:
            if model.focusLocked { return String(format: "%.2f", model.lensPosition) }
            return model.focusTapped ? "TAP" : "AF"
        }
    }

    private func isHeld(_ control: ControlDial) -> Bool {
        switch control {
        case .iso, .shutter: return model.exposureLocked
        case .whiteBalance: return model.whiteBalanceLocked
        case .focus: return model.focusLocked || model.focusTapped
        }
    }

    private func dialPanel(_ control: ControlDial) -> some View {
        HStack(spacing: 8) {
            lockButton(control)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(title(control))
                        .font(Tokens.labelFont)
                        .foregroundStyle(Tokens.label)
                    Spacer()
                    Text(value(control))
                        .font(Tokens.valueFont)
                        .foregroundStyle(isHeld(control) ? Tokens.held : Tokens.value)
                }
                dial(control)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .instrumentPanel()
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
            Image(systemName: held ? "lock" : "lock.open")
                .font(.system(size: 14))
                .foregroundStyle(held ? Tokens.held : Tokens.value)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Switching continuous autofocus on lost 8 frames in a take.
        .disabled(control == .focus && held && model.isRecording)
        .accessibilityLabel(held ? "Unlock \(name(control))" : "Lock \(name(control))")
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
                step: 1.0 / 6, label: name(.iso), valueText: value(.iso))
        case .shutter:
            Dial(
                value: Binding(
                    get: { model.shutterStops },
                    set: { value in
                        model.shutterStops = value
                        if !model.exposureLocked { model.exposureLocked = true }
                    }),
                range: AppModel.slowestShutterStops...13, step: 1.0 / 6, label: name(.shutter),
                valueText: value(.shutter))
        case .whiteBalance:
            Dial(
                value: Binding(
                    get: { Double(model.temperature) },
                    set: { value in
                        model.temperature = Float(value)
                        if !model.whiteBalanceLocked { model.whiteBalanceLocked = true }
                    }),
                range: 2500...9000, step: 100, label: name(.whiteBalance),
                valueText: value(.whiteBalance))
        case .focus:
            Dial(
                value: Binding(
                    get: { Double(model.lensPosition) },
                    set: { value in
                        model.lensPosition = Float(value)
                        model.focusTapped = false
                        if !model.focusLocked { model.focusLocked = true }
                    }),
                range: 0...1, step: 0.01, label: name(.focus), valueText: value(.focus))
        }
    }
}

/// An engraved ruler that moves under a fixed center mark.
struct Dial: View {
    @EnvironmentObject private var model: AppModel
    @Binding var value: Double
    @State private var dragStart: Double?
    let range: ClosedRange<Double>
    let step: Double
    let label: String
    let valueText: String

    private let spacing: CGFloat = 8

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
                let x = size.width / 2 + CGFloat(tick - value / step) * spacing
                let major = Int(tick) % 6 == 0
                let height = major ? size.height : size.height * 0.5
                var path = Path()
                path.move(to: CGPoint(x: x, y: size.height - height))
                path.addLine(to: CGPoint(x: x, y: size.height))
                context.stroke(path, with: .color(.white.opacity(major ? 0.9 : 0.45)), lineWidth: 0.5)
            }
        }
        .overlay {
            Rectangle().fill(Tokens.held).frame(width: 1)
        }
        .frame(height: 20)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 2)
                .onChanged { drag in
                    let start = dragStart ?? value
                    dragStart = start
                    let moved = start - Double(drag.translation.width / spacing) * step
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
