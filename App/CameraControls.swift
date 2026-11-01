import SwiftUI
import VLCore

enum ControlDial: CaseIterable, Identifiable {
    case shutter, iso, whiteBalance, focus

    var id: Self { self }
}

/// All controls, on black beneath the picture. Rows and columns divide their space evenly, so
/// every layout stays symmetric.
struct ControlBand: View {
    @EnvironmentObject private var model: AppModel
    @State private var selected: ControlDial?
    @State private var showToolsInCompact = false
    let hold: Hold
    let isCompact: Bool
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

    private var portrait: some View {
        VStack(spacing: 0) {
            if !isCompact {
                evenly { StatusLine() }
                evenly { ToolRow(axis: .horizontal) }
            }
            evenly {
                if isCompact && showToolsInCompact {
                    ToolRow(axis: .horizontal)
                } else {
                    ControlPanel(selected: $selected, axis: .horizontal)
                }
            }
            evenly { actionRow }
        }
        .padding(.horizontal, 12)
    }

    private func evenly<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content().frame(maxHeight: .infinity)
    }

    /// The record column stays on the outer edge, under the thumb.
    private var landscape: some View {
        HStack(spacing: 0) {
            if hold == .landscapeRight { actionColumn }
            if !isCompact {
                ToolRow(axis: .vertical)
                    .frame(width: 48)
            }
            ControlPanel(selected: $selected, axis: .vertical)
                .frame(maxWidth: .infinity)
            if hold == .landscapeLeft { actionColumn }
        }
        .padding(.vertical, 12)
    }

    private var actionRow: some View {
        HStack(spacing: 0) {
            leadingActions
            recordButton.frame(maxWidth: .infinity)
            trailingActions
        }
    }

    private var actionColumn: some View {
        VStack(spacing: 0) {
            trailingActions
            recordButton.frame(maxHeight: .infinity)
            leadingActions
        }
        .frame(width: 76)
    }

    @ViewBuilder
    private var leadingActions: some View {
        if model.isRecording {
            RecordingClock().frame(maxWidth: .infinity, maxHeight: .infinity)
            Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            lensButton.frame(maxWidth: .infinity, maxHeight: .infinity)
            if isCompact {
                iconButton("slider.horizontal.3", label: "Tools", isOn: showToolsInCompact) {
                    showToolsInCompact.toggle()
                }
            } else {
                aspectButton
            }
        }
    }

    @ViewBuilder
    private var trailingActions: some View {
        if model.isRecording {
            if isCompact {
                iconButton("slider.horizontal.3", label: "Tools", isOn: showToolsInCompact) {
                    showToolsInCompact.toggle()
                }
            } else {
                monitorButton
            }
            Telemetry().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            monitorButton
            iconButton("gearshape", label: "Settings", isOn: false, action: openSettings)
        }
    }

    private var recordButton: some View {
        RecordButton(isRecording: model.isRecording) { model.toggleRecord() }
            .disabled(model.isBusy != nil)
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

/// One line of what the camera is set to and how long it can run.
struct StatusLine: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        HStack(spacing: 10) {
            Text(model.signalPath)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Spacer(minLength: 0)
            Label(model.timeLeftLabel, systemImage: "internaldrive")
            Label(model.batteryLabel, systemImage: "battery.75")
            if model.isHot {
                Image(systemName: "thermometer.high").foregroundStyle(Tokens.held)
            }
        }
        .labelStyle(CompactLabel())
        .font(Tokens.lineFont)
        .foregroundStyle(Tokens.label)
        .accessibilityElement(children: .combine)
    }
}

private struct CompactLabel: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 3) {
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

struct Telemetry: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        if model.showTelemetry {
            VStack(alignment: .trailing, spacing: 2) {
                Text(String(format: "%.2f FPS", model.stats.rollingFPS))
                Text(String(format: "%.0f MB/S", model.dataRate))
                Text(String(format: "GPU %.0f", model.pipelineStats.gpuRecentMs))
            }
            .font(Tokens.lineFont)
            .foregroundStyle(model.isHot ? Tokens.held : Tokens.label)
            .fixedSize()
        }
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

/// The read-outs, which give way to a dial in the same place.
struct ControlPanel: View {
    @EnvironmentObject private var model: AppModel
    @AppStorage("fineDial") private var fine = false
    @Binding var selected: ControlDial?
    let axis: Axis

    var body: some View {
        if let selected {
            dialPanel(selected)
                .transition(.opacity)
        } else {
            readouts
                .transition(.opacity)
        }
    }

    private var stack: AnyLayout {
        axis == .horizontal ? AnyLayout(HStackLayout(spacing: 0)) : AnyLayout(VStackLayout(spacing: 0))
    }

    private var readouts: some View {
        stack {
            cell(title: "FPS", value: "\(Int(model.frameRate))", held: false)
            ForEach(ControlDial.allCases) { control in
                Button {
                    open(control)
                } label: {
                    cell(title: title(control), value: value(control), held: isHeld(control))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(name(control))
                .accessibilityValue(value(control))
            }
        }
    }

    private func open(_ control: ControlDial) {
        // A focus rack lost half its frames during a take.
        if control == .focus, model.isRecording {
            let notice = "Focus is held during a recording"
            model.notice = notice
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                if model.notice == notice { model.notice = nil }
            }
            return
        }
        withAnimation(.easeOut(duration: 0.12)) { selected = control }
    }

    private func cell(title: String, value: String, held: Bool) -> some View {
        VStack(spacing: 2) {
            Text(title)
                .font(Tokens.labelFont)
                .foregroundStyle(Tokens.label)
            Text(value)
                .font(Tokens.valueFont)
                .foregroundStyle(held ? Tokens.held : Tokens.value)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        let buttons = Group {
            smallButton(isHeld(control) ? "lock" : "lock.open", isOn: isHeld(control),
                label: isHeld(control) ? "Unlock \(name(control))" : "Lock \(name(control))") {
                toggleLock(control)
            }
            smallButton("scope", isOn: fine, label: fine ? "Snap to stops" : "Fine adjustment") {
                fine.toggle()
            }
        }
        return stack {
            buttons
            Dial(
                stops: stops(control), value: binding(control), axis: axis, spacing: fine ? 7 : 44,
                label: name(control), valueText: value(control))
            smallButton("xmark", isOn: false, label: "Close \(name(control))") {
                withAnimation(.easeOut(duration: 0.12)) { selected = nil }
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

struct RecordButton: View {
    let isRecording: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .strokeBorder(Tokens.value, lineWidth: 2)
                RoundedRectangle(cornerRadius: isRecording ? 3 : 27)
                    .fill(Tokens.record)
                    .frame(width: isRecording ? 24 : 54, height: isRecording ? 24 : 54)
            }
            .frame(width: 64, height: 64)
            .contentShape(Circle())
            .animation(.easeOut(duration: 0.15), value: isRecording)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isRecording ? "Stop recording" : "Record")
    }
}
