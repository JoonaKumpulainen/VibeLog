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
    @ObservedObject var hold: HoldTracker
    @State private var showSettings = false
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
            ZStack {
                Color.black
                viewfinder(screen)
                HeldLayout(hold: hold.hold, screen: screen, insets: insets) { heldInsets in
                    CameraHUD(
                        selectedDial: $selectedDial, isLandscape: hold.hold.isLandscape,
                        insets: heldInsets, openSettings: { showSettings = true })
                }
                .id(hold.hold.label)
                .transition(.opacity)
            }
            .animation(.easeOut(duration: 0.2), value: hold.hold)
            .frame(width: screen.width, height: screen.height)
            .ignoresSafeArea()
        }
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .sensoryFeedback(.impact(weight: .medium), trigger: model.isRecording)
        .sensoryFeedback(.selection, trigger: model.lensID)
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
    }

    /// The sensor stays fixed to the phone, so the picture is upright in every hold. 16:9 keeps
    /// three quarters of the sensor height, which is the screen's width, so it scales up to fill it.
    private func viewfinder(_ screen: CGSize) -> some View {
        let portraitHeight = screen.width * 4 / 3
        let zoom = model.widescreen ? min(4.0 / 3, screen.height / portraitHeight) : 1
        let imageWidth = screen.width * zoom
        let imageHeight = portraitHeight * zoom
        let shownWidth = model.widescreen ? imageWidth * 0.75 : imageWidth
        return ZStack {
            SessionPreview(session: model.camera.session)
            if let pipeline = model.pipeline, model.method.isPhoto,
                model.processing.enabled, model.processing.monitor != .isp {
                ProcessedMonitor(pipeline: pipeline)
            }
            touchLayer
        }
        .frame(width: imageWidth, height: imageHeight)
        .frame(width: shownWidth, height: imageHeight)
        .clipped()
        .overlay {
            FrameMarks()
                .stroke(.white.opacity(0.7), lineWidth: 1)
                .allowsHitTesting(false)
        }
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
                        .rotationEffect(.degrees(hold.hold.angle))
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

/// Everything that floats on the picture, laid out for how the phone is held.
struct CameraHUD: View {
    @EnvironmentObject private var model: AppModel
    @AppStorage("debugOverlay") private var showDebugOverlay = false
    @AppStorage("telemetry") private var showTelemetry = true
    @Binding var selectedDial: ControlDial?
    let isLandscape: Bool
    let insets: EdgeInsets
    let openSettings: () -> Void

    var body: some View {
        Group {
            if isLandscape {
                HStack(spacing: 12) {
                    VStack(spacing: 8) {
                        header
                        Spacer(minLength: 0)
                        lensRow
                        ControlPanels(selected: $selectedDial)
                    }
                    VStack {
                        formatButton
                        Spacer()
                        recordButton
                        Spacer()
                        monitorMenu
                    }
                }
            } else {
                VStack(spacing: 8) {
                    header
                    Spacer(minLength: 0)
                    lensRow
                    ControlPanels(selected: $selectedDial)
                    HStack {
                        monitorMenu
                        Spacer()
                        recordButton
                        Spacer()
                        formatButton
                    }
                    .padding(.horizontal, 8)
                }
            }
        }
        .padding(.top, max(insets.top, 10))
        .padding(.bottom, max(insets.bottom, 10))
        .padding(.leading, max(insets.leading, 12))
        .padding(.trailing, max(insets.trailing, 12))
    }

    private var header: some View {
        VStack(spacing: 8) {
            if model.isRecording {
                recordingLine
            } else {
                signalPath
            }
            if showDebugOverlay {
                DebugOverlay()
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let notice = model.notice {
                Text(notice)
                    .font(Tokens.lineFont)
                    .foregroundStyle(Tokens.value)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .instrumentPanel()
            }
            if let busy = model.isBusy {
                ProgressView(busy)
                    .font(Tokens.lineFont)
                    .padding(10)
                    .instrumentPanel()
            }
        }
    }

    private var signalPath: some View {
        Button(action: openSettings) {
            VStack(spacing: 2) {
                HStack {
                    Text(model.signalPath).foregroundStyle(Tokens.value)
                    Spacer(minLength: 8)
                }
                HStack {
                    Text(model.outputLabel)
                    Spacer(minLength: 8)
                    Text(model.timeLeftLabel)
                    Text(model.batteryLabel)
                }
                .foregroundStyle(Tokens.label)
            }
            .font(Tokens.lineFont)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
        }
        .buttonStyle(.plain)
        .disabled(model.isBusy != nil)
        .accessibilityLabel("Format, \(model.signalPath), \(model.timeLeftLabel) left")
    }

    private var recordingLine: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Circle().fill(Tokens.record).frame(width: 7, height: 7)
                Text(timecode).font(Tokens.valueFont)
            }
            .foregroundStyle(Tokens.value)
            .padding(.horizontal, 8)
            .frame(height: 28)
            .instrumentPanel()
            .accessibilityLabel("Recording, \(model.recordElapsed) seconds")
            Spacer(minLength: 0)
            if showTelemetry {
                Text(telemetry)
                    .font(Tokens.lineFont)
                    .foregroundStyle(Tokens.value)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .padding(.horizontal, 8)
                    .frame(height: 28)
                    .instrumentPanel()
            }
        }
    }

    private var timecode: String {
        let elapsed = model.recordElapsed
        return String(format: "%02d:%02d:%02d", elapsed / 3600, elapsed / 60 % 60, elapsed % 60)
    }

    private var telemetry: String {
        String(
            format: "%.2f FPS  %.0f MB/S  GPU %.0f  %@", model.stats.rollingFPS, model.dataRate,
            model.pipelineStats.gpuRecentMs, model.status.thermal.uppercased())
    }

    @ViewBuilder
    private var lensRow: some View {
        if model.lenses.count > 1 {
            HStack {
                Spacer()
                HStack(spacing: 0) {
                    ForEach(model.lenses.sorted { $0.zoom < $1.zoom }) { lens in
                        let selected = lens.id == model.lensID
                        Button {
                            model.lensID = lens.id
                        } label: {
                            Text(lens.zoomLabel)
                                .font(Tokens.lineFont)
                                .foregroundStyle(selected ? Tokens.held : Tokens.value)
                                .frame(width: 40, height: 30)
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
                .opacity(model.isRecording ? 0.4 : 1)
            }
        }
    }

    private var recordButton: some View {
        RecordButton(isRecording: model.isRecording) { model.toggleRecord() }
            .disabled(model.isBusy != nil)
    }

    private var formatButton: some View {
        Button(action: openSettings) {
            Text("FMT")
                .font(Tokens.lineFont)
                .foregroundStyle(Tokens.value)
                .frame(width: 48, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .instrumentPanel()
        .disabled(model.isRecording || model.isBusy != nil)
        .opacity(model.isRecording ? 0.4 : 1)
        .accessibilityLabel("Format and settings")
    }

    /// Only changes what the monitor draws, so it stays available while recording.
    @ViewBuilder
    private var monitorMenu: some View {
        if model.processing.monitor != .isp {
            Menu {
                Picker("Monitor", selection: $model.processing.monitor) {
                    ForEach([MonitorMode.rec709, .log]) { Text($0.label).tag($0) }
                }
                Picker("Exposure tool", selection: $model.processing.overlay) {
                    ForEach(ExposureOverlay.allCases) { Text($0.label).tag($0) }
                }
            } label: {
                Text("MON")
                    .font(Tokens.lineFont)
                    .foregroundStyle(model.processing.overlay == .none ? Tokens.value : Tokens.held)
                    .frame(width: 48, height: 44)
                    .contentShape(Rectangle())
            }
            .instrumentPanel()
            .accessibilityLabel("Monitor and exposure tools")
        } else {
            Color.clear.frame(width: 48, height: 44)
        }
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
