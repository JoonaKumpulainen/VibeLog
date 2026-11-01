import AVKit
import SwiftUI
import VLCapture
import VLProcessing

struct ContentView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        CameraScreen(hold: model.hold)
            .alert("Camera access is off", isPresented: $model.permissionDenied) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Allow camera access for VibeLog in Settings.")
            }
    }
}

struct CameraScreen: View {
    @EnvironmentObject private var model: AppModel
    @AppStorage("debugOverlay") private var showDebugOverlay = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject var hold: HoldTracker
    @State private var showSettings = false
    @State private var showMonitor = false
    @State private var selectedDial: ControlDial?
    @State private var focusMark: CGPoint?
    @State private var hideFocusMark: Task<Void, Never>?
    @State private var biasAtDragStart: Float?

    var body: some View {
        GeometryReader { geometry in
            let insets = geometry.safeAreaInsets
            let screen = CGSize(
                width: geometry.size.width + insets.leading + insets.trailing,
                height: geometry.size.height + insets.top + insets.bottom)
            let layout = CameraGeometry(
                screen: screen, top: insets.top, bottom: insets.bottom, widescreen: model.widescreen)
            ZStack {
                Color.black
                viewfinder(layout.picture.size)
                    .position(x: layout.picture.midX, y: layout.picture.midY)
                CameraHUD(
                    selectedDial: $selectedDial, showMonitor: $showMonitor, hold: hold.hold,
                    insets: insets, openSettings: { showSettings = true })
            }
            .environment(\.heldTurn, hold.turn)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: hold.turn)
            .frame(width: screen.width, height: screen.height)
            .ignoresSafeArea()
        }
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .sensoryFeedback(.impact(weight: .medium), trigger: model.isRecording)
        .sensoryFeedback(.selection, trigger: model.lensID)
        .modifier(VolumeRecord {
            if !showSettings, model.isBusy == nil { model.toggleRecord() }
        })
        .onChange(of: model.isRecording) { _, recording in
            // Any focus change during a take costs frames.
            if recording, selectedDial == .focus { selectedDial = nil }
        }
        .fullScreenCover(isPresented: $showSettings) {
            SettingsView()
        }
    }

    /// The sensor stays fixed to the phone, so the picture is upright in every hold. 16:9 keeps
    /// three quarters of the sensor height, which is the picture's width.
    private func viewfinder(_ size: CGSize) -> some View {
        ZStack {
            SessionPreview(session: model.camera.session)
            if let pipeline = model.pipeline, model.method.isPhoto,
                model.processing.enabled, model.processing.monitor != .isp {
                ProcessedMonitor(pipeline: pipeline)
            }
            touchLayer
        }
        .frame(width: size.height * 3 / 4, height: size.height)
        .scaleEffect(model.isOn(.punchIn) ? 3 : 1)
        .frame(width: size.width, height: size.height)
        .clipped()
        .overlay {
            FrameMarks()
                .stroke(.white.opacity(0.7), lineWidth: 1)
                .allowsHitTesting(false)
            LiveFrameGuides(
                level: hold.level, grid: model.isOn(.grid), center: model.isOn(.center),
                showsLevel: model.isOn(.level), gravityDegrees: hold.hold.gravityDegrees)
            if model.isRecording {
                Rectangle()
                    .strokeBorder(Tokens.record, lineWidth: 2)
                    .allowsHitTesting(false)
            }
            HeldLayout(hold: hold.hold, screen: size, insets: EdgeInsets()) { _ in
                messages
            }
            .allowsHitTesting(false)
        }
    }

    /// Tools for testing. Notices stay off the picture, beside the record button.
    private var messages: some View {
        VStack(spacing: 8) {
            if showDebugOverlay {
                DebugOverlay()
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let busy = model.isBusy {
                ProgressView(busy)
                    .font(Tokens.lineFont)
                    .padding(10)
                    .instrumentPanel()
            }
            Spacer(minLength: 0)
        }
        .padding(16)
    }

    private var touchLayer: some View {
        GeometryReader { geometry in
            ZStack {
                Color.clear
                    .contentShape(Rectangle())
                    .gesture(SpatialTapGesture().onEnded { tap($0.location, in: geometry.size) })
                    .simultaneousGesture(exposureDrag)
                    .simultaneousGesture(lensPinch)
                if let focusMark {
                    FocusMark(bias: model.exposureBias, showsBias: !model.exposureLocked)
                        .turnedToHold()
                        .position(focusMark)
                        .allowsHitTesting(false)
                }
            }
        }
        .disabled(model.isBusy != nil)
    }

    private func tap(_ location: CGPoint, in size: CGSize) {
        guard !model.isRecording else { return }
        // The sensor's top left is the portrait view's top right.
        model.focus(at: CGPoint(x: location.y / size.height, y: 1 - location.x / size.width))
        showFocusMark(at: location)
    }

    private func showFocusMark(at location: CGPoint) {
        focusMark = location
        hideFocusMark?.cancel()
        hideFocusMark = Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            if !Task.isCancelled { focusMark = nil }
        }
    }

    /// Dragging after a tap sets exposure. Up means up as the phone is held.
    private var exposureDrag: some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { drag in
                guard let focusMark, !model.exposureLocked, !model.isRecording else { return }
                let start = biasAtDragStart ?? model.exposureBias
                biasAtDragStart = start
                let angle = hold.hold.angle * .pi / 180
                let up = sin(angle) * drag.translation.width - cos(angle) * drag.translation.height
                model.exposureBias = min(max(start + Float(up) / 100, -2), 2)
                showFocusMark(at: focusMark)
            }
            .onEnded { _ in biasAtDragStart = nil }
    }

    private var lensPinch: some Gesture {
        MagnifyGesture().onEnded { pinch in
            let lenses = model.lenses.sorted { $0.zoom < $1.zoom }
            guard !model.isRecording, let index = lenses.firstIndex(where: { $0.id == model.lensID })
            else { return }
            if pinch.magnification > 1.3, index + 1 < lenses.count {
                model.lensID = lenses[index + 1].id
            } else if pinch.magnification < 0.77, index > 0 {
                model.lensID = lenses[index - 1].id
            }
        }
    }
}

