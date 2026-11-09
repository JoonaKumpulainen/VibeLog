import SwiftUI
import UIKit
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
    /// The look panel, which Settings can open too.
    @State private var showLook = false
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
                    selectedDial: $selectedDial, showMonitor: $showMonitor, showFormat: $showFormat, showLook: $showLook,
                    hold: hold.hold, insets: insets, stripDepth: screen.height - layout.picture.maxY,
                    openSettings: {
                        guard !showSettings else { return }
                        model.settingsOpened()
                        showSettings = true
                    })
                // Fixed to the screen, so a row that runs too wide can't widen the stack and
                // move the picture.
                .frame(width: screen.width, height: screen.height)
            }
            .environment(\.heldTurn, hold.turn)
            .onChange(of: hold.hold, initial: true) { _, held in model.scopeTurns = Int((held.angle / 90).rounded()) }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: hold.turn)
            .frame(width: screen.width, height: screen.height)
            .ignoresSafeArea()
        }
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        // Control Center's swipe from the top corner otherwise holds back taps on the gear.
        .defersSystemGestures(on: .top)
        .haptic(.impact(weight: .medium), trigger: model.isRecording)
        .haptic(.selection, trigger: model.lensID)
        .haptic(.warning, trigger: model.takeAlert) { _, alert in alert != nil }
        .modifier(VolumeRecord {
            if !showSettings, model.playingTake == nil, model.isBusy == nil { model.toggleRecord() }
        })
        .onChange(of: model.isRecording) { _, recording in
            // Any focus change during a take costs frames.
            if recording, selectedDial == .focus { selectedDial = nil }
            if recording {
                showFormat = false
                // The tools tray gives way to the take's own readings.
                showMonitor = false
            }
        }
        .sheet(isPresented: $showSettings, onDismiss: { model.settingsClosed() }) {
            SettingsView(openFormat: {
                model.fullView = false
                showFormat = true
            }, openLook: {
                model.fullView = false
                model.openLookPanel()
                showLook = true
            })
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
        .overlay(alignment: model.scopeCorner.alignment) {
            if model.isOn(.scope), model.monitorIsProcessed {
                ScopeOverlay(hold: hold.hold, picture: size)
                    .padding(8)
            }
        }
        .coordinateSpace(name: ScopeOverlay.space)
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
    @Binding var showLook: Bool
    /// The look panel's page, kept when it closes by a tap outside.
    @State private var lookPage = LookPanel.Page.looks
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
                        MonitorPanel(hold: hold)
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
            StatusBlocks(hold: hold, openSettings: openSettings, cornerTaps: !showFormat && !showLook)
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
                        depth: panelDepth)
                        .accessibilityAction(.escape) { setFormat(false) }
                }
                // A fade in place, as the look panel does.
                .transition(.opacity)
                .zIndex(1)
            }
            if showLook {
                // A tap outside keeps the changes and closes it, as Done does, like Format.
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture {
                        model.closeLookPanel(keep: true)
                        withAnimation(lookFade) { showLook = false }
                    }
                    .accessibilityHidden(true)
                VStack(spacing: 0) {
                    Spacer(minLength: 0)
                    LookPanel(
                        hold: hold, bottomInset: max(insets.bottom, 10),
                        depth: panelDepth, page: $lookPage
                    ) { keep in
                        // Done or Cancel opens it on LOOKS next time; a tap outside keeps the page.
                        lookPage = .looks
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
        withAnimation(lookFade) { showFormat = isOpen }
    }

    /// Format and look panels reach from the screen's edge to the picture, rounded up so no
    /// hairline of black shows between them on any phone's point grid.
    private var panelDepth: CGFloat { stripDepth.rounded(.up) }

    /// Five columns, matching the bars above.
    private func columns<Content: View>(
        @ViewBuilder content: @escaping (CGFloat) -> Content
    ) -> some View {
        GeometryReader { geometry in
            content(geometry.size.width / 5)
        }
        .frame(height: CameraGeometry.recordDepth)
    }

    /// FORMAT and LOOK side by side on the left, record in the middle, and the monitoring tools
    /// and the last take on the right. During a take the clock takes FORMAT and LOOK's place,
    /// since neither changes then, and the tools stay.
    private var actionRow: some View {
        columns { column in
            HStack(spacing: 0) {
                leadingSlots(column)
                recordButton
                    .frame(width: column)
                monitorButton
                    .frame(width: column)
                lastTakeSlot
                    .frame(width: column)
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
                    StatGauges()
                        .upright(hold, depth: CameraGeometry.recordDepth - 2)
                        .frame(width: column)
                    fullViewButton
                        .frame(width: column)
                }
                recordButton
                    .frame(width: column)
                if model.isRecording {
                    timecode
                        .frame(width: column * 2)
                } else {
                    Color.clear
                        .frame(width: column * 2)
                }
            }
        }
    }

    private var recordButton: some View {
        RecordButton(isRecording: model.isRecording) { model.toggleRecord() }
            .disabled(model.isBusy != nil)
    }

    /// The clock takes both columns, in the same place in every hold.
    @ViewBuilder
    private func leadingSlots(_ column: CGFloat) -> some View {
        if model.isRecording {
            timecode
                .frame(width: column * 2)
        } else {
            formatButton
                .frame(width: column)
            lookButton
                .frame(width: column)
        }
    }

    /// Opens the look panel. Amber while the look is baked into takes, since then no log is recorded.
    private var lookButton: some View {
        Button {
            selectedDial = nil
            showMonitor = false
            model.fullView = false
            model.openLookPanel()
            withAnimation(lookFade) { showLook = true }
        } label: {
            ActionCell(
                title: model.bakeLook ? "BAKED" : "LOOK", value: model.monitorLabel,
                tint: model.bakeLook ? Tokens.held : Tokens.value, hold: hold)
        }
        .buttonStyle(.plain)
        // The ISP preview can't change during a take, and choosing a look would turn it off.
        .disabled(model.isBusy != nil || (model.isRecording && model.processing.monitor == .isp))
        .accessibilityLabel("Look")
        .accessibilityValue(model.bakeLook ? "\(model.monitorName), baked into takes" : model.monitorName)
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
        .haptic(.selection, trigger: showFormat)
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
                ActionCell(title: "MON", value: model.activeToolCount == 0 ? "OFF" : "\(model.activeToolCount) ON", tint: Tokens.value, hold: hold)
                    .background(
                        showMonitor ? Tokens.surface : Color.clear,
                        in: RoundedRectangle(cornerRadius: Tokens.panelRadius))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Monitoring tools")
            // Quiet during a take, where a buzz could reach the microphones.
            .haptic(.selection, trigger: showMonitor) { _, _ in !model.isRecording }
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

/// The format, and what's left beside the settings gear, mirrored either side of the Dynamic
/// Island: three rows each, the same width, centered in the depth above the picture. Each block
/// turns as a square. Upright, it keeps to its outer edge. Sideways, it centers in the square,
/// which keeps it equally far from the Dynamic Island and clear of the screen's rounded corners.
struct StatusBlocks: View {
    @EnvironmentObject private var model: AppModel
    let hold: Hold
    let openSettings: () -> Void
    /// Off while a panel covers the gear, so a tap there closes the panel instead.
    var cornerTaps = true

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
                .allowsHitTesting(false)
                .accessibilityElement(children: .combine)
            }
            Spacer(minLength: 0)
            // The gauges turn as their own small square and the gear on its own, side by side,
            // kept in from the corner as the format lines are on the left.
            HStack(spacing: 4) {
                StatGauges()
                    .allowsHitTesting(false)
                    .frame(width: Self.gaugeSide, height: Self.gaugeSide)
                    .turnedToHold()
                Image(systemName: "gearshape")
                    .font(.system(size: 26))
                    .foregroundStyle(Tokens.value)
                    .opacity(model.isBusy == nil ? 1 : 0.4)
                    .frame(width: 30, height: 30)
                    .turnedToHold()
                    .frame(width: Self.gearSide, height: Self.gearSide)
                    .allowsHitTesting(false)
            }
            .frame(height: CameraGeometry.statusSide)
        }
        .padding(.horizontal, Self.edgeGap)
        .padding(.top, (CameraGeometry.statusDepth - CameraGeometry.statusSide) / 2)
        .overlay(alignment: .topTrailing) { settingsTarget }
    }

    /// Room for the three gauges, square so they can turn in place.
    private static let gaugeSide: CGFloat = 56
    private static let gearSide: CGFloat = 52
    private static let edgeGap: CGFloat = 24
    /// How far the target reaches over the gauges, which take no taps.
    private static let gaugeOverlap: CGFloat = 14

    /// The whole corner beside the gauges, out to the screen's top and side, so the gear takes a
    /// tap anywhere near it, held any way. Only the icon turns; the corner it sits in doesn't.
    private var settingsTarget: some View {
        Button(action: openSettings) {
            Color.clear
                .frame(width: Self.gearSide + Self.edgeGap + Self.gaugeOverlap, height: CameraGeometry.statusDepth)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(model.isBusy != nil)
        .accessibilityLabel("Settings")
        // The button alone missed taps in the screen's top edge, so the window watches the same
        // corner too. Opening twice does nothing, so a tap both catch opens Settings once.
        .background(CornerTap(enabled: cornerTaps && model.isBusy == nil && model.playingTake == nil && !model.idlePaused,
            action: openSettings))
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

/// Green, then orange, then red, each with a darker shade for text on it.
enum GaugeTint {
    case good, caution, bad

    private var rgb: (Double, Double, Double) {
        switch self {
        case .good: return (0.33, 0.82, 0.4)
        case .caution: return (1.0, 0.62, 0.18)
        case .bad: return (0.95, 0.27, 0.22)
        }
    }

    var color: Color { Color(red: rgb.0, green: rgb.1, blue: rgb.2) }
    var ink: Color { Color(red: rgb.0 * 0.3, green: rgb.1 * 0.3, blue: rgb.2 * 0.3) }
}

/// A small bar that empties as it runs out, in its state's colour, with its reading inside. A
/// battery gets the nub on its end.
struct GaugeBar: View {
    let share: Double
    let text: String
    let tint: GaugeTint
    var battery = false

    private static let width: CGFloat = 42
    private static let height: CGFloat = 14

    private func label(_ color: Color) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .bold, design: .monospaced))
            .foregroundStyle(color)
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .frame(width: Self.width - 4)
            .frame(width: Self.width, height: Self.height)
    }

    var body: some View {
        let inner = Self.width - 3
        let filled = inner * CGFloat(min(max(share, 0), 1))
        HStack(spacing: 1) {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3.5)
                    .strokeBorder(tint.color.opacity(0.9), lineWidth: 1)
                RoundedRectangle(cornerRadius: 2)
                    .fill(tint.color)
                    .frame(width: filled)
                    .padding(1.5)
                // Light over the empty part and dark over the fill, split where the fill ends.
                label(Tokens.value)
                label(tint.ink)
                    .mask(alignment: .leading) {
                        Rectangle().frame(width: filled + 1.5)
                    }
            }
            .frame(width: Self.width, height: Self.height)
            if battery {
                RoundedRectangle(cornerRadius: 1)
                    .fill(tint.color.opacity(0.9))
                    .frame(width: 2, height: 5)
            }
        }
    }
}

