import SwiftUI
import VLCore

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @State private var showLog = false

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .topLeading) {
                SessionPreview(session: model.camera.session)
                DebugOverlay()
                if let renderer = model.preview {
                    RawMonitor(renderer: renderer)
                        .aspectRatio(3.0 / 4.0, contentMode: .fit)
                        .frame(width: 120)
                        .border(.white.opacity(0.5))
                        .overlay(alignment: .bottom) {
                            Text("RAW").font(.caption2.bold())
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                        .padding(6)
                }
                if let busy = model.isBusy {
                    ProgressView(busy)
                        .padding()
                        .background(.black.opacity(0.8), in: RoundedRectangle(cornerRadius: 8))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxHeight: .infinity)
            .background(.black)

            transport
            ControlPanel()
                .frame(height: 280)
        }
        .sheet(isPresented: $showLog) {
            LogView()
        }
        .alert("Camera access is off", isPresented: $model.permissionDenied) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Allow camera access for VibeLog in Settings.")
        }
    }

    private var transport: some View {
        HStack(spacing: 10) {
            Button(model.isStreaming ? "Stop" : "Stream") { model.toggleStream() }
                .buttonStyle(.bordered)
            Button {
                model.toggleRecord()
            } label: {
                Label(model.isRecording ? "Recording" : "Record", systemImage: "record.circle")
            }
            .buttonStyle(.borderedProminent)
            .tint(model.isRecording ? Color.red : Color.accentColor)
            Button("Probe") { model.runProbe() }
                .buttonStyle(.bordered)
            Button("Log") { showLog = true }
                .buttonStyle(.bordered)
        }
        .disabled(model.isBusy != nil)
        .padding(.vertical, 6)
    }
}

struct DebugOverlay: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject private var log = Log.shared

    var body: some View {
        let stats = model.stats
        VStack(alignment: .leading, spacing: 1) {
            line(model.method.label)
            line(String(format: "fps %.2f now  %.2f sustained  n=%d", stats.rollingFPS, stats.sustainedFPS, stats.frames))
            line(String(format: "gap ms med %.1f p95 %.1f max %.1f", stats.gapMedianMs, stats.gapP95Ms, stats.gapMaxMs))
            line("drops cap \(stats.captureDrops) writer \(stats.writerDrops) fail \(stats.captureFailures) missed~\(stats.estimatedMissed)")
            line(frameLine)
            line("thermal \(model.status.thermal)  mem \(model.status.footprintMB) MB  avail \(model.status.availableMB) MB")
            line("disk free \(model.status.freeDiskGB) GB")
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
