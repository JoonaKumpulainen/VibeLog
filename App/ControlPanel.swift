import SwiftUI
import VLCapture
import VLCore
import VLProcessing

struct ControlPanel: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Form {
            Section("Capture") {
                Picker("Lens", selection: $model.lensID) {
                    ForEach(model.lenses) { Text($0.name).tag($0.id) }
                }
                Picker("Method", selection: $model.method) {
                    ForEach(CaptureMethod.allCases) { Text($0.label).tag($0) }
                }
                if model.method.isPhoto {
                    Toggle("Use Photo preset", isOn: $model.usePhotoPreset)
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
            if model.method.isPhoto {
                Section("Processing") {
                    Toggle("GPU pipeline", isOn: $model.processing.enabled)
                    Picker("Monitor", selection: $model.processing.monitor) {
                        ForEach(MonitorMode.allCases) { Text($0.label).tag($0) }
                    }
                    Picker("Log curve", selection: $model.processing.curve) {
                        ForEach(LogCurve.allCases) { Text($0.label).tag($0) }
                    }
                    Picker("Debayer", selection: $model.processing.demosaic) {
                        ForEach(DemosaicMethod.allCases) { Text($0.label).tag($0) }
                    }
                    labeled(String(format: "Exposure %+.1f", model.processing.exposureStops)) {
                        Slider(value: $model.processing.exposureStops, in: -3...3, step: 0.1)
                    }
                }
            }
            Section("Recording") {
                Stepper(value: $model.recordSeconds, in: 1...120) {
                    Text("Duration \(Int(model.recordSeconds)) s")
                }
                Toggle("Write frames to disk", isOn: $model.writeFrames)
            }
            Section("Exposure") {
                Toggle("Lock ISO and shutter", isOn: $model.exposureLocked)
                if let range = model.options?.isoRange {
                    labeled("ISO \(Int(model.iso))") {
                        Slider(value: $model.iso, in: range)
                    }
                }
                labeled("Shutter \(model.shutterLabel)") {
                    Slider(value: $model.shutterStops, in: 3...13)
                }
            }
            Section("White balance") {
                Toggle("Lock white balance", isOn: $model.whiteBalanceLocked)
                labeled("\(Int(model.temperature)) K") {
                    Slider(value: $model.temperature, in: 2500...9000)
                }
                labeled("Tint \(Int(model.tint))") {
                    Slider(value: $model.tint, in: -150...150)
                }
            }
            Section("Focus") {
                Toggle("Lock focus", isOn: $model.focusLocked)
                labeled(String(format: "Lens %.2f", model.lensPosition)) {
                    Slider(value: $model.lensPosition, in: 0...1)
                }
            }
        }
        .disabled(model.isRecording)
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

    private func labeled<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack {
            Text(title).font(.caption.monospacedDigit()).frame(width: 90, alignment: .leading)
            content()
        }
    }
}