/// What's left to shoot on: storage, with the GB left or, during a take, the minutes they hold;
/// battery, with its level and no percent sign; and heat, filled green, orange or red.
struct StatGauges: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: CameraGeometry.statusLineGap) {
            GaugeBar(share: model.storageShare, text: model.storageGaugeLabel, tint: storageTint)
                .accessibilityElement()
                .accessibilityLabel("Storage")
                .accessibilityValue("\(model.timeLeftLabel) left")
            GaugeBar(
                share: model.batteryShare ?? 0,
                text: model.batteryShare.map { "\(Int(($0 * 100).rounded()))" } ?? "?",
                tint: batteryTint, battery: true)
                .accessibilityElement()
                .accessibilityLabel("Battery")
                .accessibilityValue(model.isCharging ? "\(model.batteryLabel), charging" : model.batteryLabel)
            GaugeBar(share: 1, text: "HEAT", tint: heatTint)
                .accessibilityElement()
                .accessibilityLabel("Heat")
                .accessibilityValue(model.heatLabel)
        }
    }

    private var storageTint: GaugeTint {
        if model.isStorageLow { return .bad }
        return model.storageShare < 0.2 ? .caution : .good
    }

    private var batteryTint: GaugeTint {
        guard let share = model.batteryShare, !model.isCharging else { return .good }
        if model.isBatteryLow { return .bad }
        return share < 0.3 ? .caution : .good
    }

    private var heatTint: GaugeTint {
        switch model.heatLevel {
        case 0: return .good
        case 1: return .caution
        default: return .bad
        }
    }
}

/// The scope in a corner of the screen, drawn on its own layer. It stays in that corner in every
/// hold, turned to read, with even margins. A tap moves to the next kind, a drag moves it to
/// another corner, and the handle at its inner corner resizes it.
struct ScopeOverlay: View {
    @EnvironmentObject private var model: AppModel
    let hold: Hold
    /// The picture's size, which the scope snaps to the corners of.
    let picture: CGSize
    @State private var drag = CGSize.zero
    /// Set once a touch has moved far enough to be a drag, so letting go doesn't count as a tap.
    @State private var moving = false
    /// The scale while the handle is held, kept here so the camera screen doesn't redraw per tick.
    @State private var liveScale: Double?
    @State private var scaleAtStart = 1.0

    static let minimumScale = 0.6
    static let maximumScale = 2.5
    /// How far the resize target's centre sits out past the scope's inner corner.
    private static let handleReach = 16.0
    /// How far a touch moves before it's a drag rather than a tap.
    private static let slop: CGFloat = 10

    /// A vectorscope is round, so it's square; the others are wide.
    private var standard: CGSize {
        model.scopeKind == .vectorscope ? CGSize(width: 110, height: 110) : CGSize(width: 176, height: 104)
    }

    /// The scope's size on the screen, sideways when the phone is.
    private func onScreen(_ size: CGSize) -> CGSize {
        hold.isLandscape ? CGSize(width: size.height, height: size.width) : size
    }

    /// The largest scale that still fits inside the picture with its margins.
    private var largest: Double {
        let turned = onScreen(standard)
        let fits = min((picture.width - 16) / turned.width, (picture.height - 16) / turned.height)
        return max(min(Self.maximumScale, fits), Self.minimumScale)
    }

    private var scale: Double { min(max(liveScale ?? model.scopeScale, Self.minimumScale), largest) }

    private var size: CGSize { CGSize(width: standard.width * scale, height: standard.height * scale) }

