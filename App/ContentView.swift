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
                screen: screen, top: insets.top, bottom: insets.bottom, widescreen: model.widescreen,
                fullView: model.showsFullView)
            ZStack {
                Color.black
                viewfinder(layout.picture.size)
                    .position(x: layout.picture.midX, y: layout.picture.midY)
                CameraHUD(
                    selectedDial: $selectedDial, showMonitor: $showMonitor, hold: hold.hold,
                    insets: insets, stripDepth: screen.height - layout.picture.maxY,
                    openSettings: { showSettings = true })
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
        .sensoryFeedback(.warning, trigger: model.takeAlert) { _, alert in alert != nil }
        .modifier(VolumeRecord {
            if !showSettings, model.playingTake == nil, model.isBusy == nil { model.toggleRecord() }
        })
        .onChange(of: model.isRecording) { _, recording in
            // Any focus change during a take costs frames.
            if recording, selectedDial == .focus { selectedDial = nil }
        }
        .fullScreenCover(isPresented: $showSettings) {
            SettingsView()
        }
        .fullScreenCover(isPresented: Binding(
            get: { model.playingTake != nil },
            set: { if !$0 { model.closeLastTake() } }
        )) {
            if let url = model.playingTake {
                TakePlayer(url: url)
            }
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

    /// Tools for testing. Notices stay off the picture, over the controls.
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
    /// What's left beneath the picture.
    let stripDepth: CGFloat
    let openSettings: () -> Void

    var body: some View {
        if model.showsFullView {
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                fullViewRow
                    .padding(.bottom, (stripDepth - CameraGeometry.recordDepth) / 2)
            }
            .padding(.leading, max(insets.leading, 12))
            .padding(.trailing, max(insets.trailing, 12))
        } else {
            controls
        }
    }

    private var controls: some View {
        ZStack(alignment: .top) {
            VStack(spacing: 8) {
                Spacer(minLength: 0)
                VStack(spacing: 8) {
                    if showMonitor, model.processing.monitor != .isp {
                        MonitorPanel(hold: hold)
                    } else if selectedDial == nil {
                        // An open dial takes this row's place, which keeps both off the picture.
                        toolRow
                    }
                    ControlPanels(selected: $selectedDial, hold: hold)
                }
                .overlay { noticeCard }
                actionRow
            }
            .padding(.bottom, max(insets.bottom, 10))
            .padding(.leading, max(insets.leading, 12))
            .padding(.trailing, max(insets.trailing, 12))
            StatusBlocks(hold: hold)
        }
        .onChange(of: selectedDial) { _, dial in
            if dial != nil { showMonitor = false }
        }
    }

    /// Five columns, matching the bars above.
    private func columns<Content: View>(
        @ViewBuilder content: @escaping (CGFloat) -> Content
    ) -> some View {
        GeometryReader { geometry in
            content(geometry.size.width / 5)
        }
        .frame(height: CameraGeometry.recordDepth)
    }

    private var actionRow: some View {
        columns { column in
            HStack(spacing: 0) {
                lastTakeSlot
                    .frame(width: column)
                monitorButton
                    .frame(width: column)
                recordButton
                    .frame(width: column)
                trailingSlots(column)
            }
        }
    }

    /// All that's left in Full view, in the same columns.
    private var fullViewRow: some View {
        columns { column in
            HStack(spacing: 0) {
                if let notice = model.notice {
                    Text(notice)
                        .font(Tokens.statusFont)
                        .foregroundStyle(Tokens.value)
                        .lineLimit(4)
                        .minimumScaleFactor(0.7)
                        .upright(hold, depth: CameraGeometry.recordDepth - 2)
                        .frame(width: column * 2)
                } else {
                    RemainingLines(alignment: .leading)
                        .upright(hold, depth: CameraGeometry.recordDepth - 2)
                        .frame(width: column)
                    fullViewButton
                        .frame(width: column)
                }
                recordButton
                    .frame(width: column)
                trailingSlots(column)
            }
        }
    }

    private var recordButton: some View {
        RecordButton(isRecording: model.isRecording) { model.toggleRecord() }
            .disabled(model.isBusy != nil)
    }

    /// The clock takes both columns, in the same place in every hold.
    @ViewBuilder
    private func trailingSlots(_ column: CGFloat) -> some View {
        if model.isRecording {
            timecode
                .frame(width: column * 2)
        } else {
            Color.clear
                .frame(width: column)
            formatButton
                .frame(width: column)
        }
    }

    /// Sideways, only the record row's depth is free, so hours go until they're needed.
    private var timecode: some View {
        Text(hold.isLandscape ? model.shortTimecodeLabel : model.timecodeLabel)
            .font(hold.isLandscape ? Tokens.sidewaysClockFont : Tokens.clockFont)
            .foregroundStyle(Tokens.recordText)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .upright(hold, depth: CameraGeometry.recordDepth)
            .accessibilityLabel("Recording, \(model.recordElapsed) seconds")
    }

    /// A take that ended outranks a passing message.
    @ViewBuilder
    private var noticeCard: some View {
        if let alert = model.takeAlert {
            NoticeCard(title: alert.title, detail: alert.detail, isUrgent: true, hold: hold) {
                model.takeAlert = nil
            }
        } else if let notice = model.notice {
            NoticeCard(title: notice, detail: nil, isUrgent: false, hold: hold) {
                model.notice = nil
            }
        }
    }

    @ViewBuilder
    private var lastTakeSlot: some View {
        if let take = model.lastTake, !model.isRecording {
            Button {
                model.openLastTake()
            } label: {
                Image(uiImage: take.thumbnail)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 52, height: 52)
                    .clipShape(RoundedRectangle(cornerRadius: Tokens.panelRadius))
                    .overlay(
                        RoundedRectangle(cornerRadius: Tokens.panelRadius)
                            .strokeBorder(Tokens.hairline, lineWidth: 0.5)
                    )
                    .turnedToHold()
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(model.isBusy != nil)
            .accessibilityLabel("Play last take")
        } else {
            Color.clear
        }
    }

    /// The offset, the monitoring tools that are on, then the lenses.
    private var toolRow: some View {
        HStack(spacing: 0) {
            if model.widescreen {
                fullViewButton
            }
            if let offset = model.exposureOffsetLabel {
                Button {
                    model.exposureBias = 0
                } label: {
                    VStack(spacing: 0) {
                        Text("EV")
                            .font(Tokens.labelFont)
                            .foregroundStyle(Tokens.label)
                        Text(offset)
                            .font(Tokens.lineFont)
                            .foregroundStyle(Tokens.held)
                    }
                    .turnedToHold()
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                // A bias change was cut short by the writer failure, so it stays off during a take.
                .disabled(model.isRecording)
                .accessibilityLabel("Exposure offset \(offset) stops")
                .accessibilityHint(model.isRecording ? "" : "Resets to zero")
            }
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

    private var fullViewButton: some View {
        Button {
            model.fullView.toggle()
        } label: {
            Image(systemName: model.fullView
                ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                .font(.system(size: 14))
                .foregroundStyle(Tokens.value)
                .turnedToHold()
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(model.isBusy != nil)
        .accessibilityLabel(model.fullView ? "Show all controls" : "Full view")
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
                title: "FMT", value: model.aspectLabel, tint: Tokens.value, hold: hold,
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
                    title: "MON", value: model.monitorLabel,
                    tint: isActive ? Tokens.held : Tokens.value, hold: hold,
                    depth: CameraGeometry.controlBarDepth
                )
                .frame(height: CameraGeometry.controlBarDepth)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .instrumentPanel()
            .accessibilityLabel("Monitoring tools")
            .accessibilityValue(model.monitorName)
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

/// One status line. A warning is a filled chip, so it stands apart from held values without
/// relying on telling amber from orange.
struct StatusLine: View {
    let text: String
    var tint = Tokens.value
    var warns = false

    var body: some View {
        Text(text)
            .font(Tokens.statusFont)
            .foregroundStyle(warns ? Color.black : tint)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .padding(.horizontal, warns ? 4 : 0)
            .background(
                warns ? Tokens.warning : Color.clear, in: RoundedRectangle(cornerRadius: 3))
    }
}

/// What's left to shoot on, and how the take is going.
struct RemainingLines: View {
    @EnvironmentObject private var model: AppModel
    let alignment: HorizontalAlignment

    var body: some View {
        VStack(alignment: alignment, spacing: 1) {
            StatusLine(text: "\(model.timeLeftLabel) LEFT", warns: model.isStorageLow)
            StatusLine(text: "BATT \(model.batteryLabel)", warns: model.isBatteryLow)
            if model.showsHeat {
                StatusLine(text: "HEAT \(model.heatLabel)", warns: model.isHot)
            }
            if model.isRecording {
                StatusLine(text: "\(model.takeDrops) DROP", warns: model.takeDrops > 0)
            }
        }
    }
}

/// The format and what's left, in the corners beside the Dynamic Island. Each block turns as a
/// square, which leaves its lines the same width sideways.
struct StatusBlocks: View {
    @EnvironmentObject private var model: AppModel
    let hold: Hold

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            block(.topLeading) {
                VStack(alignment: .leading, spacing: 1) {
                    StatusLine(text: model.codecLabel, tint: Tokens.label)
                    StatusLine(text: model.curveLabel, tint: Tokens.label)
                    StatusLine(text: model.outputLabel, tint: Tokens.label)
                    StatusLine(
                        text: "\(model.aspectLabel) · \(Int(model.frameRate))", tint: Tokens.label)
                }
            }
            Spacer(minLength: 0)
            block(hold.isLandscape ? .topLeading : .topTrailing) {
                RemainingLines(alignment: hold.isLandscape ? .leading : .trailing)
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, CameraGeometry.statusTop)
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
    }

    private func block<Content: View>(
        _ alignment: Alignment, @ViewBuilder content: () -> Content
    ) -> some View {
        content()
            .frame(
                width: CameraGeometry.statusSide, height: CameraGeometry.statusSide,
                alignment: alignment
            )
            .turnedToHold()
    }
}

/// A message over the tool row and control bar, large enough to read at arm's length. Tapping it
/// clears it.
struct NoticeCard: View {
    let title: String
    let detail: String?
    let isUrgent: Bool
    let hold: Hold
    let dismiss: () -> Void

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Tokens.panelRadius)
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(isUrgent ? Tokens.noticeTitleFont : Tokens.noticeFont)
                if let detail {
                    Text(detail)
                        .font(Tokens.noticeFont)
                }
            }
            .foregroundStyle(isUrgent ? Color.black : Tokens.value)
            .multilineTextAlignment(.leading)
            // Sideways the lines run along the card, past the height it offers.
            .fixedSize(horizontal: false, vertical: true)
            .upright(hold, depth: CameraGeometry.noticeDepth - 12)
            .frame(maxWidth: .infinity, alignment: hold.isLandscape ? .center : .leading)
            if isUrgent {
                Button(action: dismiss) {
                    Text("OK")
                        .font(Tokens.valueFont)
                        .foregroundStyle(Tokens.value)
                        .turnedToHold()
                        .frame(width: 56, height: 44)
                        .background(Color.black, in: RoundedRectangle(cornerRadius: Tokens.panelRadius))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss")
            }
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(isUrgent ? Tokens.warning : Tokens.opaquePanel, in: shape)
        .overlay(shape.strokeBorder(Tokens.hairline, lineWidth: 0.5))
        .contentShape(shape)
        .onTapGesture(perform: dismiss)
        .accessibilityElement(children: .combine)
    }
}

/// The monitor look and tools, in the dial's place, so exposure stays reachable while judging it.
struct MonitorPanel: View {
    @EnvironmentObject private var model: AppModel
    let hold: Hold

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Tokens.panelRadius)
        HStack(spacing: 0) {
            lookButton
            ForEach(Tool.allCases) { tool in
                toolButton(tool)
            }
        }
        .frame(height: CameraGeometry.trayDepth)
        .background(Tokens.opaquePanel, in: shape)
        .overlay(shape.strokeBorder(Tokens.hairline, lineWidth: 0.5))
        .contentShape(shape)
    }

    private var lookButton: some View {
        Button {
            model.processing.monitor = model.processing.monitor == .log ? .rec709 : .log
        } label: {
            VStack(spacing: 3) {
                Text(model.monitorLabel)
                    .font(Tokens.lineFont)
                    .foregroundStyle(Tokens.held)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text("LOOK")
                    .font(Tokens.labelFont)
                    .foregroundStyle(Tokens.label)
            }
            .upright(hold, depth: 46)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Tokens.hairline)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Monitor look")
        .accessibilityValue(model.monitorName)
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
            .upright(hold, depth: 46)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(tool.title)
        .accessibilityAddTraits(model.isOn(tool) ? .isSelected : [])
    }
}

/// Plays a take full screen. The clip carries its own rotation.
struct TakePlayer: View {
    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer

    init(url: URL) {
        _player = State(initialValue: AVPlayer(url: url))
    }

    var body: some View {
        VideoPlayer(player: player)
            .ignoresSafeArea()
            .overlay(alignment: .topLeading) {
                Button("Done") { dismiss() }
                    .font(Tokens.valueFont)
                    .foregroundStyle(Tokens.value)
                    .frame(minWidth: 64, minHeight: 44)
                    .background(Tokens.opaquePanel, in: RoundedRectangle(cornerRadius: Tokens.panelRadius))
                    .padding(12)
            }
            .background(Color.black)
            .onAppear { player.play() }
            .onDisappear { player.pause() }
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