/// Every control, in one place for every hold. Turning the phone only turns each control's
/// contents, so nothing moves onto the picture.
struct CameraHUD: View {
    @EnvironmentObject private var model: AppModel
    @Binding var selectedDial: ControlDial?
    @Binding var showMonitor: Bool
    let hold: Hold
    let insets: EdgeInsets
    let openSettings: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            TopBar(hold: hold)
            Spacer(minLength: 0)
            VStack(spacing: 8) {
                if showMonitor, model.processing.monitor != .isp {
                    MonitorPanel(hold: hold)
                } else {
                    // An open dial takes this row's place, which keeps both off the picture.
                    if selectedDial == nil { toolRow }
                    ControlPanels(selected: $selectedDial, hold: hold)
                }
                actionRow
            }
        }
        .padding(.top, max(insets.top, 10))
        .padding(.bottom, max(insets.bottom, 10))
        .padding(.leading, max(insets.leading, 12))
        .padding(.trailing, max(insets.trailing, 12))
    }

    /// Five columns, matching the bars above.
    private var actionRow: some View {
        HStack(spacing: 0) {
            monitorButton
                .frame(maxWidth: .infinity)
            Color.clear
                .frame(maxWidth: .infinity)
            RecordButton(isRecording: model.isRecording) { model.toggleRecord() }
                .disabled(model.isBusy != nil)
                .frame(maxWidth: .infinity)
            noticeSlot
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .allowsHitTesting(false)
            formatSlot
                .frame(maxWidth: .infinity)
        }
        .frame(height: 68)
    }

    @ViewBuilder
    private var noticeSlot: some View {
        if let notice = model.notice {
            Text(notice)
                .font(Tokens.labelFont)
                .foregroundStyle(Tokens.value)
                .multilineTextAlignment(.center)
                .lineLimit(5)
                .minimumScaleFactor(0.7)
                .upright(hold, depth: 64)
                .padding(2)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(
                    Tokens.opaquePanel, in: RoundedRectangle(cornerRadius: Tokens.panelRadius)
                )
                .padding(.horizontal, 2)
        }
    }

    /// Sideways, the top bar's cells are too narrow for the clock during a take.
    @ViewBuilder
    private var formatSlot: some View {
        if !model.isRecording {
            formatButton
        } else if hold.isLandscape {
            Text(model.timecodeLabel)
                .font(Tokens.clockFont)
                .foregroundStyle(Tokens.record)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .upright(hold, depth: 66)
                .accessibilityLabel("Recording, \(model.recordElapsed) seconds")
        }
    }

    /// The monitoring tools that are on, then the lenses.
    private var toolRow: some View {
        HStack(spacing: 0) {
            ForEach(Tool.allCases.filter(model.isOn)) { tool in
                Image(systemName: tool.symbol)
                    .font(.system(size: 14))
                    .foregroundStyle(Tokens.held)
                    .turnedToHold()
                    .frame(width: 30, height: 44)
                    .accessibilityLabel("\(tool.title) is on")
            }
            Spacer(minLength: 0)
            lensPill
        }
    }

    @ViewBuilder
    private var lensPill: some View {
        if model.lenses.count > 1 {
            HStack(spacing: 0) {
                ForEach(model.lenses.sorted { $0.zoom < $1.zoom }) { lens in
                    let selected = lens.id == model.lensID
                    Button {
                        model.lensID = lens.id
                    } label: {
                        Text(lens.zoomLabel)
                            .font(Tokens.lineFont)
                            .foregroundStyle(selected ? Tokens.held : Tokens.value)
                            .fixedSize()
                            .turnedToHold()
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(lens.name)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
            .instrumentPanel()
            // Changing lens rebuilds the capture session, which would end a recording.
            .disabled(model.isRecording || model.isBusy != nil)
            .opacity(model.isRecording ? 0 : 1)
            .accessibilityHidden(model.isRecording)
        }
    }

    private var formatButton: some View {
        Button(action: openSettings) {
            InstrumentCell(
                title: "FMT", value: model.widescreen ? "16:9" : "4:3", tint: Tokens.value, hold: hold,
                depth: CameraGeometry.controlBarDepth
            )
            .frame(height: CameraGeometry.controlBarDepth)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .instrumentPanel()
        .disabled(model.isBusy != nil)
        .accessibilityLabel("Format and settings")
    }

    /// Only changes what the monitor draws, so it stays available while recording. The ISP
    /// monitor removes the Metal view these tools draw on.
    @ViewBuilder
    private var monitorButton: some View {
        if model.processing.monitor != .isp {
            let isActive = showMonitor || Tool.allCases.contains(where: model.isOn)
            Button {
                selectedDial = nil
                withAnimation(.easeOut(duration: 0.15)) { showMonitor.toggle() }
            } label: {
                InstrumentCell(
                    title: "MON", value: model.processing.monitor == .log ? "LOG" : "709",
                    tint: isActive ? Tokens.held : Tokens.value, hold: hold,
                    depth: CameraGeometry.controlBarDepth
                )
                .frame(height: CameraGeometry.controlBarDepth)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .instrumentPanel()
            .accessibilityLabel("Monitoring tools")
            .accessibilityValue(model.processing.monitor.label)
            .accessibilityAddTraits(showMonitor ? .isSelected : [])
        } else {
            Color.clear.frame(height: CameraGeometry.controlBarDepth)
        }
    }
}

/// Starts and stops a take from the volume buttons, or the Action button if it's set to Camera.
/// This takes the buttons over while the camera is running.
private struct VolumeRecord: ViewModifier {
    let action: () -> Void

    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.onCameraCaptureEvent { event in
                if event.phase == .ended { action() }
            }
        } else {
            content
        }
    }
}

/// The format and how long it can run, or the state of the take. Its columns line up with the
/// control bar beneath the picture.
struct TopBar: View {
    @EnvironmentObject private var model: AppModel
    let hold: Hold

    var body: some View {
        HStack(spacing: 0) {
            if model.isRecording {
                // Sideways, the clock takes the format button's place.
                reading("REC", hold.isLandscape ? "●" : model.timecodeLabel, tint: Tokens.record)
                divider
                timeLeft
                divider
                battery
                divider
                heat
                divider
                reading(
                    "DROP", "\(model.takeDrops)", tint: model.takeDrops > 0 ? Tokens.warning : Tokens.value)
            } else {
                reading("CODEC", model.codecLabel)
                divider
                reading("LOG", model.curveLabel)
                divider
                if model.isHot {
                    heat
                } else {
                    reading("SIZE", hold.isLandscape ? model.megapixelLabel : model.outputLabel)
                }
                divider
                timeLeft
                divider
                battery
            }
        }
        .frame(height: CameraGeometry.topBarDepth)
        .instrumentPanel()
        .accessibilityElement(children: .combine)
    }

    private var timeLeft: some View {
        reading("LEFT", model.timeLeftLabel, tint: model.isStorageLow ? Tokens.warning : Tokens.value)
    }

    private var battery: some View {
        reading("BATT", model.batteryLabel, tint: model.isBatteryLow ? Tokens.warning : Tokens.value)
    }

    private var heat: some View {
        reading("HEAT", model.heatLabel, tint: model.isHot ? Tokens.warning : Tokens.value)
    }

    private var divider: some View {
        Rectangle().fill(Tokens.hairline).frame(width: 0.5)
    }

    private func reading(_ title: String, _ value: String, tint: Color = Tokens.value) -> some View {
        InstrumentCell(
            title: title, value: value, tint: tint, hold: hold, depth: CameraGeometry.topBarDepth)
    }
}

/// An opaque panel in the controls' place, so the tools can be judged on the whole picture.
struct MonitorPanel: View {
    @EnvironmentObject private var model: AppModel
    let hold: Hold

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Tokens.panelRadius)
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach([MonitorMode.rec709, .log]) { mode in
                    modeButton(mode)
                }
            }
            .frame(height: 44)
            Rectangle().fill(Tokens.hairline).frame(height: 0.5)
            HStack(spacing: 0) {
                ForEach(Tool.allCases) { tool in
                    toolButton(tool)
                }
            }
            .frame(maxHeight: .infinity)
        }
        .frame(height: CameraGeometry.monitorDepth)
        .background(Tokens.opaquePanel, in: shape)
        .overlay(shape.strokeBorder(Tokens.hairline, lineWidth: 0.5))
        .contentShape(shape)
    }

    private func modeButton(_ mode: MonitorMode) -> some View {
        let selected = model.processing.monitor == mode
        return Button {
            model.processing.monitor = mode
        } label: {
            Text(mode.label)
                .font(Tokens.lineFont)
                .foregroundStyle(selected ? Tokens.held : Tokens.value)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .upright(hold, depth: 42)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(selected ? Tokens.hairline : Color.clear)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Monitor \(mode.label)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func toolButton(_ tool: Tool) -> some View {
        Button {
            model.toggle(tool)
        } label: {
            VStack(spacing: 3) {
                Image(systemName: tool.symbol)
                    .font(.system(size: 16))
                Text(tool.shortTitle)
                    .font(Tokens.labelFont)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .foregroundStyle(model.isOn(tool) ? Tokens.held : Tokens.value)
            .upright(hold, depth: 52)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(tool.title)
        .accessibilityAddTraits(model.isOn(tool) ? .isSelected : [])
    }
}

struct FocusMark: View {
    let bias: Float
    let showsBias: Bool

    var body: some View {
        Rectangle()
            .strokeBorder(Tokens.held, lineWidth: 1)
            .frame(width: 72, height: 72)
            .overlay(alignment: .trailing) {
                if showsBias {
                    Image(systemName: "sun.max")
                        .font(.caption)
                        .foregroundStyle(Tokens.held)
                        .offset(x: 22, y: CGFloat(-bias) * 18)
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
                RoundedRectangle(cornerRadius: isRecording ? 4 : 28)
                    .fill(Tokens.record)
                    .frame(width: isRecording ? 26 : 56, height: isRecording ? 26 : 56)
            }
            .frame(width: 68, height: 68)
            .contentShape(Circle())
            .animation(.easeOut(duration: 0.15), value: isRecording)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isRecording ? "Stop recording" : "Record")
    }
}

extension LensInfo {
    /// Names start with their zoom, as in "0.5x Ultra Wide".
    var zoomLabel: String { String(name.prefix { $0 != " " }) }
    var zoom: Double { Double(zoomLabel.dropLast()) ?? 1 }
}
