import SwiftUI
import VLCore

enum ControlDial: CaseIterable, Identifiable {
    case shutter, iso, whiteBalance, focus

    var id: Self { self }
}

/// How a value is being set, in a form that doesn't depend on color.
enum CellMark {
    case plain, auto, frozen
}

/// A title over a value, turned in place to the hold. Sideways, the bar's depth is how wide it
/// can be.
struct InstrumentCell: View {
    let title: String
    let value: String
    let tint: Color
    var mark = CellMark.plain
    let hold: Hold

    var body: some View {
        VStack(alignment: hold.isLandscape ? .center : .leading, spacing: 2) {
            HStack(spacing: 3) {
                Text(title)
                    .font(Tokens.labelFont)
                    .foregroundStyle(Tokens.label)
                markView
            }
            Text(value)
                .font(hold.isLandscape ? Tokens.sidewaysReadoutFont : Tokens.readoutFont)
                .foregroundStyle(tint)
        }
        .lineLimit(1)
        .minimumScaleFactor(0.9)
        .upright(hold, depth: CameraGeometry.controlBarDepth - 2)
        .padding(.horizontal, hold.isLandscape ? 0 : 10)
        .frame(
            maxWidth: .infinity, maxHeight: .infinity,
            alignment: hold.isLandscape ? .center : .leading)
    }

    @ViewBuilder
    private var markView: some View {
        switch mark {
        case .plain:
            EmptyView()
        case .auto:
            Text("A")
                .font(Tokens.markFont)
                .foregroundStyle(Tokens.label)
                .padding(.horizontal, 2)
                .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(Tokens.label, lineWidth: 0.5))
        case .frozen:
            Image(systemName: "lock.fill")
                .font(.system(size: 8))
                .foregroundStyle(Tokens.label)
        }
    }
}

/// A smaller title over a value, for the record row.
struct ActionCell: View {
    let title: String
    let value: String
    let tint: Color
    let hold: Hold

    var body: some View {
        VStack(spacing: 1) {
            Text(title)
                .font(Tokens.labelFont)
                .foregroundStyle(Tokens.label)
            Text(value)
                .font(Tokens.smallValueFont)
                .foregroundStyle(tint)
        }
        .lineLimit(1)
        .minimumScaleFactor(0.7)
        .upright(hold, depth: 56)
        .frame(width: 60, height: 52)
        .contentShape(Rectangle())
    }
}

/// The four values, and the dial for the chosen one in the tray above them.
struct ControlPanels: View {
    @EnvironmentObject private var model: AppModel
    @AppStorage("fineDial") private var fine = false
    @State private var showsTint = false
    @Binding var selected: ControlDial?
    let hold: Hold

