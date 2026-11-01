import SwiftUI
import VLCapture
import VLProcessing

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @AppStorage("debugOverlay") private var showDebugOverlay = false
    @State private var showSettings = false

    var body: some View {
        VStack(spacing: 0) {
            topBar
            viewfinder
            bottomBar
        }
        .background(Color.black.ignoresSafeArea())
        .sensoryFeedback(.impact(weight: .medium), trigger: model.isRecording)
        .sensoryFeedback(.selection, trigger: model.lensID)
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
        .alert("Camera access is off", isPresented: $model.permissionDenied) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Allow camera access for VibeLog in Settings.")
        }
    }

    private var topBar: some View {
        ZStack {
            statusText
            HStack {
                if model.processing.monitor != .isp {
                    monitorMenu
                }
                Spacer()
            }
        }
        .frame(height: 44)
        .padding(.horizontal, 16)
    }

    @ViewBuilder
    private var statusText: some View {
        if model.isRecording {
            HStack(spacing: 6) {
                Circle().fill(.red).frame(width: 8, height: 8)
                Text(timecode)
            }
            .font(.headline.monospacedDigit())
            .foregroundStyle(.white)
            .accessibilityLabel("Recording, \(model.recordElapsed) seconds")
        } else {
            Text("\(model.encoderPreset.label) · \(model.outputLabel) · \(model.processing.curve.label)")
                .font(.footnote.weight(.medium))
                .foregroundStyle(.white.opacity(0.75))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .padding(.horizontal, 48)
        }
    }

    private var timecode: String {
        let elapsed = model.recordElapsed
        return String(format: "%02d:%02d:%02d", elapsed / 3600, elapsed / 60 % 60, elapsed % 60)
    }

    /// Only changes what the monitor draws, so it stays available while recording.
    private var monitorMenu: some View {
        Menu {
            Picker("Monitor", selection: $model.processing.monitor) {
                ForEach([MonitorMode.rec709, .log]) { Text($0.label).tag($0) }
            }
            Picker("Exposure tool", selection: $model.processing.overlay) {
                ForEach(ExposureOverlay.allCases) { Text($0.label).tag($0) }
            }
        } label: {
            Image(systemName: model.processing.overlay == .none ? "eye" : "eye.fill")
                .font(.body.weight(.medium))
                .foregroundStyle(model.processing.overlay == .none ? Color.white : Color.yellow)
                .frame(width: 44, height: 44)
        }
        .accessibilityLabel("Monitor and exposure tools")
    }

    private var viewfinder: some View {
        ZStack {
            SessionPreview(session: model.camera.session)
            if let pipeline = model.pipeline, model.method.isPhoto,
                model.processing.enabled, model.processing.monitor != .isp {
                ProcessedMonitor(pipeline: pipeline)
            }
            VStack(spacing: 8) {
                if showDebugOverlay {
                    DebugOverlay()
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if let notice = model.notice {
                    Text(notice)
                        .font(.footnote.weight(.semibold))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding(.top, 8)
                }
                Spacer()
                lensPicker
                    .padding(.bottom, 12)
            }
            if let busy = model.isBusy {
                ProgressView(busy)
                    .padding()
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .aspectRatio(3.0 / 4.0, contentMode: .fit)
        .clipped()
        .background(.black)
    }

    @ViewBuilder
    private var lensPicker: some View {
        if model.lenses.count > 1 {
            HStack(spacing: 8) {
                ForEach(model.lenses.sorted { $0.zoom < $1.zoom }) { lens in
                    let selected = lens.id == model.lensID
                    Button {
                        model.lensID = lens.id
                    } label: {
                        Text(lens.zoomLabel)
                            .font(.caption.weight(.semibold).monospacedDigit())
                            .foregroundStyle(selected ? Color.yellow : Color.white)
                            .frame(width: selected ? 40 : 32, height: selected ? 40 : 32)
                            .background(.ultraThinMaterial, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(lens.name)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
            .frame(height: 44)
            .animation(.easeOut(duration: 0.15), value: model.lensID)
            // Changing lens rebuilds the capture session, which would end a recording.
            .disabled(model.isRecording || model.isBusy != nil)
            .opacity(model.isRecording ? 0.4 : 1)
        }
    }

    private var bottomBar: some View {
        HStack {
            // Holds the place of the library button.
            Color.clear.frame(width: 52, height: 52)
            Spacer()
            RecordButton(isRecording: model.isRecording) { model.toggleRecord() }
                .disabled(model.isBusy != nil)
            Spacer()
            Button {
                showSettings = true
            } label: {
                Image(systemName: "gearshape")
                    .font(.title3)
                    .foregroundStyle(.white)
                    .frame(width: 52, height: 52)
                    .background(.white.opacity(0.12), in: Circle())
            }
            .accessibilityLabel("Settings")
            .disabled(model.isRecording || model.isBusy != nil)
            .opacity(model.isRecording ? 0.4 : 1)
        }
        .padding(.horizontal, 28)
        .frame(maxHeight: .infinity)
    }
}

struct RecordButton: View {
    let isRecording: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .strokeBorder(.white, lineWidth: 4)
                RoundedRectangle(cornerRadius: isRecording ? 6 : 29)
                    .fill(.red)
                    .frame(width: isRecording ? 30 : 58, height: isRecording ? 30 : 58)
            }
            .frame(width: 72, height: 72)
            .animation(.easeOut(duration: 0.2), value: isRecording)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isRecording ? "Stop recording" : "Record")
    }
}

private extension LensInfo {
    /// Names start with their zoom, as in "0.5x Ultra Wide".
    var zoomLabel: String { String(name.prefix { $0 != " " }) }
    var zoom: Double { Double(zoomLabel.dropLast()) ?? 1 }
}
