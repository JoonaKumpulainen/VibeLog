import SwiftUI
import VLCore

enum ControlDial: CaseIterable, Identifiable {
    case shutter, iso, whiteBalance, focus

    var id: Self { self }
}

/// A title over a value, turned in place to the hold. Sideways, the bar's depth is how wide it
/// can be.
struct InstrumentCell: View {
    let title: String
    let value: String
    let tint: Color
    let hold: Hold
    let depth: CGFloat

    var body: some View {
        VStack(alignment: hold.isLandscape ? .center : .leading, spacing: 1) {
            Text(title)
                .font(Tokens.labelFont)
                .foregroundStyle(Tokens.label)
            Text(value)
                .font(Tokens.valueFont)
                .foregroundStyle(tint)
        }
        .lineLimit(1)
        .minimumScaleFactor(0.6)
        .upright(hold, depth: depth - 2)
        .padding(.horizontal, hold.isLandscape ? 0 : 8)
        .frame(
            maxWidth: .infinity, maxHeight: .infinity,
            alignment: hold.isLandscape ? .center : .leading)
    }
}

/// The read-out row, and the dial for the chosen value above it.
struct ControlPanels: View {
    @EnvironmentObject private var model: AppModel
    @AppStorage("fineDial") private var fine = false
    @Binding var selected: ControlDial?
    let hold: Hold

