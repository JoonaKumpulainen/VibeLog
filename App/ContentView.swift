import SwiftUI
import VLCapture
import VLCore
import VLProcessing
import VLRecording

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
    @State private var showFormat = false
    @State private var selectedDial: ControlDial?
    @State private var focusMark: CGPoint?
    @State private var hideFocusMark: Task<Void, Never>?
    @State private var biasAtDragStart: Float?
    @State private var punchAtDragStart: CGPoint?

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
                    selectedDial: $selectedDial, showMonitor: $showMonitor, showFormat: $showFormat,
                    hold: hold.hold, insets: insets, stripDepth: screen.height - layout.picture.maxY,
                    openSettings: {
                        model.settingsOpened()
                        showSettings = true
                    })
                // Fixed to the screen, so a row that runs too wide can't widen the stack and
                // move the picture.
                .frame(width: screen.width, height: screen.height)
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
            if recording { showFormat = false }
        }
        .sheet(isPresented: $showSettings, onDismiss: { model.settingsClosed() }) {
            SettingsView {
                model.fullView = false
                showFormat = true
            }
        }
        .background(TouchWatcher { model.noteTouch() })
        .overlay {
            if model.idlePaused {
                Color.black.opacity(0.001)
                    .contentShape(Rectangle())
                    .ignoresSafeArea()
                    .onTapGesture { model.cameraTouched() }
                    .accessibilityAddTraits(.isButton)
                    .accessibilityLabel("Resume camera")
            }
        }
        .onChange(of: selectedDial != nil || showFormat || showMonitor) { _, open in
            model.isCameraControlOpen = open
            model.noteTouch()
        }
        .onChange(of: model.playingTake != nil) { _, open in
            AppOrientation.allowTurning(open)
        }
        .fullScreenCover(isPresented: Binding(
            get: { model.playingTake != nil },
            set: { if !$0 { model.closeLastTake() } }
        )) {
            if let url = model.playingTake {
                TakeCover(url: url)
            }
        }
    }

    /// The sensor stays fixed to the phone, so the picture is upright in every hold. 16:9 keeps
    /// three quarters of the sensor height, which is the picture's width.
    private func viewfinder(_ size: CGSize) -> some View {
        ZStack {
            // Apple's picture would show until the first Metal draw, so it stays hidden behind it.
            SessionPreview(
                session: model.camera.session, hidden: model.monitorIsProcessed,
                connected: model.appPreviewConnected, holdsState: model.isRecording)
            if let pipeline = model.pipeline, model.monitorIsProcessed {
                ProcessedMonitor(pipeline: pipeline)
            }
            touchLayer
        }
        .frame(width: size.height * 3 / 4, height: size.height)
        // The Metal monitor punches in by itself, with real pixels.
        .scaleEffect(model.isOn(.punchIn) && !model.monitorIsProcessed ? 3 : 1)
        .frame(width: size.width, height: size.height)
        .clipped()
        .overlay {
            LiveFrameGuides(
                level: hold.level, grid: model.isOn(.grid), center: model.isOn(.center),
                showsLevel: model.isOn(.level), gravityDegrees: hold.hold.gravityDegrees,
                guideRatio: model.frameGuideRatio)
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
                    .background(Tokens.opaquePanel, in: RoundedRectangle(cornerRadius: Tokens.panelRadius))
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
                    .simultaneousGesture(pictureDrag(in: geometry.size))
                    .simultaneousGesture(lensPinch)
                    .accessibilityElement()
                    .accessibilityLabel("Viewfinder")
                    .accessibilityHint("Tap to focus and meter")
                    .accessibilityAddTraits(.allowsDirectInteraction)
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
        let share = model.pictureShare(
            ofView: CGPoint(x: location.x / size.width, y: location.y / size.height))
        // The sensor's top left is the portrait view's top right.
        model.focus(at: CGPoint(x: share.y, y: 1 - share.x))
        // Punch-in opens on what was last focused.
        if !model.isOn(.punchIn) { model.movePunch(to: share) }
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

    /// Dragging moves the punch-in. Otherwise, dragging after a tap sets exposure, where up means
    /// up as the phone is held.
    private func pictureDrag(in size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { drag in
                if model.isOn(.punchIn), model.monitorIsProcessed {
                    let start = punchAtDragStart ?? model.punchCenter
                    punchAtDragStart = start
                    let scale = AppModel.punchScale
                    model.movePunch(to: CGPoint(
                        x: start.x - drag.translation.width / size.width * scale,
                        y: start.y - drag.translation.height / size.height * scale))
                    return
                }
                guard let focusMark, !model.exposureLocked, !model.isRecording else { return }
                let start = biasAtDragStart ?? model.exposureBias
                biasAtDragStart = start
                let angle = hold.hold.angle * .pi / 180
                let up = sin(angle) * drag.translation.width - cos(angle) * drag.translation.height
                model.exposureBias = min(max(start + Float(up) / 100, -2), 2)
                showFocusMark(at: focusMark)
            }
            .onEnded { _ in
                biasAtDragStart = nil
                punchAtDragStart = nil
            }
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Binding var selectedDial: ControlDial?
    @Binding var showMonitor: Bool
    @Binding var showFormat: Bool
    /// The look panel, over the controls like Format, so the picture shows each LUT.
    @State private var showLook = false
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
            VStack(spacing: 5) {
                Spacer(minLength: 0)
                VStack(spacing: 3) {
                    // One tray above the control bar, so nothing else moves.
                    if showMonitor, model.processing.monitor != .isp {
                        MonitorPanel(hold: hold) {
                            model.openLookPanel()
                            withAnimation(lookFade) { showLook = true }
                        }
                        .transition(trayTransition)
                    } else if selectedDial == nil {
                        toolRow
                            .transition(trayTransition)
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
            if showFormat {
                // Tapping the picture closes the panel.
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { setFormat(false) }
                    .accessibilityHidden(true)
                VStack(spacing: 0) {
                    Spacer(minLength: 0)
                    FormatPanel(
                        hold: hold, bottomInset: max(insets.bottom, 10),
                        depth: stripDepth - CameraGeometry.formatGap)
                        .accessibilityAction(.escape) { setFormat(false) }
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .zIndex(1)
            }
            if showLook {
                // Holds touches off the picture and controls, so only Cancel or Select closes it.
                Color.clear
                    .contentShape(Rectangle())
                    .accessibilityHidden(true)
                VStack(spacing: 0) {
                    Spacer(minLength: 0)
                    LookPanel(
                        hold: hold, bottomInset: max(insets.bottom, 10),
                        depth: stripDepth - CameraGeometry.formatGap
                    ) { keep in
                        model.closeLookPanel(keep: keep)
                        withAnimation(lookFade) { showLook = false }
                    }
                    .accessibilityAction(.escape) {
                        model.closeLookPanel(keep: false)
                        showLook = false
                    }
                }
                // A fade in place. Sliding up over the controls showed both at once mid-way.
                .transition(.opacity)
                .zIndex(2)
            }
        }
        .onChange(of: selectedDial) { _, dial in
            if dial != nil { showMonitor = false }
        }
        .onChange(of: showLook) { _, open in
            model.isCameraControlOpen = open
            model.noteTouch()
        }
    }

    private var motion: Animation? {
        reduceMotion ? nil : .spring(duration: 0.35, bounce: 0.15)
    }

    private var lookFade: Animation? {
        reduceMotion ? nil : .easeOut(duration: 0.18)
    }

    private var trayTransition: AnyTransition {
        .opacity.combined(with: .scale(scale: 0.96))
    }

    private func setFormat(_ isOpen: Bool) {
        withAnimation(motion) { showFormat = isOpen }
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
            formatButton
                .frame(width: column)
            settingsButton
                .frame(width: column)
        }
    }

    /// The take's health sits with its clock. Sideways, only the record row's depth is free.
    private var timecode: some View {
        let label = model.timecodeLabel
        let width: CGFloat = hold.isLandscape ? CameraGeometry.recordDepth - 2 : 140
        return VStack(spacing: 1) {
            Text(label)
                .font(Tokens.clockFont(digits: label.count, width: width))
                .foregroundStyle(Tokens.recordText)
                .lineLimit(1)
                .accessibilityLabel("Recording, \(model.recordElapsed) seconds")
            StatusLine(text: "\(model.takeDrops) DROP", tint: Tokens.label, warns: model.takeDrops > 0)
        }
        .upright(hold, depth: CameraGeometry.recordDepth)
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
            .accessibilityHint("Opens the takes")
        } else {
            Color.clear
        }
    }

    /// The offset, the monitoring tools that are on, then the lenses. Tapping any of the first
    /// two clears it.
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
                Button {
                    model.toggle(tool)
                } label: {
                    Image(systemName: tool.symbol)
                        .font(.system(size: 16))
                        .foregroundStyle(Tokens.held)
                        .turnedToHold()
                        .frame(minWidth: 28, maxWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(tool.title) is on")
                .accessibilityHint("Turns it off")
            }
            Spacer(minLength: 0)
            // Changing lens rebuilds the capture session, which would end a recording.
            if !model.isRecording {
                lensPill
            } else if model.recordEncoded {
                // Sized before the tools, which shrink to fit. Shared out evenly, the tools took
                // their widest and pushed the row past the screen, which shifted the whole view.
                AudioMeter()
                    .layoutPriority(1)
            }
        }
        .frame(height: CameraGeometry.trayDepth)
    }

    private var fullViewButton: some View {
        Button {
            model.fullView.toggle()
        } label: {
            Image(systemName: model.fullView
                ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                .font(.system(size: 16))
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
                            .font(Tokens.smallValueFont)
                            .foregroundStyle(selected ? Tokens.held : Tokens.value)
                            .fixedSize()
                            .turnedToHold()
                            .frame(width: 44, height: 44)
                            .background(selected ? Tokens.surface : Color.clear, in: Circle())
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(lens.name)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
            .disabled(model.isBusy != nil)
        }
    }

    private var formatButton: some View {
        Button {
            selectedDial = nil
            showMonitor = false
            model.fullView = false
            setFormat(true)
        } label: {
            ActionCell(title: "FORMAT", value: model.aspectLabel, tint: Tokens.value, hold: hold)
        }
        .buttonStyle(.plain)
        .disabled(model.isBusy != nil)
        .accessibilityLabel("Format")
        .accessibilityValue(model.aspectLabel)
    }

    private var settingsButton: some View {
        Button(action: openSettings) {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 20))
                .foregroundStyle(Tokens.value)
                .turnedToHold()
                .frame(width: 52, height: 52)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(model.isBusy != nil)
        .accessibilityLabel("Settings")
    }

    /// Only changes what the monitor draws, so it stays available while recording. The ISP
    /// monitor removes the Metal view these tools draw on.
    @ViewBuilder
    private var monitorButton: some View {
        if model.processing.monitor != .isp {
            Button {
                selectedDial = nil
                withAnimation(motion) { showMonitor.toggle() }
            } label: {
                ActionCell(title: "MON", value: model.monitorLabel, tint: Tokens.value, hold: hold)
                    .background(
                        showMonitor ? Tokens.surface : Color.clear,
                        in: RoundedRectangle(cornerRadius: Tokens.panelRadius))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Monitoring tools")
            .accessibilityValue(model.monitorName)
            .accessibilityAddTraits(showMonitor ? .isSelected : [])
        } else {
            Color.clear
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

/// One status line. A warning is a filled chip that reaches past the text, so the line stays
/// aligned with its neighbors and stands apart from held values without relying on color alone.
struct StatusLine: View {
    let text: String
    var tint = Tokens.label
    var warns = false

    var body: some View {
        Text(text)
            .font(Tokens.statusFont)
            .foregroundStyle(warns ? Color.black : tint)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .background {
                if warns {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Tokens.warning)
                        .padding(.horizontal, -4)
                }
            }
    }
}

/// What's left to shoot on.
struct RemainingLines: View {
    @EnvironmentObject private var model: AppModel
    let alignment: HorizontalAlignment

    var body: some View {
        VStack(alignment: alignment, spacing: CameraGeometry.statusLineGap) {
            StatusLine(text: "\(model.timeLeftLabel) LEFT", warns: model.isStorageLow)
            StatusLine(text: "BATT \(model.batteryLabel)", warns: model.isBatteryLow)
            StatusLine(text: "HEAT \(model.heatLabel)", warns: model.isHot)
        }
    }
}

/// The format and what's left, mirrored either side of the Dynamic Island: three lines each, the
/// same width, centered in the depth above the picture. Each block turns as a square. Upright, it
/// keeps to its outer edge. Sideways, its lines center in the square, which keeps them equally far
/// from the Dynamic Island and clear of the screen's rounded corners.
struct StatusBlocks: View {
    @EnvironmentObject private var model: AppModel
    let hold: Hold

    private enum Side {
        case left, right
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            block(.left) { alignment in
                VStack(alignment: alignment, spacing: CameraGeometry.statusLineGap) {
                    StatusLine(text: model.codecLabel)
                    StatusLine(text: "\(model.curveLabel) \(model.frameRateLabel)P")
                    StatusLine(text: model.outputLabel)
                }
            }
            Spacer(minLength: 0)
            block(.right) { alignment in
                RemainingLines(alignment: alignment)
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, (CameraGeometry.statusDepth - CameraGeometry.statusSide) / 2)
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
    }

    /// Where the phone's sides end up as held, which turns "outer" into a direction.
    private func lineAlignment(_ side: Side) -> HorizontalAlignment {
        switch hold {
        case .portrait: return side == .left ? .leading : .trailing
        case .upsideDown: return side == .left ? .trailing : .leading
        case .landscapeLeft, .landscapeRight: return .center
        }
    }

    private func block<Content: View>(
        _ side: Side, @ViewBuilder content: (HorizontalAlignment) -> Content
    ) -> some View {
        let lines = lineAlignment(side)
        let edge = Alignment(horizontal: lines, vertical: .center)
        return content(lines)
            .frame(width: CameraGeometry.statusLineWidth, alignment: edge)
            .frame(width: CameraGeometry.statusSide, height: CameraGeometry.statusSide, alignment: edge)
            .turnedToHold()
    }
}

/// A message over the tray and control bar, large enough to read at arm's length. Tapping it
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
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        .accessibilityElement(children: .combine)
    }
}

/// The monitor look and tools, in the tray, so exposure stays reachable while judging it.
struct MonitorPanel: View {
    @EnvironmentObject private var model: AppModel
    let hold: Hold
    let openLook: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            lookButton
            ForEach(Tool.allCases) { tool in
                toolButton(tool)
            }
        }
        .frame(height: CameraGeometry.trayDepth)
        .contentShape(Rectangle())
    }

    /// Opens the look panel. Amber while the look is baked into takes, since then no log is recorded.
    private var lookButton: some View {
        Button(action: openLook) {
            VStack(spacing: 3) {
                Text(model.monitorLabel)
                    .font(Tokens.lineFont)
                    .foregroundStyle(model.bakeLook ? Tokens.held : Tokens.value)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text(model.bakeLook ? "BAKED" : "LOOK")
                    .font(Tokens.labelFont)
                    .foregroundStyle(model.bakeLook ? Tokens.held : Tokens.label)
            }
            .upright(hold, depth: 46)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Tokens.surface, in: RoundedRectangle(cornerRadius: Tokens.panelRadius))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Look")
        .accessibilityValue(model.bakeLook ? "\(model.monitorName), baked into takes" : model.monitorName)
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

/// The viewfinder's look: LOG, Rec.709 or a LUT, each shown on the picture as it reaches the
/// middle of the carousel. BAKE in the header records that look into takes. Cancel puts back what
/// was there, and Select keeps it. Every control keeps its place and turns with the hold.
struct LookPanel: View {
    @EnvironmentObject private var model: AppModel
    let hold: Hold
    let bottomInset: CGFloat
    /// From the screen's edge to just short of the picture.
    let depth: CGFloat
    let close: (Bool) -> Void
    @State private var choice = ""
    @State private var bake = false
    @State private var ready = false

    /// Not a file name, since those end in .cube.
    static let logChoice = "log"
    private static let headerDepth: CGFloat = 52

    private var bakeAllowed: Bool { !model.isRecording && choice != Self.logChoice }

    var body: some View {
        VStack(spacing: 0) {
            // No title: the LOOK cell that opened the panel already names it, and a turned title
            // had no room beside the toggle.
            HStack(spacing: 0) {
                headerButton("Cancel", weight: .regular) { close(false) }
                Spacer(minLength: 0)
                bakeToggle
                Spacer(minLength: 0)
                headerButton("Select", weight: .semibold) { close(true) }
            }
            .frame(height: Self.headerDepth)
            if ready {
                LookCarousel(
                    options: [Self.logChoice, ""] + model.lookNames, selection: $choice, hold: hold,
                    label: Self.label)
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, bottomInset)
        .frame(height: depth)
        .background(Tokens.opaquePanel)
        .onAppear {
            // The carousel opens on the current choice, so it's made once that's known.
            choice = model.processing.monitor == .log ? Self.logChoice : model.selectedLUT
            bake = model.bakeLook
            ready = true
        }
        .onChange(of: choice) { _, value in
            if value == Self.logChoice {
                model.processing.monitor = .log
                bake = false
            } else {
                model.processing.monitor = .rec709
                model.previewLUT(value)
            }
        }
        .onChange(of: bake) { _, on in if !model.isRecording { model.bakeLook = on } }
    }

    static func label(_ option: String) -> String {
        if option == logChoice { return "LOG" }
        if option.isEmpty { return "REC.709" }
        if BuiltInLook.named(option) != nil { return option }
        return (option as NSString).deletingPathExtension
    }

    private func headerButton(_ title: String, weight: Font.Weight, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(Tokens.statusFont.weight(weight))
                .foregroundStyle(Tokens.held)
                .fixedSize()
                .turnedToHold()
                .frame(width: 72, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Off for LOG, which baking would only record as log, and during a take. Only the label
    /// turns with the hold: a turned switch would slide the wrong way under a finger.
    private var bakeToggle: some View {
        HStack(spacing: 8) {
            Text("BAKE")
                .font(Tokens.labelFont)
                .foregroundStyle(bake ? Tokens.held : Tokens.label)
                .fixedSize()
                .turnedToHold()
            Toggle("BAKE", isOn: $bake)
                .labelsHidden()
                .tint(Tokens.held)
        }
        .fixedSize()
        .frame(width: 110, height: 44)
        .disabled(!bakeAllowed)
        .opacity(bakeAllowed ? 1 : 0.4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Bake the look into takes")
    }
}

/// Choices in a row that slides under a band, the middle one chosen as it settles. The row keeps
/// its upright layout in every hold, and only each name turns to read.
struct LookCarousel: View {
    let options: [String]
    @Binding var selection: String
    let hold: Hold
    let label: (String) -> String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var centered: String?

    /// Room for a name.
    private static let itemWidth: CGFloat = 128

    var body: some View {
        GeometryReader { geometry in
            let margin = max((geometry.size.width - Self.itemWidth) / 2, 0)
            ZStack {
                // The band the chosen name sits in.
                RoundedRectangle(cornerRadius: Tokens.panelRadius)
                    .fill(Tokens.surface)
                    .frame(width: Self.itemWidth)
                ScrollViewReader { reader in
                    ScrollView(.horizontal, showsIndicators: false) {
                        // A plain stack, marked as the scroll targets itself, so the row snaps to a
                        // name and reports which one settled in the middle.
                        HStack(spacing: 0) {
                            ForEach(options, id: \.self) { option in
                                item(option, height: geometry.size.height)
                            }
                        }
                        .scrollTargetLayout()
                    }
                    .contentMargins(.horizontal, margin, for: .scrollContent)
                    .scrollTargetBehavior(.viewAligned)
                    .scrollPosition(id: $centered, anchor: .center)
                    .onAppear {
                        centered = selection
                        reader.scrollTo(selection, anchor: .center)
                        DispatchQueue.main.async { reader.scrollTo(selection, anchor: .center) }
                    }
                }
            }
        }
        .sensoryFeedback(.selection, trigger: centered)
        .onChange(of: centered) { _, value in
            if let value, value != selection { selection = value }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Look")
    }

    private func item(_ option: String, height: CGFloat) -> some View {
        let isOn = option == centered
        // Turned sideways, a name runs across the row's depth, so it gets that much room.
        let length = hold.isLandscape ? min(Self.itemWidth - 12, height - 8) : Self.itemWidth - 12
        return Button {
            withAnimation(reduceMotion ? nil : .spring(duration: 0.3, bounce: 0.1)) { centered = option }
        } label: {
            Text(label(option))
                .font(Tokens.statusFont)
                .foregroundStyle(isOn ? Tokens.held : Tokens.value)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .frame(width: length)
                .turnedToHold()
                .frame(width: Self.itemWidth, height: height)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label(option))
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

/// One setting as a column that slides under a fixed band, with the choice at its center. Sideways,
/// the column runs across and each choice turns in place.
struct FormatWheel<Value: Hashable>: View {
    let title: String
    let options: [Value]
    @Binding var selection: Value
    let label: (Value) -> String
    let hold: Hold
    let rowDepth: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var centered: Value?

    static var titleGap: CGFloat { 4 }

    static func titleDepth(_ hold: Hold) -> CGFloat { hold.isLandscape ? 40 : 16 }

    init(
        title: String, options: [Value], selection: Binding<Value>, hold: Hold, rowDepth: CGFloat,
        label: @escaping (Value) -> String
    ) {
        self.title = title
        self.options = options
        _selection = selection
        self.hold = hold
        self.rowDepth = rowDepth
        self.label = label
        _centered = State(initialValue: selection.wrappedValue)
    }

    var body: some View {
        VStack(spacing: Self.titleGap) {
            Text(title)
                .font(Tokens.labelFont)
                .foregroundStyle(Tokens.label)
                .fixedSize()
                .turnedToHold()
                .frame(height: Self.titleDepth(hold))
            ScrollViewReader { reader in
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 0) {
                        ForEach(options, id: \.self) { option in
                            choice(option)
                        }
                    }
                    .scrollTargetLayout()
                }
                .contentMargins(.vertical, rowDepth, for: .scrollContent)
                .scrollTargetBehavior(.viewAligned)
                .scrollPosition(id: $centered, anchor: .center)
                // The scroll position alone opens at the top. The second call covers a first
                // layout that hasn't finished.
                .onAppear {
                    reader.scrollTo(selection, anchor: .center)
                    DispatchQueue.main.async { reader.scrollTo(selection, anchor: .center) }
                }
            }
            .frame(height: rowDepth * 3)
        }
        .frame(maxWidth: .infinity)
        .sensoryFeedback(.selection, trigger: centered)
        .onChange(of: centered) { _, value in
            if let value, value != selection { selection = value }
        }
        .onChange(of: selection) { _, value in
            if value != centered { centered = value }
        }
    }

    private func choice(_ option: Value) -> some View {
        let isOn = option == centered
        return Button {
            withAnimation(reduceMotion ? nil : .spring(duration: 0.3, bounce: 0.1)) { centered = option }
        } label: {
            Text(label(option))
                .font(Tokens.statusFont)
                .foregroundStyle(isOn ? Tokens.held : Tokens.value)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .upright(hold, depth: rowDepth - 2)
                .frame(maxWidth: .infinity)
                .frame(height: rowDepth)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .scrollTransition(.interactive.threshold(.centered), axis: .vertical) { content, phase in
            content
                .scaleEffect(1 - abs(phase.value) * 0.18)
                .opacity(1 - abs(phase.value) * 0.6)
        }
        .accessibilityLabel("\(title) \(label(option))")
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

/// What gets recorded, over the control zone so the picture stays visible. A new setting or choice
/// only needs another column or list entry.
struct FormatPanel: View {
    @EnvironmentObject private var model: AppModel
    let hold: Hold
    let bottomInset: CGFloat
    /// From the screen's edge to just short of the picture.
    let depth: CGFloat

    private static let topPadding: CGFloat = 6

    /// Three rows share what's left under the titles.
    private var rowDepth: CGFloat {
        let spare = depth - FormatWheel<Bool>.titleDepth(hold) - FormatWheel<Bool>.titleGap
            - Self.topPadding - bottomInset
        return max(spare / 3, 44)
    }

    private static func isHEVC(_ preset: EncoderPreset) -> Bool { preset.id.hasPrefix("hevc") }

    private static func chromaLabel(_ preset: EncoderPreset) -> String {
        switch preset.id {
        case "hevc420": return "4:2:0"
        case "hevc422": return "4:2:2"
        case "hevc444": return "4:4:4"
        case "prores422": return "422"
        case "prores422hq": return "422 HQ"
        case "prores4444": return "4444"
        default: return preset.shortLabel
        }
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 0) {
            FormatWheel(title: "CODEC", options: ["PRORES", "HEVC"], selection: family, hold: hold, rowDepth: rowDepth) { $0 }
            FormatWheel(
                title: Self.isHEVC(model.encoderPreset) ? "CHROMA" : "PROFILE", options: chromaChoices, selection: $model.encoderPreset, hold: hold,
                rowDepth: rowDepth, label: Self.chromaLabel
            )
            // Each codec has its own list.
            .id(Self.isHEVC(model.encoderPreset))
            FormatWheel(title: "SIZE", options: EncoderSize.all, selection: $model.encoderSize, hold: hold, rowDepth: rowDepth) {
                (model.widescreen ? $0.widescreen : $0).label
            }
            FormatWheel(
                title: "LOG", options: LogCurve.allCases, selection: $model.processing.curve, hold: hold,
                rowDepth: rowDepth
            ) { $0.shortLabel }
            FormatWheel(title: "ASPECT", options: [false, true], selection: $model.widescreen, hold: hold, rowDepth: rowDepth) {
                $0 ? "16:9" : "OPEN GATE"
            }
            FormatWheel(title: "FPS", options: FrameRates.all, selection: $model.frameRate, hold: hold,
                rowDepth: rowDepth, label: FrameRates.label
            )
        }
        .background(alignment: .bottom) {
            // The band every column's choice sits in.
            Rectangle()
                .fill(Tokens.surface)
                .frame(height: rowDepth)
                .padding(.bottom, rowDepth)
        }
        .padding(.horizontal, 12)
        .padding(.top, Self.topPadding)
        .padding(.bottom, bottomInset)
        .frame(height: depth, alignment: .bottom)
        .background(Tokens.opaquePanel)
    }

    private var chromaChoices: [EncoderPreset] {
        let hevc = Self.isHEVC(model.encoderPreset)
        return EncoderPreset.all.filter { Self.isHEVC($0) == hevc }
    }

    /// Switching codec keeps the chroma where the other codec has it.
    private var family: Binding<String> {
        Binding(
            get: { Self.isHEVC(model.encoderPreset) ? "HEVC" : "PRORES" },
            set: { name in
                let current = model.encoderPreset
                guard (name == "HEVC") != Self.isHEVC(current) else { return }
                let keepsFull = current.id.hasSuffix("444")
                let target = name == "HEVC"
                    ? (keepsFull ? "hevc444" : "hevc422") : (keepsFull ? "prores4444" : "prores422hq")
                model.encoderPreset = EncoderPreset.all.first { $0.id == target } ?? current
            })
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let isRecording: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .strokeBorder(Tokens.value, lineWidth: 2)
                RoundedRectangle(cornerRadius: isRecording ? 4 : 29)
                    .fill(Tokens.record)
                    .frame(width: isRecording ? 28 : 58, height: isRecording ? 28 : 58)
            }
            .frame(width: CameraGeometry.recordDepth, height: CameraGeometry.recordDepth)
            .contentShape(Circle())
            .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: isRecording)
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
