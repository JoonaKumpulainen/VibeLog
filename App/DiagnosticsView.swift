import SwiftUI
import VLCapture
import VLCore

/// Test tools for phone runs, opened from Advanced in Settings.
struct DiagnosticsView: View {
    @EnvironmentObject private var model: AppModel
    @AppStorage("debugOverlay") private var showDebugOverlay = false
    @State private var showLog = false
    /// Closes Settings, so a running test shows on the camera screen.
    let close: () -> Void

    init(close: @escaping () -> Void) {
        self.close = close
    }

    var body: some View {
        Form {
            Section {
                Toggle("Debug overlay", isOn: $showDebugOverlay)
                Button("Show log") { showLog = true }
                if let result = model.lastResult {
                    Text(result).font(.caption.monospaced()).textSelection(.enabled)
                }
            }
            Section {
                Button("Run control test") {
                    close()
                    model.runControlTest()
                }
                .disabled(!model.isStreaming || !model.recordEncoded)
            } footer: {
                Text("Records \(Int(AppModel.controlTestSeconds)) seconds and changes focus and exposure during it. Keep the phone still and pointed at a detailed scene.")
            }
            Section("Tools") {
                Button(model.isStreaming ? "Stop stream" : "Start stream") { model.toggleStream() }
                Button("Save still") { model.saveStill() }
                    .disabled(!model.isStreaming)
                Button("Run probe") {
                    close()
                    model.runProbe()
                }
                Button("Run 48mm RAW probe") {
                    close()
                    model.runZoomRawProbe()
                }
                Button("Run encoder test") {
                    close()
                    model.runEncoderTest()
                }
            }
            Section {
                TextField("Server, as 192.168.1.20:8765", text: $model.testServer)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                SecureField("Token", text: $model.testToken)
                Toggle("Connect", isOn: $model.testLinkOn)
                LabeledContent("State", value: model.testLinkState)
                Toggle("Send logs and sidecars after each take", isOn: $model.testSendsResults)
                Toggle("Send gyro and timing files", isOn: $model.testSendsGyro)
            } header: {
                Text("Test link")
            } footer: {
                Text("Lets your computer change settings and start takes, using tools/test_server.py. It can't delete takes, and videos only go when asked for. Off at every launch. Plain HTTP, so use it on your own network.")
            }
            Section("Capture") {
                Picker("Method", selection: $model.method) {
                    ForEach(CaptureMethod.allCases) { Text($0.label).tag($0) }
                }
                if model.method.isPhoto {
                    Toggle("Use Photo preset", isOn: $model.usePhotoPreset)
                    Toggle("Fixed frame time at 30 fps", isOn: $model.fixedFrameTime)
                }
                if !model.method.isPhoto || !model.usePhotoPreset {
                    Picker("Format", selection: $model.formatIndex) {
                        ForEach(model.formats) { Text($0.label).tag($0.id) }
                    }
                }
                if model.method.isPhoto {
                    photoControls
                } else {
                    videoControls
                }
            }
            Section("Recording") {
                if model.method.isPhoto {
                    Toggle("GPU pipeline", isOn: $model.processing.enabled)
                }
                Toggle("Encode video (off: RAW dump)", isOn: $model.recordEncoded)
                if !model.recordEncoded {
                    Toggle("Write frames to disk", isOn: $model.writeFrames)
                }
                if model.recordEncoded {
                    Toggle("Log capture timing", isOn: $model.logCaptureTiming)
                }
                Toggle(isOn: $model.disconnectAppPreview) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Disconnect Apple's preview")
                        Text("Takes the hidden preview off the camera while VibeLog's own viewfinder shows, to measure its heat. It stays connected for the ISP preview look.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .disabled(model.isRecording)
            }
        }
        .onAppear { model.diagnosticsOpened() }
        .onDisappear { model.diagnosticsClosed() }
        .navigationTitle("Diagnostics")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showLog) {
            LogView()
        }
    }

    @ViewBuilder
    private var photoControls: some View {
        if let options = model.options {
            Picker("RAW type", selection: $model.rawFormat) {
                ForEach(options.rawPhotoTypes, id: \.self) {
                    Text(PixelFormats.fourCC($0)).tag($0)
                }
            }
            Picker("Photo size", selection: $model.photoSize) {
                ForEach(options.photoSizes, id: \.self) {
                    Text($0.label).tag(Optional($0))
                }
            }
            if model.method == .photoBracket, options.maxBracketCount > 1 {
                Stepper(value: $model.bracketCount, in: 1...options.maxBracketCount) {
                    Text("Bracket \(model.bracketCount) frames")
                }
            }
        }
    }

    @ViewBuilder
    private var videoControls: some View {
        if let options = model.options {
            Picker("Pixel format", selection: $model.videoFormat) {
                ForEach(options.videoTypes, id: \.self) {
                    Text(PixelFormats.fourCC($0)).tag($0)
                }
            }
            Stepper(value: $model.videoFPS, in: 1...60) {
                Text("Frame rate \(Int(model.videoFPS))")
            }
        }
    }
}

struct DebugOverlay: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject private var log = Log.shared

    var body: some View {
        let stats = model.stats
        VStack(alignment: .leading, spacing: 1) {
            line(model.method.label)
            if model.isRecording {
                line(String(format: "REC %02d:%02d", model.recordElapsed / 60, model.recordElapsed % 60))
            }
            line(String(format: "fps %.2f now  %.2f sustained  n=%d", stats.rollingFPS, stats.sustainedFPS, stats.frames))
            line(String(format: "gap ms med %.1f p95 %.1f max %.1f", stats.gapMedianMs, stats.gapP95Ms, stats.gapMaxMs))
            line(String(
                format: "gpu %.1f ms now %.1f max  done %d drop %d", model.pipelineStats.gpuRecentMs,
                model.pipelineStats.gpuMaxMs, model.pipelineStats.processed, model.pipelineStats.dropped))
            line("drops cap \(stats.captureDrops) writer \(stats.writerDrops) fail \(stats.captureFailures) missed~\(stats.estimatedMissed)")
            line(frameLine)
            line("thermal \(model.status.thermal)  mem \(model.status.footprintMB) MB  avail \(model.status.availableMB) MB")
            line("disk free \(model.status.freeDiskGB) GB  battery \(model.status.battery)")
            if let error = log.lastError {
                Text("errors \(log.errorCount): \(error)")
                    .foregroundStyle(.red)
                    .lineLimit(3)
            }
            if let result = model.lastResult {
                Text(result).foregroundStyle(.yellow).lineLimit(4)
            }
        }
        .font(.system(size: 11, design: .monospaced))
        .padding(6)
        .background(.black.opacity(0.55))
        .foregroundStyle(.green)
    }

    private var frameLine: String {
        if model.method.isPhoto {
            let raw = model.rawFormat == 0 ? "no RAW" : PixelFormats.fourCC(model.rawFormat)
            return "frame \(raw) \(model.photoSize?.label ?? "-")"
        }
        let format = model.videoFormat == 0 ? "-" : PixelFormats.fourCC(model.videoFormat)
        let info = model.formats.first { $0.id == model.formatIndex }
        return "frame \(format) \(info?.width ?? 0)x\(info?.height ?? 0)"
    }

    private func line(_ text: String) -> some View {
        Text(text).lineLimit(1).minimumScaleFactor(0.7)
    }
}