    var body: some View {
        VStack(spacing: 6) {
            if let selected {
                dialPanel(selected)
                    .transition(.opacity)
            }
            HStack(spacing: 0) {
                cell(title: "FPS", value: "\(Int(model.frameRate))", held: false)
                ForEach(ControlDial.allCases) { control in
                    divider
                    Button {
                        select(control)
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
            .frame(height: CameraGeometry.controlBarDepth)
            .instrumentPanel()
        }
    }

    private func select(_ control: ControlDial) {
        // A focus rack lost half its frames during a take.
        if control == .focus, model.isRecording {
            model.showNotice("Focus is held during a take", seconds: 2)
            return
        }
        withAnimation(.easeOut(duration: 0.15)) {
            selected = selected == control ? nil : control
        }
    }

    private var divider: some View {
        Rectangle().fill(Tokens.hairline).frame(width: 0.5)
    }

    private func cell(title: String, value: String, held: Bool) -> some View {
        InstrumentCell(
            title: title, value: value, tint: held ? Tokens.held : Tokens.value, hold: hold,
            depth: CameraGeometry.controlBarDepth)
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
            if model.focusLocked || model.focusHeldForTake {
                return String(format: "%.2f", model.lensPosition)
            }
            return model.focusTapped ? "TAP" : "AF"
        }
    }

    private func isHeld(_ control: ControlDial) -> Bool {
        switch control {
        case .iso, .shutter: return model.exposureLocked || model.exposureHeldForTake
        case .whiteBalance: return model.whiteBalanceLocked || model.whiteBalanceHeldForTake
        case .focus: return model.focusLocked || model.focusTapped || model.focusHeldForTake
        }
    }

    private func dialPanel(_ control: ControlDial) -> some View {
        HStack(spacing: 8) {
            smallButton(isHeld(control) ? "lock" : "lock.open", isOn: isHeld(control),
                label: isHeld(control) ? "Unlock \(name(control))" : "Lock \(name(control))") {
                toggleLock(control)
            }
            // One tap here would return to auto mid-shot.
            .disabled(model.isRecording)
            .opacity(model.isRecording ? 0 : 1)
            .accessibilityHidden(model.isRecording)
            VStack(alignment: .leading, spacing: 2) {
                // Sideways the bar below shows the value, and the labels need the depth.
                if !hold.isLandscape {
                    HStack {
                        Text(title(control))
                            .font(Tokens.labelFont)
                            .foregroundStyle(Tokens.label)
                        Spacer()
                        Text(value(control))
                            .font(Tokens.valueFont)
                            .foregroundStyle(isHeld(control) ? Tokens.held : Tokens.value)
                    }
                }
                Dial(
                    stops: stops(control), value: binding(control), labelAngle: hold.angle,
                    isMirrored: hold == .landscapeRight || hold == .upsideDown,
                    spacing: fine ? 7 : 44, label: name(control), valueText: value(control)
                )
                .frame(height: hold.isLandscape ? 46 : 30)
            }
            smallButton("scope", isOn: fine, label: fine ? "Snap to stops" : "Fine adjustment") {
                fine.toggle()
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .instrumentPanel()
    }

    private func smallButton(
        _ symbol: String, isOn: Bool, label: String, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14))
                .foregroundStyle(isOn ? Tokens.held : Tokens.value)
                .turnedToHold()
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private func toggleLock(_ control: ControlDial) {
        switch control {
        case .iso, .shutter: model.exposureLocked.toggle()
        case .whiteBalance: model.whiteBalanceLocked.toggle()
        case .focus:
            if isHeld(.focus) { model.releaseFocus() } else { model.focusLocked = true }
        }
    }

    private func stops(_ control: ControlDial) -> [ExposureScales.Stop] {
        switch control {
        case .iso:
            let range = model.isoRange
            return fine ? ExposureScales.fineStops(geometric: range, perStop: 12)
                : ExposureScales.isoStops(range: range)
        case .shutter:
            return fine ? ExposureScales.fineStops(geometric: model.frameRate...8000, perStop: 6)
                : ExposureScales.shutterStops(fps: model.frameRate, mains: model.mainsHz)
        case .whiteBalance:
            return fine ? ExposureScales.fineStops(linear: 2500...9000, step: 10, majorEvery: 50)
                : ExposureScales.whiteBalanceStops()
        case .focus:
            return fine ? ExposureScales.fineStops(linear: 0...1, step: 0.005, majorEvery: 10)
                : ExposureScales.focusStops()
        }
    }

    private func binding(_ control: ControlDial) -> Binding<Double> {
        switch control {
        case .iso:
            return Binding(
                get: { Double(model.iso) },
                set: { value in
                    model.iso = Float(value)
                    if !model.exposureLocked { model.exposureLocked = true }
                })
        case .shutter:
            return Binding(
                get: { pow(2, model.shutterStops) },
                set: { value in
                    model.shutterStops = log2(value)
                    if !model.exposureLocked { model.exposureLocked = true }
                })
        case .whiteBalance:
            return Binding(
                get: { Double(model.temperature) },
                set: { value in
                    model.temperature = Float(value)
                    if !model.whiteBalanceLocked { model.whiteBalanceLocked = true }
                })
        case .focus:
            return Binding(
                get: { Double(model.lensPosition) },
                set: { value in
                    model.lensPosition = Float(value)
                    model.focusTapped = false
                    if !model.focusLocked { model.focusLocked = true }
                })
        }
    }
}

/// A scale of stops that moves under a fixed center mark, one stop at a time.
struct Dial: View {
    @EnvironmentObject private var model: AppModel
    @Binding var value: Double
    @State private var dragStart: Double?
    let stops: [ExposureScales.Stop]
    /// Turns the scale's labels to the hold.
    let labelAngle: Double
    /// Reverses the scale, so that up as the phone is held always means the same.
    let isMirrored: Bool
    let spacing: CGFloat
    let label: String
    let valueText: String

    init(
        stops: [ExposureScales.Stop], value: Binding<Double>, labelAngle: Double,
        isMirrored: Bool, spacing: CGFloat, label: String, valueText: String
    ) {
        self.stops = stops
        _value = value
        self.labelAngle = labelAngle
        self.isMirrored = isMirrored
        self.spacing = spacing
        self.label = label
        self.valueText = valueText
    }

    private var position: Double { ExposureScales.position(of: value, in: stops) }

    var body: some View {
        Canvas { context, size in
            let center = position
            let reach = Double(size.width / 2 / spacing) + 1
            // Sideways, a label runs along the depth, so the ticks give it room.
            let sideways = abs(labelAngle) == 90
            let labelY = size.height * (sideways ? 0.44 : 0.3)
            let direction: CGFloat = isMirrored ? -1 : 1
            for index in stops.indices where abs(Double(index) - center) <= reach {
                let stop = stops[index]
                let along = size.width / 2 + direction * CGFloat(Double(index) - center) * spacing
                let tick = size.height * (stop.isMajor ? (sideways ? 0.13 : 0.34) : (sideways ? 0.08 : 0.2))
                var path = Path()
                path.move(to: CGPoint(x: along, y: size.height - tick))
                path.addLine(to: CGPoint(x: along, y: size.height))
                context.stroke(path, with: .color(.white.opacity(stop.isMajor ? 0.9 : 0.45)), lineWidth: 0.5)
                guard !stop.label.isEmpty else { continue }
                let text = Text(stop.label).font(Tokens.lineFont)
                    .foregroundColor(abs(Double(index) - center) < 0.5 ? Tokens.held : Tokens.value)
                var labelContext = context
                labelContext.translateBy(x: along, y: labelY)
                labelContext.rotate(by: .degrees(labelAngle))
                labelContext.draw(text, at: .zero)
            }
            var mark = Path()
            mark.move(to: CGPoint(x: size.width / 2, y: size.height * (sideways ? 0.8 : 0.5)))
            mark.addLine(to: CGPoint(x: size.width / 2, y: size.height))
            context.stroke(mark, with: .color(Tokens.held), lineWidth: 1)
        }
        .clipped()
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 2)
                .onChanged { drag in
                    let start = dragStart ?? position
                    dragStart = start
                    let moved = isMirrored ? -drag.translation.width : drag.translation.width
                    let target = (start - Double(moved / spacing)).rounded()
                    value = stops[min(max(Int(target), 0), stops.count - 1)].value
                }
                .onEnded { _ in dragStart = nil }
        )
        .sensoryFeedback(.selection, trigger: Int(position.rounded())) { _, _ in
            dragStart != nil && !model.isRecording
        }
        .accessibilityElement()
        .accessibilityLabel(label)
        .accessibilityValue(valueText)
        .accessibilityAdjustableAction { direction in
            let index = Int(position.rounded())
            switch direction {
            case .increment: value = stops[min(index + 1, stops.count - 1)].value
            case .decrement: value = stops[max(index - 1, 0)].value
            @unknown default: break
            }
        }
    }
}