    var body: some View {
        let turned = onScreen(size)
        ZStack(alignment: .topLeading) {
            LayerHost(layer: model.scopeLayer)
            Text(model.scopeKind.label)
                .font(Tokens.markFont)
                .foregroundStyle(Tokens.label)
                .padding(3)
        }
        .frame(width: size.width, height: size.height)
        .clipShape(RoundedRectangle(cornerRadius: Tokens.panelRadius))
        .turnedToHold()
        // Laid out at its turned size, so a sideways scope keeps the same margins in its corner.
        .frame(width: turned.width, height: turned.height)
        .contentShape(Rectangle())
        .overlay(alignment: model.scopeCorner.opposite.alignment) { resizeHandle }
        .offset(drag)
        .gesture(move)
        .haptic(.impact(weight: .light), trigger: model.scopeCorner)
        .haptic(.selection, trigger: model.scopeKind)
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("Scope, \(model.scopeKind.label)")
        .accessibilityHint("Shows the next scope")
        .accessibilityAction { model.scopeKind = model.scopeKind.next }
    }

    /// One gesture for both, so a drag never also counts as a tap: a touch that stays within a
    /// few points is a tap, and one that moves further carries the scope and snaps it, with a
    /// spring and a light tick, to the screen corner nearest where it was let go.
    private var move: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(ScopeOverlay.space))
            .onChanged { value in
                if !moving, hypot(value.translation.width, value.translation.height) < Self.slop { return }
                moving = true
                drag = value.translation
            }
            .onEnded { value in
                guard moving else {
                    model.scopeKind = model.scopeKind.next
                    return
                }
                moving = false
                let end = value.predictedEndLocation
                let corner = ScreenCorner(right: end.x > picture.width / 2, bottom: end.y > picture.height / 2)
                withAnimation(.spring(duration: 0.35, bounce: 0.2)) {
                    model.scopeCorner = corner
                    drag = .zero
                }
            }
    }

    /// An invisible round target at the corner facing the picture's middle, since the scope's own
    /// corner stays put. Dragging it away from the scope's corner grows the scope, and toward it
    /// shrinks it.
    private var resizeHandle: some View {
        let corner = model.scopeCorner
        let (x, y) = corner.signs
        let resize = DragGesture(minimumDistance: 0, coordinateSpace: .named(ScopeOverlay.space))
            .onChanged { value in
                if liveScale == nil { scaleAtStart = scale }
                let start = onScreen(CGSize(width: standard.width * scaleAtStart, height: standard.height * scaleAtStart))
                // The free corner moves away from the scope's corner, which is -x, -y.
                let grow = (-CGFloat(x) * value.translation.width / start.width
                    - CGFloat(y) * value.translation.height / start.height) / 2
                liveScale = min(max(scaleAtStart * (1 + Double(grow)), Self.minimumScale), largest)
            }
            .onEnded { _ in
                if let liveScale { model.scopeScale = liveScale }
                liveScale = nil
            }
        // Nothing drawn: a round target 56 points across, centred just outside the scope's
        // corner, so it's easy to catch without covering the scope.
        let outward = CGFloat(Self.handleReach)
        return Color.clear
            .frame(width: 56, height: 56)
            .contentShape(Circle())
            .offset(x: -CGFloat(x) * outward, y: -CGFloat(y) * outward)
            .highPriorityGesture(resize)
            .haptic(.impact(weight: .light), trigger: model.scopeScale)
            .accessibilityHidden(true)
    }
}

extension ScopeOverlay {
    static let space = "picture"
}

/// A corner of the portrait screen. The scope stays in the one it was put in however the phone
/// turns, and only turns in place to read.
enum ScreenCorner: String {
    case bottomLeft, bottomRight, topLeft, topRight

    /// Right and down on the screen, each -1 or 1.
    var signs: (x: Int, y: Int) {
        switch self {
        case .bottomLeft: return (-1, 1)
        case .bottomRight: return (1, 1)
        case .topLeft: return (-1, -1)
        case .topRight: return (1, -1)
        }
    }

    var alignment: Alignment {
        switch self {
        case .topLeft: return .topLeading
        case .topRight: return .topTrailing
        case .bottomLeft: return .bottomLeading
        case .bottomRight: return .bottomTrailing
        }
    }

    /// The corner across from this one.
    var opposite: ScreenCorner {
        switch self {
        case .bottomLeft: return .topRight
        case .bottomRight: return .topLeft
        case .topLeft: return .bottomRight
        case .topRight: return .bottomLeft
        }
    }

    init(right: Bool, bottom: Bool) {
        switch (right, bottom) {
        case (false, true): self = .bottomLeft
        case (true, true): self = .bottomRight
        case (false, false): self = .topLeft
        case (true, false): self = .topRight
        }
    }
}

/// Shows a layer that something off the main thread draws into.
struct LayerHost: UIViewRepresentable {
    let layer: CALayer

    final class HostView: UIView {
        var hosted: CALayer?

        override func layoutSubviews() {
            super.layoutSubviews()
            hosted?.frame = bounds
        }
    }

    func makeUIView(context: Context) -> HostView {
        let view = HostView()
        view.isUserInteractionEnabled = false
        view.layer.addSublayer(layer)
        view.hosted = layer
        return view
    }

