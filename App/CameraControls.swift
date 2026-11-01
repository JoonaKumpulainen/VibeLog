import SwiftUI
import VLCore

enum ControlDial: CaseIterable, Identifiable {
    case shutter, iso, whiteBalance, focus

    var id: Self { self }
}

/// All controls, on black beneath the picture. The record button sits above this band in one
/// fixed place, so the band leaves a gap for it in every hold.
struct ControlBand: View {
    @EnvironmentObject private var model: AppModel
    @Binding var selected: ControlDial
    @Binding var showTools: Bool
    let hold: Hold
    let insets: EdgeInsets
    let openSettings: () -> Void

    var body: some View {
        Group {
            if hold.isLandscape {
                landscape
            } else {
                portrait
            }
        }
        .padding(.top, insets.top)
        .padding(.bottom, insets.bottom)
        .padding(.leading, insets.leading)
        .padding(.trailing, insets.trailing)
    }

    /// The action row stays on the phone's bottom edge, which is the top when upside down.
    private var portrait: some View {
        VStack(spacing: 0) {
            if hold == .upsideDown { actionRow }
            panel(.horizontal)
                .frame(maxHeight: .infinity)
            if hold != .upsideDown { actionRow }
        }
    }

    private var landscape: some View {
        HStack(spacing: 0) {
            if hold == .landscapeRight { actionColumn }
            panel(.vertical)
                .frame(maxWidth: .infinity)
            if hold == .landscapeLeft { actionColumn }
        }
    }

    @ViewBuilder
    private func panel(_ axis: Axis) -> some View {
        if showTools {
            ToolDrawer(axis: axis, openSettings: openSettings)
                .transition(.opacity)
        } else {
            ControlPanel(selected: $selected, axis: axis)
                .transition(.opacity)
        }
    }

    private var actionRow: some View {
        HStack(spacing: 0) {
            lensSlot
            Color.clear.frame(width: CameraGeometry.actionDepth)
            toolsButton
        }
        .frame(height: CameraGeometry.actionDepth)
    }

    private var actionColumn: some View {
        VStack(spacing: 0) {
            toolsButton
            Color.clear.frame(height: CameraGeometry.actionDepth)
            lensSlot
        }
        .frame(width: CameraGeometry.actionDepth)
    }

    @ViewBuilder
    private var lensSlot: some View {
        if model.isRecording {
            RecordingClock().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            lensButton
        }
    }