    var body: some View {
        VStack(spacing: 3) {
            if let selected {
                dialPanel(selected)
                    .transition(.opacity)
            }
            HStack(spacing: 0) {
                ForEach(ControlDial.allCases) { control in
                    Button {
                        select(control)
                    } label: {
                        InstrumentCell(
                            title: title(control), value: value(control),
                            tint: isManual(control) ? Tokens.held : Tokens.value, mark: mark(control),
                            hold: hold
                        )
                        .background(
                            selected == control ? Tokens.surface : Color.clear,
                            in: RoundedRectangle(cornerRadius: Tokens.panelRadius)
                        )
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(name(control))
                    .accessibilityValue("\(value(control)), \(stateName(control))")
                }
            }
            .frame(height: CameraGeometry.controlBarDepth)
        }
    }

    private func select(_ control: ControlDial) {
        // A focus rack lost half its frames during a take.
        if control == .focus, model.isRecording {
            model.showNotice("Focus is held during a take", seconds: 2)
            return
        }
        showsTint = false
        withAnimation(.easeOut(duration: 0.15)) {
            selected = selected == control ? nil : control
        }
    }

    private func title(_ control: ControlDial) -> String {
        switch control {
        case .iso: return "ISO"
        case .shutter: return selected == .shutter ? model.shutterAngleLabel : "SHUTTER"
        case .whiteBalance: return isShowingTint(control) ? "TINT" : "WB"
        case .focus: return "FOCUS"
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

    private func isShowingTint(_ control: ControlDial) -> Bool {
        control == .whiteBalance && showsTint && selected == .whiteBalance
    }

    private func value(_ control: ControlDial) -> String {
        switch control {
        case .iso: return "\(Int(model.iso))"
        case .shutter: return model.shutterLabel
        case .whiteBalance:
            if isShowingTint(control) { return String(format: "%+d", Int(model.tint)) }
            return "\(Int((model.temperature / 10).rounded()) * 10)"
        case .focus:
            if model.focusLocked || model.focusHeldForTake {
                return String(format: "%.2f", model.lensPosition)
            }
            return model.focusTapped ? "AF-L" : "AF"
        }
    }

    private func isHeld(_ control: ControlDial) -> Bool {
        switch control {
        case .iso, .shutter: return model.exposureLocked || model.exposureHeldForTake
        case .whiteBalance: return model.whiteBalanceLocked || model.whiteBalanceHeldForTake
        case .focus: return model.focusLocked || model.focusTapped || model.focusHeldForTake
        }
    }

    /// Set by the user, as opposed to following the camera or frozen for a take.
    private func isManual(_ control: ControlDial) -> Bool {
        switch control {
        case .iso, .shutter: return model.exposureLocked
        case .whiteBalance: return model.whiteBalanceLocked
        case .focus: return model.focusLocked || model.focusTapped
        }
    }

    private func isFrozen(_ control: ControlDial) -> Bool {
        switch control {
        case .iso, .shutter: return model.exposureHeldForTake
        case .whiteBalance: return model.whiteBalanceHeldForTake
        case .focus: return model.isRecording
        }
    }

    private func mark(_ control: ControlDial) -> CellMark {
        if isFrozen(control) { return .frozen }
        return isManual(control) ? .plain : .auto
    }

    private func stateName(_ control: ControlDial) -> String {
        switch mark(control) {
        case .plain: return "manual"
        case .auto: return "auto"
        case .frozen: return "frozen for the take"
        }
    }

    private func dialPanel(_ control: ControlDial) -> some View {
        let tinted = isShowingTint(control)
        return HStack(spacing: 4) {
            trayButton("AUTO", isOn: !isHeld(control), label: "Auto \(name(control))") {
                toggleLock(control)
            }
            // One tap here would return to auto mid-shot.
            .disabled(model.isRecording)
            .opacity(model.isRecording ? 0 : 1)
            .accessibilityHidden(model.isRecording)
            Dial(
                stops: tinted ? tintStops : stops(control),
                value: tinted ? tintBinding : binding(control), labelAngle: hold.angle,
                isMirrored: hold == .landscapeRight || hold == .upsideDown,
                spacing: fine ? 7 : 44, label: tinted ? "Tint" : name(control),
                valueText: value(control)
            )
            .frame(height: 46)
            if control == .whiteBalance {
                trayButton("TINT", isOn: showsTint, label: "Tint") { showsTint.toggle() }
            }
            if control == .focus {
                trayButton("PUNCH", isOn: model.isOn(.punchIn), label: "Punch-in") {
                    model.toggle(.punchIn)
                }
                if model.monitorIsProcessed {
                    trayButton("PEAK", isOn: model.isOn(.peaking), label: "Focus peaking") {
                        model.toggle(.peaking)
                    }
                }
            }
            trayButton("FINE", isOn: fine, label: "Fine adjustment") { fine.toggle() }
        }
        .frame(height: CameraGeometry.trayDepth)
    }

    private func trayButton(
        _ text: String, isOn: Bool, label: String, action: @escaping () -> Void
    ) -> some View {
        let shape = RoundedRectangle(cornerRadius: Tokens.panelRadius)
        return Button(action: action) {
            Text(text)
                .font(Tokens.labelFont)
                .foregroundStyle(isOn ? Tokens.value : Tokens.label)
                .fixedSize()
                .turnedToHold()
                .frame(width: 46, height: 44)
                .background(isOn ? Tokens.surface : Color.clear, in: shape)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }

    private func toggleLock(_ control: ControlDial) {
        switch control {
        case .iso, .shutter: model.exposureLocked.toggle()
        case .whiteBalance: model.whiteBalanceLocked.toggle()
        case .focus:
            if isHeld(.focus) { model.releaseFocus() } else { model.focusLocked = true }
        }
    }

    private var tintStops: [ExposureScales.Stop] {
        fine ? ExposureScales.fineStops(linear: -150...150, step: 1, majorEvery: 10)
            : (-15...15).map { step in
                let named = step % 5 == 0
                return ExposureScales.Stop(
                    value: Double(step * 10), label: named ? "\(step * 10)" : "", isMajor: named)
            }
    }

    private var tintBinding: Binding<Double> {
        Binding(
            get: { Double(model.tint) },
            set: { value in
                model.tint = Float(value)
                if !model.whiteBalanceLocked { model.whiteBalanceLocked = true }
            })
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