    func updateUIView(_ view: HostView, context: Context) {}
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

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Tool.allCases) { tool in
                toolButton(tool)
            }
        }
        .frame(height: CameraGeometry.trayDepth)
        .contentShape(Rectangle())
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
/// middle of the carousel, and ADJUST to grade it. BAKE in the header records that look into
/// takes. Cancel puts back what was there, and Done or a tap outside keeps it. Every control
/// keeps its place and turns with the hold.
struct LookPanel: View {
    @EnvironmentObject private var model: AppModel
    let hold: Hold
    let bottomInset: CGFloat
    /// From the screen's edge to just short of the picture.
    let depth: CGFloat
    @Binding var page: Page
    let close: (Bool) -> Void
    @State private var choice = ""
    @State private var bake = false
    @State private var ready = false
    @State private var styleChoice = Self.noStyle
    @State private var choosingRange = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Not a file name, since those end in .cube.
    static let logChoice = "log"
    /// Not a style name, since saving one asks for a name.
    static let noStyle = "\u{0}none"
    private static let headerDepth: CGFloat = 44

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
                headerButton("Done", weight: .semibold) { close(true) }
            }
            .frame(height: Self.headerDepth)
            pageTabs
            if page != .looks {
                // On a phone with less room under the picture, a page scrolls rather than breaks.
                ViewThatFits(in: .vertical) {
                    gradePage
                    ScrollView(.vertical, showsIndicators: false) { gradePage }
                }
            } else if ready {
                // The look's styles flow up from below it, and the looks make room above.
                VStack(spacing: 0) {
                    LookCarousel(
                        options: lookOptions, selection: $choice, hold: hold, label: Self.label, showsBand: false,
                        subtitle: { $0 == BuiltInLook.aces20.name ? model.bakeTarget.shortLabel : nil },
                        tappedChosen: { option in if option == BuiltInLook.aces20.name { choosingRange = true } })
                    if !stylesHere.isEmpty {
                        LookCarousel(
                            options: [Self.noStyle] + stylesHere.map(\.name), selection: $styleChoice, hold: hold,
                            label: { $0 == Self.noStyle ? "NO STYLE" : $0.uppercased() },
                            deletable: { name in model.savedStyles.contains { $0.name == name } },
                            delete: deleteStyle, showsBand: false)
                            .id(stylesHere.map(\.name))
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
                // One band through the look and its style, growing as the style row flows up.
                .background {
                    RoundedRectangle(cornerRadius: Tokens.panelRadius)
                        .fill(Tokens.surface)
                        .frame(width: LookCarousel.itemWidth)
                }
                .clipped()
                .animation(reduceMotion ? nil : .spring(duration: 0.4, bounce: 0.15), value: stylesHere.isEmpty)
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, bottomInset)
        // Anything too deep is cut at the bottom, never pushed up over the picture.
        .frame(height: depth, alignment: .top)
        .clipped()
        .background(Tokens.opaquePanel)
        .onAppear {
            // The carousel opens on the current choice, so it's made once that's known.
            choice = model.processing.monitor == .log ? Self.logChoice : model.selectedLUT
            if choice == Self.logChoice { page = .looks }
            styleChoice = model.currentStyle?.name ?? Self.noStyle
            bake = model.bakeLook
            ready = true
        }
        .onChange(of: choice) { _, value in
            if model.processing.monitor == .isp {
                // Apple's picture can't show a look, so choosing one turns it off.
                model.showNotice(
                    model.bakeLook
                        ? "ISP preview is off, to show the look. Baked takes record it either way"
                        : "ISP preview is off, to show the look. Turn it back on in Settings", seconds: 5)
            }
            if value == Self.logChoice {
                model.processing.monitor = .log
                bake = false
            } else {
                model.processing.monitor = .rec709
                model.previewLUT(value)
            }
            // A built-in style carries over between the ACES looks; otherwise the row starts on
            // whichever style the grade matches, or none.
            if !stylesHere.contains(where: { $0.name == styleChoice }) {
                styleChoice = model.currentStyle?.name ?? Self.noStyle
            }
        }
        .onChange(of: styleChoice) { _, name in
            if let style = stylesHere.first(where: { $0.name == name }) {
                model.previewStyle(style)
            } else if model.currentStyle != nil {
                // Off a style back to the look itself. A grade of the owner's own stays.
                model.lookGrade = LookGrade()
            }
        }
        .onChange(of: bake) { _, on in if !model.isRecording { model.bakeLook = on } }
        .confirmationDialog("Dynamic Range", isPresented: $choosingRange, titleVisibility: .visible) {
            ForEach(BakeTarget.allCases) { target in
                Button(target == model.bakeTarget ? "\(target.label) ✓" : target.label) { model.bakeTarget = target }
            }
        } message: {
            Text("What ACES 2.0 records when BAKE is on. HDR is 1000 nits in Rec.2020, as PQ for HDR10 or as HLG. With HDR viewfinder on in Settings, the viewfinder shows HDR too.")
        }
    }

    enum Page { case looks, adjust, color, wheels, fx }

    @ViewBuilder private var gradePage: some View {
        switch page {
        case .adjust: GradePanel(hold: hold)
        case .color: ColorPanel(hold: hold)
        case .wheels: WheelsPanel(hold: hold)
        case .fx: FXPanel(hold: hold)
        case .looks: EmptyView()
        }
    }

    /// LOOKS, ADJUST and COLOR. The grade is fixed during a take, as the bake is.
    /// LOG is for judging exposure and takes no grade, so there ADJUST and COLOR merge into LOOKS,
    /// which widens to the whole row, and split out again when any look is chosen.
    private var canAdjust: Bool { choice != Self.logChoice }

    private var pageTabs: some View {
        HStack(spacing: 0) {
            pageTab("LOOKS", on: page == .looks) { page = .looks }
            if canAdjust {
                Group {
                    pageTab("ADJUST", on: page == .adjust) { page = .adjust }
                    pageTab("COLOR", on: page == .color) { page = .color }
                    pageTab("WHEELS", on: page == .wheels) { page = .wheels }
                    pageTab("FX", on: page == .fx) { page = .fx }
                }
                .disabled(model.isRecording)
                .opacity(model.isRecording ? 0.4 : 1)
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .frame(height: 32)
        .clipped()
        .animation(reduceMotion ? nil : .spring(duration: 0.35, bounce: 0.15), value: canAdjust)
        .haptic(.selection, trigger: page)
    }

    private func pageTab(_ title: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            // Turned, a name runs across the row's depth, so it's kept to that.
            Text(title)
                .font(Tokens.labelFont)
                .foregroundStyle(on ? Tokens.held : Tokens.label)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .upright(hold, depth: 28)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    /// LOG, MONITOR and the ACES looks, then imported LUTs.
    private var lookOptions: [String] { [Self.logChoice, ""] + model.lookNames }

    /// The built-in styles under either ACES look, and the owner's own under the look they were
    /// saved on. LOG has none.
    private var stylesHere: [LookStyle] { choice == Self.logChoice ? [] : model.styles(for: choice) }

    /// Only the owner's own styles can go, from a long press in the style row.
    private func deleteStyle(_ name: String) {
        if styleChoice == name { styleChoice = Self.noStyle }
        model.deleteStyle(named: name)
    }

    static func label(_ option: String) -> String {
        if option == logChoice { return "LOG" }
        if option.isEmpty { return "MONITOR" }
        if BuiltInLook.named(option) != nil { return option }
        return (option as NSString).deletingPathExtension
    }

    private func headerButton(_ title: String, weight: Font.Weight, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(Tokens.statusFont.weight(weight))
                .foregroundStyle(Tokens.held)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .upright(hold, depth: 40)
                .frame(width: 64, height: 44)
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

/// One of the grade's sliders.
enum GradeControl: CaseIterable, Identifiable {
    case exposure, contrast, temperature, tint, saturation

    var id: Self { self }

    var title: String {
        switch self {
        case .exposure: return "EXP"
        case .contrast: return "CON"
        case .temperature: return "TEMP"
        case .tint: return "TINT"
        case .saturation: return "SAT"
        }
    }

    var name: String {
        switch self {
        case .exposure: return "Exposure"
        case .contrast: return "Contrast"
        case .temperature: return "Temperature"
        case .tint: return "Tint"
        case .saturation: return "Saturation"
        }
    }

    /// Conservative to start with, to be tuned from the phone.
    var range: ClosedRange<Double> {
        switch self {
        case .exposure: return -2...2
        case .saturation: return 0...2
        default: return -1...1
        }
    }

    var keyPath: WritableKeyPath<LookGrade, Double> {
        switch self {
        case .exposure: return \.exposure
        case .contrast: return \.contrast
        case .temperature: return \.temperature
        case .tint: return \.tint
        case .saturation: return \.saturation
        }
    }

    /// Fine enough to grade with, coarse enough that a drag doesn't rebuild for nothing.
    func snapped(_ value: Double) -> Double {
        let step = self == .exposure ? 0.05 : 0.01
        return (value / step).rounded() * step
    }

    /// The value as the cell shows it, so a haptic tick lands on each number shown: tenths of a
    /// stop for exposure, points for the others.
    func shownStep(_ value: Double) -> Int {
        Int((value * (self == .exposure ? 10 : 100)).rounded())
    }

    func text(_ value: Double) -> String {
        switch self {
        case .exposure: return String(format: "%+.1f", value)
        case .saturation: return String(format: "%.0f%%", value * 100)
        default: return String(format: "%+.0f", value * 100)
        }
    }
}

/// The grade, one slider at a time: tap a value to choose it and drag the slider below, and tap
/// the chosen value again to put it back. Only the text turns with the hold: a turned slider
/// would slide the wrong way under a finger. While a slider moves, the grade stays in this view
/// and only a quick preview reaches the viewfinder, so nothing else on the screen redraws; it's
/// kept when the finger lifts. RESET clears these five and leaves COLOR alone.
struct GradePanel: View {
    @EnvironmentObject private var model: AppModel
    let hold: Hold
    @State private var selected = GradeControl.exposure
    @State private var draft: LookGrade?
    @State private var haptics = DetentHaptics()

    private var shown: LookGrade { draft ?? model.lookGrade }

    /// The grade with these five at neutral and the colours and wheels kept.
    private var cleared: LookGrade {
        var grade = LookGrade()
        grade.bands = shown.bands
        grade.wheels = shown.wheels
        return grade
    }

    var body: some View {
        VStack(spacing: 2) {
            HStack(spacing: 0) {
                ForEach(GradeControl.allCases) { cell($0) }
            }
            .frame(height: 40)
            Slider(value: binding(selected), in: selected.range) { editing in
                if editing { haptics.prepare() } else { commit() }
            }
            // A new slider for each value, so momentum from the last one can't carry into it.
            .id(selected)
            .tint(Tokens.held)
            .padding(.horizontal, 8)
            .accessibilityLabel(selected.name)
            .accessibilityValue(selected.text(shown[keyPath: selected.keyPath]))
            Spacer(minLength: 0)
            GradeActions(
                hold: hold, canSave: !shown.isNeutral, canReset: shown != cleared,
                reset: { model.lookGrade = cleared })
        }
        .disabled(model.isRecording)
        .haptic(.selection, trigger: selected)
        .onChange(of: selected) { _, _ in commit() }
    }

    private func commit() {
        guard let draft else { return }
        model.commitGrade(draft)
        self.draft = nil
    }

    private func binding(_ control: GradeControl) -> Binding<Double> {
        Binding(
            get: { shown[keyPath: control.keyPath] },
            set: { value in
                var grade = shown
                grade[keyPath: control.keyPath] = control.snapped(value)
                guard grade != shown else { return }
                haptics.moved(
                    from: control.shownStep(shown[keyPath: control.keyPath]),
                    to: control.shownStep(grade[keyPath: control.keyPath]),
                    neutral: control.shownStep(LookGrade()[keyPath: control.keyPath]))
                draft = grade
                model.previewGrade(grade)
            })
    }

    private func cell(_ control: GradeControl) -> some View {
        let value = shown[keyPath: control.keyPath]
        let changed = value != LookGrade()[keyPath: control.keyPath]
        let isOn = control == selected
        return Button {
            if isOn {
                commit()
                model.lookGrade[keyPath: control.keyPath] = LookGrade()[keyPath: control.keyPath]
            } else {
                selected = control
            }
        } label: {
            VStack(spacing: 2) {
                Text(control.title)
                    .font(Tokens.labelFont)
                    .foregroundStyle(isOn ? Tokens.held : Tokens.label)
                Text(control.text(value))
                    .font(Tokens.statusFont)
                    .foregroundStyle(changed ? Tokens.held : Tokens.value)
            }
            .fixedSize()
            .turnedToHold()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(isOn ? Tokens.surface : .clear, in: RoundedRectangle(cornerRadius: Tokens.panelRadius))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(control.name)
        .accessibilityValue(control.text(value))
        .accessibilityHint(isOn ? "Tap again to reset" : "")
    }
}

/// SAVE and RESET, a compact pair centred along the bottom of ADJUST and COLOR, so they sit the
/// same distance from both edges of the phone. SAVE keeps the look and the whole grade as a
/// style under that look.
struct GradeActions: View {
    @EnvironmentObject private var model: AppModel
    let hold: Hold
    let canSave: Bool
    let canReset: Bool
    let reset: () -> Void
    @State private var naming = false
    @State private var styleName = ""

    var body: some View {
        HStack(spacing: 16) {
            PanelButton(title: "SAVE", enabled: canSave, hold: hold) {
                styleName = ""
                naming = true
            }
            .accessibilityLabel("Save as a style")
            PanelButton(title: "RESET", enabled: canReset, hold: hold, action: reset)
        }
        .frame(maxWidth: .infinity)
        .alert("Save Style", isPresented: $naming) {
            TextField("Name", text: $styleName)
            Button("Save") { model.saveStyle(named: styleName) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Keeps this look's grade, COLOR included, under the look in LOOKS. Long-press it there to delete it.")
        }
    }
}

/// A small filled button along a panel's bottom, its label kept inside it in every hold.
struct PanelButton: View {
    let title: String
    let enabled: Bool
    let hold: Hold
    let action: () -> Void

    static let size = CGSize(width: 96, height: 30)

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(Tokens.labelFont)
                .foregroundStyle(enabled ? Tokens.value : Tokens.label)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .upright(hold, depth: Self.size.height - 8)
                .frame(width: Self.size.width, height: Self.size.height)
                .background(Tokens.surface.opacity(enabled ? 1 : 0.5), in: RoundedRectangle(cornerRadius: Tokens.panelRadius))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}

/// One of a colour's three changes.
enum BandControl: CaseIterable, Identifiable {
    case hue, saturation, luminance

    var id: Self { self }

    var title: String {
        switch self {
        case .hue: return "HUE"
        case .saturation: return "SAT"
        case .luminance: return "LUM"
        }
    }

    var name: String {
        switch self {
        case .hue: return "Hue"
        case .saturation: return "Saturation"
        case .luminance: return "Luminance"
        }
    }

    var keyPath: WritableKeyPath<BandAdjust, Double> {
        switch self {
        case .hue: return \.hue
        case .saturation: return \.saturation
        case .luminance: return \.luminance
        }
    }
}

extension ColorBand {
    private var rgb: (Double, Double, Double) {
        switch self {
        case .red: return (0.92, 0.22, 0.2)
        case .orange: return (0.96, 0.56, 0.16)
        case .yellow: return (0.95, 0.85, 0.2)
        case .green: return (0.3, 0.78, 0.3)
        case .cyan: return (0.2, 0.8, 0.85)
        case .blue: return (0.25, 0.42, 0.95)
        case .magenta: return (0.85, 0.3, 0.8)
        case .skin: return (0.87, 0.64, 0.5)
        }
    }

    var swatch: Color { Color(red: rgb.0, green: rgb.1, blue: rgb.2) }

    /// The swatch darkened, for its letter.
    var ink: Color { Color(red: rgb.0 * 0.35, green: rgb.1 * 0.35, blue: rgb.2 * 0.35) }

    var letter: String { self == .skin ? "SK" : String(name.prefix(1)).uppercased() }
}

/// Each colour's hue, saturation and luminance: tap a ball, then HUE, SAT or LUM, and drag the
/// slider beside them. A changed colour has an amber ring. Tapping the chosen ball again, or the
/// arrow beside the slider, puts that colour back, and RESET below puts every colour back. It works like ADJUST, keeping a draft while a slider moves.
struct ColorPanel: View {
    @EnvironmentObject private var model: AppModel
    let hold: Hold
    @State private var band = ColorBand.red
    @State private var control = BandControl.hue
    @State private var draft: LookGrade?
    @State private var haptics = DetentHaptics()

    private var shown: LookGrade { draft ?? model.lookGrade }

    var body: some View {
        VStack(spacing: 2) {
            HStack(spacing: 0) {
                ForEach(ColorBand.allCases) { ball($0) }
            }
            .frame(height: 36)
            HStack(spacing: 4) {
                ForEach(BandControl.allCases) { controlCell($0) }
                Slider(value: binding, in: -1...1) { editing in
                    if editing { haptics.prepare() } else { commit() }
                }
                // A new slider for each colour and value, so momentum from the last one can't
                // carry into it.
                .id("\(band.rawValue)-\(control.title)")
                .tint(band.swatch)
                .accessibilityLabel("\(band.name) \(control.name)")
                .accessibilityValue(text(shown.bands[band.rawValue][keyPath: control.keyPath]))
                Button {
                    commit()
                    model.lookGrade.bands[band.rawValue] = BandAdjust()
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                        .font(Tokens.statusFont)
                        .foregroundStyle(shown.bands[band.rawValue].isNeutral ? Tokens.label : Tokens.held)
                        .turnedToHold()
                        .frame(width: 32, height: 40)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(shown.bands[band.rawValue].isNeutral)
                .accessibilityLabel("Reset \(band.name)")
            }
            .frame(height: 40)
            Spacer(minLength: 0)
            GradeActions(
                hold: hold, canSave: !shown.isNeutral, canReset: !shown.bands.allSatisfy(\.isNeutral),
                reset: {
                    commit()
                    model.lookGrade.bands = LookGrade().bands
                })
        }
        .disabled(model.isRecording)
        .haptic(.selection, trigger: band)
        .haptic(.selection, trigger: control)
        .onChange(of: band) { _, _ in commit() }
        .onChange(of: control) { _, _ in commit() }
    }

    private func commit() {
        guard let draft else { return }
        model.commitGrade(draft)
        self.draft = nil
    }

    private func text(_ value: Double) -> String { String(format: "%+.0f", value * 100) }

    private var binding: Binding<Double> {
        Binding(
            get: { shown.bands[band.rawValue][keyPath: control.keyPath] },
            set: { value in
                var grade = shown
                let old = grade.bands[band.rawValue][keyPath: control.keyPath]
                let new = (value * 100).rounded() / 100
                guard new != old else { return }
                grade.bands[band.rawValue][keyPath: control.keyPath] = new
                haptics.moved(from: Int((old * 100).rounded()), to: Int((new * 100).rounded()), neutral: 0)
                draft = grade
                model.previewGrade(grade)
            })
    }

    private func ball(_ item: ColorBand) -> some View {
        let isOn = item == band
        let changed = !shown.bands[item.rawValue].isNeutral
        return Button {
            if isOn {
                commit()
                model.lookGrade.bands[item.rawValue] = BandAdjust()
            } else {
                band = item
            }
        } label: {
            Text(item.letter)
                .font(.system(size: item == .skin ? 8 : 10, weight: .bold, design: .monospaced))
                .foregroundStyle(item.ink)
                .fixedSize()
                .turnedToHold()
                .frame(width: 24, height: 24)
                .background(item.swatch, in: Circle())
                .overlay(Circle().stroke(Tokens.held, lineWidth: changed ? 2 : 0).padding(-3))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(isOn ? Tokens.surface : .clear, in: RoundedRectangle(cornerRadius: Tokens.panelRadius))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(item.name)
        .accessibilityValue(changed ? "changed" : "unchanged")
        .accessibilityHint(isOn ? "Tap again to reset" : "")
    }

    private func controlCell(_ item: BandControl) -> some View {
        let isOn = item == control
        let value = shown.bands[band.rawValue][keyPath: item.keyPath]
        return Button { control = item } label: {
            VStack(spacing: 2) {
                Text(item.title)
                    .font(Tokens.labelFont)
                    .foregroundStyle(isOn ? Tokens.held : Tokens.label)
                Text(text(value))
                    .font(Tokens.statusFont)
                    .foregroundStyle(value != 0 ? Tokens.held : Tokens.value)
            }
            .fixedSize()
            .turnedToHold()
            .frame(width: 40, height: 40)
            .background(isOn ? Tokens.surface : .clear, in: RoundedRectangle(cornerRadius: Tokens.panelRadius))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(item.name)
        .accessibilityValue(text(value))
    }
}

extension ToneRange {
    var title: String {
        switch self {
        case .shadows: return "SHAD"
        case .midtones: return "MID"
        case .highlights: return "HIGH"
        }
    }
}

/// A colour wheel with a puck, for one range's colour push. It's laid out as the vectorscope is,
/// red toward the top left, so the picture moves on the scope the way the puck moves. A drag
/// moves the puck from where it is, at a fine rate, rather than jumping it to the finger. The
/// wheel stays as it is in every hold, as sliders do, since a turned wheel would move the wrong
/// way under a finger.
struct ToneWheelPad: View {
    let wheel: ToneWheel
    let diameter: CGFloat
    let change: (_ x: Double, _ y: Double) -> Void
    let end: () -> Void
    @State private var start: SIMD2<Double>?

    /// Oklab's hue turned this far counter-clockwise lands where the vectorscope puts that colour:
    /// red at Oklab 29 degrees sits at the scope's 103.
    static let screenTurn = 74.0
    /// A finger's travel across the whole wheel moves the puck this far, so small pushes are easy.
    private static let rate = 0.6

    /// The puck's place on the screen, up being positive y.
    static func screenPoint(_ wheel: ToneWheel) -> CGPoint {
        let angle = (wheel.hue + screenTurn) * .pi / 180
        return CGPoint(x: wheel.amount * cos(angle), y: wheel.amount * sin(angle))
    }

    /// A screen point in the disc back to the wheel's x and y.
    static func wheelPoint(_ point: CGPoint) -> SIMD2<Double> {
        let (px, py) = (Double(point.x), Double(point.y))
        var length = min(hypot(px, py), 1)
        // A small dead zone, so the middle is easy to find again.
        if length < 0.03 { length = 0 }
        let hue = atan2(py, px) - screenTurn * .pi / 180
        return SIMD2((length * cos(hue) * 100).rounded() / 100, (length * sin(hue) * 100).rounded() / 100)
    }

    /// The ring's colours by Oklab hue, at each COLOR band's centre.
    private static let anchors: [(hue: Double, rgb: SIMD3<Double>)] = [
        (29, SIMD3(0.92, 0.22, 0.2)), (56, SIMD3(0.96, 0.56, 0.16)), (110, SIMD3(0.95, 0.85, 0.2)),
        (142, SIMD3(0.3, 0.78, 0.3)), (195, SIMD3(0.2, 0.8, 0.85)), (264, SIMD3(0.25, 0.42, 0.95)),
        (328, SIMD3(0.85, 0.3, 0.8)),
    ]

    static func colour(hue: Double) -> Color {
        let h = (hue.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)
        let count = anchors.count
        var index = anchors.lastIndex { $0.hue <= h } ?? count - 1
        if h < anchors[0].hue { index = count - 1 }
        let low = anchors[index]
        let high = anchors[(index + 1) % count]
        var span = high.hue - low.hue
        if span <= 0 { span += 360 }
        var along = h - low.hue
        if along < 0 { along += 360 }
        let rgb = low.rgb + (high.rgb - low.rgb) * (along / span)
        return Color(red: rgb.x, green: rgb.y, blue: rgb.z)
    }

    /// SwiftUI's angular gradient runs clockwise on the screen, so each stop's hue is worked back.
    private static let ring: Gradient = {
        let steps = 36
        return Gradient(stops: (0...steps).map { step in
            let clockwise = Double(step) / Double(steps) * 360
            return .init(color: colour(hue: -clockwise - screenTurn), location: Double(step) / Double(steps))
        })
    }()

    var body: some View {
        let radius = diameter / 2
        let point = Self.screenPoint(wheel)
        ZStack {
            Circle().fill(AngularGradient(gradient: Self.ring, center: .center))
            Circle().fill(RadialGradient(
                colors: [Color(white: 0.3), Color(white: 0.3).opacity(0)], center: .center,
                startRadius: 0, endRadius: radius))
            Rectangle().fill(Color.white.opacity(0.25)).frame(width: 1, height: diameter * 0.3)
            Rectangle().fill(Color.white.opacity(0.25)).frame(width: diameter * 0.3, height: 1)
            Circle()
                .stroke(Color.white, lineWidth: 2)
                .background(Circle().fill(Color.black.opacity(0.4)))
                .frame(width: 12, height: 12)
                .offset(x: point.x * radius, y: -point.y * radius)
        }
        .frame(width: diameter, height: diameter)
        .contentShape(Circle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    let origin = start ?? SIMD2(Double(point.x), Double(point.y))
                    start = origin
                    let moved = CGPoint(
                        x: origin.x + Double(value.translation.width / radius) * Self.rate,
                        y: origin.y - Double(value.translation.height / radius) * Self.rate)
                    let next = Self.wheelPoint(moved)
                    if next != SIMD2(wheel.x, wheel.y) { change(next.x, next.y) }
                }
                .onEnded { _ in
                    start = nil
                    end()
                })
    }
}

/// Shadows, midtones and highlights, each a colour wheel and a luminance slider: tap a range,
/// push its puck toward a colour and drag LUM. Tapping the chosen range again, or the arrow,
/// puts it back, and RESET below puts every wheel back. It keeps a draft while dragging, as
/// ADJUST does.
struct WheelsPanel: View {
    @EnvironmentObject private var model: AppModel
    let hold: Hold
    @State private var range = ToneRange.shadows
    @State private var draft: LookGrade?
    @State private var haptics = DetentHaptics()

    private var shown: LookGrade { draft ?? model.lookGrade }
    private var wheel: ToneWheel { shown.wheels[range.rawValue] }

    var body: some View {
        VStack(spacing: 2) {
            HStack(spacing: 0) {
                ForEach(ToneRange.allCases) { cell($0) }
            }
            .frame(height: 40)
            HStack(spacing: 8) {
                ToneWheelPad(
                    wheel: wheel, diameter: 60,
                    change: { x, y in
                        var grade = shown
                        let old = grade.wheels[range.rawValue]
                        grade.wheels[range.rawValue].x = x
                        grade.wheels[range.rawValue].y = y
                        haptics.moved(
                            from: Int((old.amount * 20).rounded()),
                            to: Int((grade.wheels[range.rawValue].amount * 20).rounded()), neutral: 0)
                        update(grade)
                    },
                    end: commit)
                    .id(range)
                    .accessibilityLabel("\(range.name) colour")
                    .accessibilityValue(String(format: "%.0f at hue %.0f", wheel.amount * 100, wheel.hue))
                VStack(spacing: 0) {
                    Text("LUM " + String(format: "%+.0f", wheel.luminance * 100))
                        .font(Tokens.labelFont)
                        .foregroundStyle(wheel.luminance != 0 ? Tokens.held : Tokens.label)
                        .fixedSize()
                        .turnedToHold()
                    Slider(value: luminance, in: -1...1) { editing in
                        if editing { haptics.prepare() } else { commit() }
                    }
                    // A new slider for each range, so momentum from the last one can't carry into it.
                    .id("\(range.rawValue)-luminance")
                    .tint(Tokens.held)
                    .accessibilityLabel("\(range.name) luminance")
                }
                Button {
                    commit()
                    model.lookGrade.wheels[range.rawValue] = ToneWheel()
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                        .font(Tokens.statusFont)
                        .foregroundStyle(wheel.isNeutral ? Tokens.label : Tokens.held)
                        .turnedToHold()
                        .frame(width: 32, height: 40)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(wheel.isNeutral)
                .accessibilityLabel("Reset \(range.name)")
            }
            .padding(.horizontal, 8)
            .frame(height: 64)
            Spacer(minLength: 0)
            GradeActions(
                hold: hold, canSave: !shown.isNeutral, canReset: !shown.wheels.allSatisfy(\.isNeutral),
                reset: {
                    commit()
                    model.lookGrade.wheels = LookGrade().wheels
                })
        }
        .disabled(model.isRecording)
        .haptic(.selection, trigger: range)
        .onChange(of: range) { _, _ in commit() }
    }

    private func update(_ grade: LookGrade) {
        draft = grade
        model.previewGrade(grade)
    }

    private func commit() {
        guard let draft else { return }
        model.commitGrade(draft)
        self.draft = nil
    }

    private var luminance: Binding<Double> {
        Binding(
            get: { wheel.luminance },
            set: { value in
                var grade = shown
                let old = grade.wheels[range.rawValue].luminance
                let new = (value * 100).rounded() / 100
                guard new != old else { return }
                grade.wheels[range.rawValue].luminance = new
                haptics.moved(from: Int((old * 100).rounded()), to: Int((new * 100).rounded()), neutral: 0)
                update(grade)
            })
    }

    private func cell(_ item: ToneRange) -> some View {
        let isOn = item == range
        let value = shown.wheels[item.rawValue]
        return Button {
            if isOn {
                commit()
                model.lookGrade.wheels[item.rawValue] = ToneWheel()
            } else {
                range = item
            }
        } label: {
            VStack(spacing: 2) {
                HStack(spacing: 4) {
                    Circle()
                        .fill(value.amount > 0 ? ToneWheelPad.colour(hue: value.hue) : Tokens.label.opacity(0.4))
                        .frame(width: 8, height: 8)
                    Text(item.title)
                        .font(Tokens.labelFont)
                        .foregroundStyle(isOn ? Tokens.held : Tokens.label)
                }
                Text(String(format: "%+.0f", value.luminance * 100))
                    .font(Tokens.statusFont)
                    .foregroundStyle(value.isNeutral ? Tokens.value : Tokens.held)
            }
            .fixedSize()
            .turnedToHold()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(isOn ? Tokens.surface : .clear, in: RoundedRectangle(cornerRadius: Tokens.panelRadius))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(item.name)
        .accessibilityValue(value.isNeutral ? "unchanged" : "changed")
        .accessibilityHint(isOn ? "Tap again to reset" : "")
    }
}

/// One of the FX tab's effects.
enum FXControl: CaseIterable, Identifiable {
    case halation, bloom, diffusion, vignette, grain

    var id: Self { self }

    var title: String {
        switch self {
        case .halation: return "HAL"
        case .bloom: return "BLOOM"
        case .diffusion: return "DIFF"
        case .vignette: return "VIG"
        case .grain: return "GRAIN"
        }
    }

    var name: String {
        switch self {
        case .halation: return "Halation"
        case .bloom: return "Bloom"
        case .diffusion: return "Diffusion"
        case .vignette: return "Vignette"
        case .grain: return "Grain"
        }
    }

    var range: ClosedRange<Double> { self == .vignette ? -1...1 : 0...1 }

    var keyPath: WritableKeyPath<LookEffects, Double> {
        switch self {
        case .halation: return \.halation
        case .bloom: return \.bloom
        case .diffusion: return \.diffusion
        case .vignette: return \.vignette
        case .grain: return \.grain
        }
    }

    func text(_ value: Double) -> String {
        self == .vignette ? String(format: "%+.0f", value * 100) : String(format: "%.0f", value * 100)
    }
}

/// The effects, one slider at a time, as ADJUST works. Effects change a value the GPU reads each
/// draw, so a drag shows at once with nothing to build. They show in the viewfinder and export;
/// takes are recorded without them for now, which the bottom row says while BAKE is on.
struct FXPanel: View {
    @EnvironmentObject private var model: AppModel
    let hold: Hold
    @State private var selected = FXControl.halation
    @State private var draft: LookEffects?
    @State private var haptics = DetentHaptics()

    private var shown: LookEffects { draft ?? model.lookEffects }

    var body: some View {
        VStack(spacing: 2) {
            HStack(spacing: 0) {
                ForEach(FXControl.allCases) { cell($0) }
            }
            .frame(height: 40)
            Slider(value: binding(selected), in: selected.range) { editing in
                if editing { haptics.prepare() } else { commit() }
            }
            .id(selected)
            .tint(Tokens.held)
            .padding(.horizontal, 8)
            .accessibilityLabel(selected.name)
            .accessibilityValue(selected.text(shown[keyPath: selected.keyPath]))
            Spacer(minLength: 0)
            HStack(spacing: 16) {
                // In baked takes only with FX in takes on in Settings, and never in log takes.
                let baked = model.bakeLook && model.processing.bakeEffects
                Text(baked ? "IN TAKES" : model.bakeLook ? "NOT BAKED" : "NOT IN TAKES")
                    .font(Tokens.markFont)
                    .foregroundStyle(baked ? Tokens.held : model.bakeLook ? Tokens.warning : Tokens.label)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .minimumScaleFactor(0.7)
                    .upright(hold, depth: PanelButton.size.height - 4)
                    .frame(width: PanelButton.size.width, height: PanelButton.size.height)
                PanelButton(title: "RESET", enabled: !shown.isNeutral, hold: hold) {
                    commit()
                    model.lookEffects = LookEffects()
                }
            }
            .frame(maxWidth: .infinity)
        }
        .disabled(model.isRecording)
        .haptic(.selection, trigger: selected)
        .onChange(of: selected) { _, _ in commit() }
    }

    private func commit() {
        guard let draft else { return }
        model.lookEffects = draft
        self.draft = nil
    }

    private func binding(_ control: FXControl) -> Binding<Double> {
        Binding(
            get: { shown[keyPath: control.keyPath] },
            set: { value in
                var effects = shown
                let old = effects[keyPath: control.keyPath]
                let new = (value * 100).rounded() / 100
                guard new != old else { return }
                effects[keyPath: control.keyPath] = new
                haptics.moved(from: Int((old * 100).rounded()), to: Int((new * 100).rounded()), neutral: 0)
                draft = effects
                model.previewEffects(effects)
            })
    }

    private func cell(_ control: FXControl) -> some View {
        let value = shown[keyPath: control.keyPath]
        let isOn = control == selected
        return Button {
            if isOn {
                commit()
                model.lookEffects[keyPath: control.keyPath] = 0
            } else {
                selected = control
            }
        } label: {
            VStack(spacing: 2) {
                Text(control.title)
                    .font(Tokens.labelFont)
                    .foregroundStyle(isOn ? Tokens.held : Tokens.label)
                Text(control.text(value))
                    .font(Tokens.statusFont)
                    .foregroundStyle(value != 0 ? Tokens.held : Tokens.value)
            }
            .fixedSize()
            .turnedToHold()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(isOn ? Tokens.surface : .clear, in: RoundedRectangle(cornerRadius: Tokens.panelRadius))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(control.name)
        .accessibilityValue(control.text(value))
        .accessibilityHint(isOn ? "Tap again to reset" : "")
    }
}

/// A tick for each number a slider passes, at most one every 35 ms, so a slow drag ticks on
/// every step and a fast one feels like a ratchet rather than a buzz, which is what the Taptic
/// Engine makes of taps closer together. Neutral always gets its firmer tick.
final class DetentHaptics {
    private let tick = UISelectionFeedbackGenerator()
    private let neutralTick = UIImpactFeedbackGenerator(style: .medium)
    private var last = Date.distantPast
    private static let gap: TimeInterval = 0.035

    func prepare() {
        tick.prepare()
        neutralTick.prepare()
    }

    func moved(from old: Int, to new: Int, neutral: Int) {
        guard old != new, Haptics.isOn else { return }
        let now = Date()
        // Passing over neutral counts too, so a fast swipe through it still marks it.
        if new == neutral || (old - neutral).signum() * (new - neutral).signum() < 0 {
            neutralTick.impactOccurred()
            last = now
        } else if now.timeIntervalSince(last) >= Self.gap {
            tick.selectionChanged()
            last = now
        }
        tick.prepare()
    }
}

/// Choices in a row that slides under a band, the middle one chosen as it settles. The row keeps
/// its upright layout in every hold, and only each name turns to read.
struct LookCarousel: View {
    let options: [String]
    @Binding var selection: String
    let hold: Hold
    let label: (String) -> String
    var deletable: (String) -> Bool = { _ in false }
    var delete: (String) -> Void = { _ in }
    /// Off when rows stack, so one band runs through both.
    var showsBand = true
    /// A second, grey line under a name, such as ACES 2.0's dynamic range.
    var subtitle: (String) -> String? = { _ in nil }
    /// A tap on the name already in the middle, which opens its own choices.
    var tappedChosen: ((String) -> Void)? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var centered: String?

    /// Room for a name.
    static let itemWidth: CGFloat = 128

    var body: some View {
        GeometryReader { geometry in
            let margin = max((geometry.size.width - Self.itemWidth) / 2, 0)
            ZStack {
                // The band the chosen name sits in.
                if showsBand {
                    RoundedRectangle(cornerRadius: Tokens.panelRadius)
                        .fill(Tokens.surface)
                        .frame(width: Self.itemWidth)
                }
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
        .haptic(.selection, trigger: centered)
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
            if isOn, let tappedChosen {
                tappedChosen(option)
            } else {
                withAnimation(reduceMotion ? nil : .spring(duration: 0.3, bounce: 0.1)) { centered = option }
            }
        } label: {
            VStack(spacing: 1) {
                Text(label(option))
                    .font(Tokens.statusFont)
                    .foregroundStyle(isOn ? Tokens.held : Tokens.value)
                if let line = subtitle(option) {
                    Text("<\(line)>")
                        .font(Tokens.markFont)
                        .foregroundStyle(Tokens.label)
                }
            }
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .frame(width: length)
            .turnedToHold()
                .frame(width: Self.itemWidth, height: height)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            if deletable(option) {
                Button("Delete Style", systemImage: "trash", role: .destructive) { delete(option) }
            }
        }
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
        .haptic(.selection, trigger: centered)
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
            FormatWheel(title: "CODEC", options: families, selection: family, hold: hold, rowDepth: rowDepth) { $0 }
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

    /// Only the codecs this phone has: ProRes from the 13 Pro on.
    private var families: [String] {
        model.recordPresets.contains { !Self.isHEVC($0) } ? ["PRORES", "HEVC"] : ["HEVC"]
    }

    private var chromaChoices: [EncoderPreset] {
        let hevc = Self.isHEVC(model.encoderPreset)
        return model.recordPresets.filter { Self.isHEVC($0) == hevc }
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
                let choices = model.recordPresets.filter { Self.isHEVC($0) == (name == "HEVC") }
                model.encoderPreset = choices.first { $0.id == target } ?? choices.first ?? current
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