    private var toolsButton: some View {
        Button {
            withAnimation(.easeOut(duration: 0.12)) { showTools.toggle() }
        } label: {
            Image(systemName: "slider.horizontal.3")
                .font(Tokens.icon)
                .foregroundStyle(showTools ? Tokens.held : Tokens.value)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(showTools ? "Show dials" : "Show tools")
    }

    private var lensButton: some View {
        Button {
            model.nextLens()
        } label: {
            Text(model.currentLensLabel)
                .font(Tokens.valueFont)
                .foregroundStyle(Tokens.value)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Change lens")
        .disabled(model.isBusy != nil)
    }
}

/// Everything that isn't a dial, in the dials' place so it never covers the picture.
struct ToolDrawer: View {
    @EnvironmentObject private var model: AppModel
    let axis: Axis
    let openSettings: () -> Void

    var body: some View {
        let lines = axis == .horizontal
            ? AnyLayout(VStackLayout(spacing: 0)) : AnyLayout(HStackLayout(spacing: 0))
        let line = axis == .horizontal
            ? AnyLayout(HStackLayout(spacing: 0)) : AnyLayout(VStackLayout(spacing: 0))
        lines {
            ToolRow(axis: axis)
            line {
                if !model.isRecording { aspectButton }
                monitorButton
                if !model.isRecording {
                    iconButton("gearshape", label: "Settings", isOn: false, action: openSettings)
                }
            }
        }
    }

    private var aspectButton: some View {
        iconButton(
            model.widescreen ? "rectangle.ratio.16.to.9" : "rectangle.ratio.4.to.3",
            label: model.widescreen ? "16:9, change aspect" : "4:3, change aspect", isOn: false
        ) {
            model.widescreen.toggle()
        }
        .disabled(model.isBusy != nil)
    }

    /// Only changes what the monitor draws, so it stays available while recording.
    private var monitorButton: some View {
        iconButton(
            "camera.filters", label: model.processing.monitor == .log ? "Monitor log" : "Monitor Rec.709",
            isOn: model.processing.monitor == .log
        ) {
            model.processing.monitor = model.processing.monitor == .log ? .rec709 : .log
        }
    }

    private func iconButton(
        _ symbol: String, label: String, isOn: Bool, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(Tokens.icon)
                .foregroundStyle(isOn ? Tokens.held : Tokens.value)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

/// What the camera is set to and how long it can run, above the picture. Held sideways the band
/// is too narrow for a line, so only the short values stay, stacked.
struct StatusLine: View {
    @EnvironmentObject private var model: AppModel
    let hold: Hold

    var body: some View {
        Group {
            if hold.isLandscape {
                VStack(spacing: 16) {
                    if model.isRecording && model.showTelemetry {
                        Text(String(format: "%.1f", model.stats.rollingFPS))
                        Text(String(format: "%.0f", model.dataRate))
                    }
                    readings
                }
                .labelStyle(CompactLabel(axis: .vertical))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            } else {
                HStack(spacing: 10) {
                    Text(leadingText)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    Spacer(minLength: 0)
                    readings
                }
                .labelStyle(CompactLabel(axis: .horizontal))
                .padding(.horizontal, 16)
            }
        }
        .font(Tokens.lineFont)
        .foregroundStyle(Tokens.label)
        .accessibilityElement(children: .combine)
    }

    private var leadingText: String {
        guard model.isRecording, model.showTelemetry else { return model.signalPath }
        return String(
            format: "%.2f FPS  %.0f MB/S  GPU %.0f", model.stats.rollingFPS, model.dataRate,
            model.pipelineStats.gpuRecentMs)
    }

    @ViewBuilder
    private var readings: some View {
        Label(model.timeLeftLabel, systemImage: "internaldrive")
        Label(model.batteryLabel, systemImage: "battery.75")
        if model.isHot {
            Image(systemName: "thermometer.high").foregroundStyle(Tokens.held)
        }
    }
}

private struct CompactLabel: LabelStyle {
    let axis: Axis

    func makeBody(configuration: Configuration) -> some View {
        let layout = axis == .horizontal
            ? AnyLayout(HStackLayout(spacing: 3)) : AnyLayout(VStackLayout(spacing: 3))
        layout {
            configuration.icon
            configuration.title
        }
    }
}

struct RecordingClock: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        let elapsed = model.recordElapsed
        Text(String(format: "%02d:%02d:%02d", elapsed / 3600, elapsed / 60 % 60, elapsed % 60))
            .font(Tokens.valueFont)
            .foregroundStyle(Tokens.record)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .fixedSize(horizontal: true, vertical: false)
            .accessibilityLabel("Recording, \(elapsed) seconds")
    }
}

/// The toolbar set in the config file, spaced evenly along its row or column.
struct ToolRow: View {
    @EnvironmentObject private var model: AppModel
    let axis: Axis

    var body: some View {
        let tools = model.toolbar
        let layout = axis == .horizontal
            ? AnyLayout(HStackLayout(spacing: 0)) : AnyLayout(VStackLayout(spacing: 0))
        layout {
            ForEach(tools) { tool in
                Button {
                    model.toggle(tool)
                } label: {
                    Image(systemName: tool.symbol)
                        .font(Tokens.icon)
                        .foregroundStyle(model.isOn(tool) ? Tokens.held : Tokens.value)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(tool.title)
                .accessibilityAddTraits(model.isOn(tool) ? .isSelected : [])
            }
        }
    }
}

/// Four tabs that always show their values, over the one dial for the selected tab.
struct ControlPanel: View {
    @EnvironmentObject private var model: AppModel
    @AppStorage("fineDial") private var fine = false
    @Binding var selected: ControlDial
    let axis: Axis

    var body: some View {
        let horizontal = axis == .horizontal
        let lines = horizontal
            ? AnyLayout(VStackLayout(spacing: 0)) : AnyLayout(HStackLayout(spacing: 0))
        lines {
            tabs
                .frame(maxWidth: horizontal ? .infinity : 48, maxHeight: horizontal ? 46 : .infinity)
            dialRow
        }
    }

    private var stack: AnyLayout {
        axis == .horizontal ? AnyLayout(HStackLayout(spacing: 0)) : AnyLayout(VStackLayout(spacing: 0))
    }

    private var tabs: some View {
        stack {
            ForEach(ControlDial.allCases) { control in
                Button {
                    select(control)
                } label: {
                    cell(control)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(name(control))
                .accessibilityValue(value(control))
                .accessibilityAddTraits(selected == control ? .isSelected : [])
            }
        }
    }

    private func select(_ control: ControlDial) {
        // A focus rack lost half its frames during a take.
        if control == .focus, model.isRecording {
            let notice = "Focus is held during a recording"
            model.notice = notice
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                if model.notice == notice { model.notice = nil }
            }
            return
        }
        selected = control
    }

    private func cell(_ control: ControlDial) -> some View {
        VStack(spacing: 2) {
            Text(title(control))
                .font(Tokens.labelFont)
                .foregroundStyle(selected == control ? Tokens.value : Tokens.label)
            Text(value(control))
                .font(Tokens.valueFont)
                .foregroundStyle(isHeld(control) ? Tokens.held : Tokens.value)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: axis == .horizontal ? .bottom : .trailing) {
            if selected == control {
                Rectangle()
                    .fill(Tokens.value)
                    .frame(width: axis == .horizontal ? 28 : 1, height: axis == .horizontal ? 1 : 28)
            }
        }
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

    private var dialRow: some View {
        stack {
            smallButton(isHeld(selected) ? "lock" : "lock.open", isOn: isHeld(selected),
                label: isHeld(selected) ? "Unlock \(name(selected))" : "Lock \(name(selected))") {
                toggleLock(selected)
            }
            Dial(
                stops: stops(selected), value: binding(selected), axis: axis, spacing: fine ? 7 : 44,
                label: name(selected), valueText: value(selected))
            smallButton("scope", isOn: fine, label: fine ? "Snap to stops" : "Fine adjustment") {
                fine.toggle()
            }
        }
    }

    private func smallButton(
        _ symbol: String, isOn: Bool, label: String, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15))
                .foregroundStyle(isOn ? Tokens.held : Tokens.value)
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
    let axis: Axis
    let spacing: CGFloat
    let label: String
    let valueText: String

    init(
        stops: [ExposureScales.Stop], value: Binding<Double>, axis: Axis, spacing: CGFloat,
        label: String, valueText: String
    ) {
        self.stops = stops
        _value = value
        self.axis = axis
        self.spacing = spacing
        self.label = label
        self.valueText = valueText
    }

    private var position: Double { ExposureScales.position(of: value, in: stops) }

    var body: some View {
        Canvas { context, size in
            let horizontal = axis == .horizontal
            let length = horizontal ? size.width : size.height
            let depth = horizontal ? size.height : size.width
            let center = position
            let reach = Double(length / 2 / spacing) + 1
            for index in stops.indices where abs(Double(index) - center) <= reach {
                let stop = stops[index]
                let along = length / 2 + CGFloat(Double(index) - center) * spacing
                let tick = stop.isMajor ? depth * 0.34 : depth * 0.2
                var path = Path()
                if horizontal {
                    path.move(to: CGPoint(x: along, y: depth - tick))
                    path.addLine(to: CGPoint(x: along, y: depth))
                } else {
                    path.move(to: CGPoint(x: depth - tick, y: along))
                    path.addLine(to: CGPoint(x: depth, y: along))
                }
                context.stroke(path, with: .color(.white.opacity(stop.isMajor ? 0.9 : 0.45)), lineWidth: 0.5)
                guard !stop.label.isEmpty else { continue }
                let text = Text(stop.label).font(Tokens.lineFont)
                    .foregroundColor(abs(Double(index) - center) < 0.5 ? Tokens.held : Tokens.value)
                context.draw(
                    text, at: horizontal ? CGPoint(x: along, y: depth * 0.3) : CGPoint(x: depth * 0.3, y: along))
            }
            var mark = Path()
            if horizontal {
                mark.move(to: CGPoint(x: length / 2, y: depth * 0.5))
                mark.addLine(to: CGPoint(x: length / 2, y: depth))
            } else {
                mark.move(to: CGPoint(x: depth * 0.5, y: length / 2))
                mark.addLine(to: CGPoint(x: depth, y: length / 2))
            }
            context.stroke(mark, with: .color(Tokens.held), lineWidth: 1)
        }
        .clipped()
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 2)
                .onChanged { drag in
                    let start = dragStart ?? position
                    dragStart = start
                    let moved = axis == .horizontal ? drag.translation.width : drag.translation.height
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

/// Fills the phone's bottom-edge row, and stays in one place whatever the hold.
struct RecordButton: View {
    let isRecording: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .strokeBorder(Tokens.value, lineWidth: 3)
                RoundedRectangle(cornerRadius: isRecording ? 4 : 30)
                    .fill(Tokens.record)
                    .frame(width: isRecording ? 28 : 60, height: isRecording ? 28 : 60)
            }
            .frame(width: 72, height: 72)
            .contentShape(Circle())
            .animation(.easeOut(duration: 0.15), value: isRecording)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isRecording ? "Stop recording" : "Record")
    }
}
