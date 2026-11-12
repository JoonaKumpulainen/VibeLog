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
                Button("Measure this phone again") {
                    close()
                    model.runEncoderTest()
                }
                LabeledContent("Encoder limits", value: model.encoderLimitsText)
                LabeledContent("GPU limits", value: model.gpuLimitsText)
                Button("Run trial takes") {
                    close()
                    model.runTrialTakes()
                }
                .disabled(!model.isStreaming)
                Button("Run GPU cost test") {
                    close()
                    model.runCostTest()
                }
            }
            Section {
                TextField(model.testOverInternet ? "Server, as https://…" : "Server, as 192.168.1.20:8765", text: $model.testServer)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                SecureField("Token", text: $model.testToken)
                Toggle("Over the internet", isOn: $model.testOverInternet)
                Toggle("Connect", isOn: $model.testLinkOn)
                LabeledContent("State", value: model.testLinkState)
                Toggle("Send logs and sidecars after each take", isOn: $model.testSendsResults)
                Toggle("Send gyro and timing files", isOn: $model.testSendsGyro)
            } header: {
                Text("Test link")
            } footer: {
                Text(model.testOverInternet
                    ? "Lets a computer elsewhere change settings, start takes, take stills of what the camera sees and fetch files, through an https:// tunnel such as ngrok, whose servers see everything sent. Only connect to a server you trust, with its long token. Off at every launch."
                    : "Lets your computer change settings and start takes, using tools/test_server.py. It can't delete takes, and videos only go when asked for. Off at every launch. Plain HTTP, so use it on your own network.")
            }
            LogSharingSection(uploader: model.logUploader) { model.shareLogs("asked") }
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

/// Opt-in sharing of test logs with the owner's log service. See docs/decisions/log-service.md.
private struct LogSharingSection: View {
    @ObservedObject var uploader: LogUploader
    let sendNow: () -> Void
    @State private var asksFirst = false

    private func binding<T>(_ key: WritableKeyPath<LogSharingSettings, T>) -> Binding<T> {
        Binding(get: { uploader.settings[keyPath: key] }, set: { value in uploader.update { $0[keyPath: key] = value } })
    }

    var body: some View {
        Section {
            Toggle("Share test logs", isOn: Binding(
                get: { uploader.settings.on },
                set: { on in if on { asksFirst = true } else { uploader.update { $0.on = false } } }))
            if uploader.settings.on {
                TextField("Server, as https://…", text: binding(\.server))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                SecureField("Invite code", text: binding(\.inviteCode))
                Toggle("Include gyro logs", isOn: binding(\.gyro))
                Toggle("Use mobile data", isOn: binding(\.mobileData))
                LabeledContent("State", value: uploader.stateText)
                // The first part of the random ID, to quote when asking for uploads to be deleted.
                LabeledContent("Anonymous ID", value: String(uploader.settings.installID.prefix(8)))
                    .textSelection(.enabled)
                if let last = uploader.settings.lastUpload {
                    LabeledContent("Last sent", value: last.formatted(date: .abbreviated, time: .shortened))
                }
                Button("Send now", action: sendNow)
                    .disabled(uploader.busy)
                Button("New anonymous ID") { uploader.update { $0.startAfresh() } }
            }
        } header: {
            Text("Log sharing")
        } footer: {
            Text("Sends session logs, take details, test reports and lens profiles to the VibeLog test service, never during a take, on Wi-Fi, or on mobile data too with its switch on, and never in Low Data Mode. Never videos, stills or what the camera sees. Dates, network addresses and names you typed are taken out first, and the phone is known only by a random ID. Gyro logs, which describe how the phone moved, only go with their switch on.")
        }
        .alert("Share test logs?", isPresented: $asksFirst) {
            Button("Share") { uploader.update { $0.on = true } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your phone model, iOS and app versions, settings, frame counts, heat and errors go to the VibeLog test service, with a random ID instead of anything about you. You can turn it off, or start a new ID, at any time.")
        }
    }
}
