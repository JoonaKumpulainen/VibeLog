import SwiftUI
import UniformTypeIdentifiers
import VLCapture
import VLCore
import VLProcessing
import VLRecording

struct ControlPanel: View {
    @EnvironmentObject private var model: AppModel
    @State private var importingLUT = false

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
                    Picker("Monitor LUT", selection: $model.selectedLUT) {
                        Text("Rec.709").tag("")
                        ForEach(model.lutNames, id: \.self) { Text($0).tag($0) }
                    }
                    Button("Import .cube LUT") { importingLUT = true }
                    Picker("Exposure tool", selection: $model.processing.overlay) {
                        ForEach(ExposureOverlay.allCases) { Text($0.label).tag($0) }
                    }
                    Toggle("Monitor off while recording", isOn: $model.processing.pauseMonitorWhileRecording)
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
                Toggle("Encode video (off: RAW dump)", isOn: $model.recordEncoded)
                if model.recordEncoded {
                    Picker("Encoder", selection: $model.encoderPreset) {
                        ForEach(EncoderPreset.all) { Text($0.label).tag($0) }
                    }
                    Picker("Size", selection: $model.encoderSize) {
                        ForEach(EncoderSize.all) { Text($0.label).tag($0) }
                    }
                    Picker("Aspect", selection: $model.widescreen) {
                        Text("4:3 open gate").tag(false)
                        Text("16:9").tag(true)
                    }
                    Button("Run encoder test") { model.runEncoderTest() }
                }
                Picker("Duration", selection: $model.recordSeconds) {
                    Text("10 seconds").tag(10.0)
                    Text("30 seconds").tag(30.0)
                    Text("1 minute").tag(60.0)
                    Text("2 minutes").tag(120.0)
                    Text("5 minutes").tag(300.0)
                    Text("10 minutes").tag(600.0)
                    Text("30 minutes").tag(1800.0)
                    Text("Until stopped").tag(0.0)
                }
                if !model.recordEncoded {
                    Toggle("Write frames to disk", isOn: $model.writeFrames)
                }
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
        .fileImporter(isPresented: $importingLUT, allowedContentTypes: [.data]) { result in
            switch result {
            case .success(let url): model.importLUT(from: url)
            case .failure(let error): Log.shared.error("LUT picker failed: \(error.localizedDescription)")
            }
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

    private func labeled<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack {
            Text(title).font(.caption.monospacedDigit()).frame(width: 90, alignment: .leading)
            content()
        }
    }
}
