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
    @ObservedObject var hold: HoldTracker
    @State private var showSettings = false
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
            ZStack(alignment: .topLeading) {
                Color.black
                viewfinder(layout.picture.size)
                    .offset(x: layout.picture.minX, y: layout.picture.minY)
                HeldLayout(
                    hold: hold.hold, screen: layout.band.size,
                    insets: EdgeInsets(top: 0, leading: 0, bottom: insets.bottom, trailing: 0)
                ) { heldInsets in
                    ControlBand(
                        hold: hold.hold, isCompact: layout.isCompact, insets: heldInsets,
                        openSettings: { showSettings = true })
                }
                .id(hold.hold.label)
                .transition(.opacity)
                .offset(y: layout.band.minY)
            }
            .animation(.easeOut(duration: 0.15), value: hold.hold)
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
    /// three quarters of the sensor height, which is the screen's width.
    private func viewfinder(_ size: CGSize) -> some View {
        let imageWidth = model.widescreen ? size.width / 0.75 : size.width
        return ZStack {
            ZStack {
                SessionPreview(session: model.camera.session)
                if let pipeline = model.pipeline, model.method.isPhoto,
                    model.processing.enabled, model.processing.monitor != .isp {
                    ProcessedMonitor(pipeline: pipeline)
                }
                touchLayer
            }
            .frame(width: imageWidth, height: size.height)
            .scaleEffect(model.isOn(.punchIn) ? 3 : 1)
            FrameGuides(
                grid: model.isOn(.grid), center: model.isOn(.center),
                levelDegrees: model.isOn(.level) ? hold.levelDegrees : nil,
                gravityDegrees: hold.hold.gravityDegrees)
            HeldLayout(
                hold: hold.hold, screen: size, insets: EdgeInsets()
            ) { _ in
                VStack(spacing: 8) {
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
                            .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 4))
                    }
                    if let busy = model.isBusy {
                        ProgressView(busy)
                            .font(Tokens.lineFont)
                            .padding(10)
                            .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 4))
                    }
                    Spacer(minLength: 0)
                }
                .padding(8)
                .allowsHitTesting(false)
            }
        }
        .frame(width: size.width, height: size.height)
        .clipped()
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

extension LensInfo {
    /// Names start with their zoom, as in "0.5x Ultra Wide".
    var zoomLabel: String { String(name.prefix { $0 != " " }) }
    var zoom: Double { Double(zoomLabel.dropLast()) ?? 1 }
}
