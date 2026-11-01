import SwiftUI
import UniformTypeIdentifiers
import VLCore
import VLProcessing
import VLRecording

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var importingLUT = false
    @State private var showDiagnostics = false

    var body: some View {
        NavigationStack {
            Form {
                recording
                image
                monitor
                tools
                whiteBalance
                Section {
                    LabeledContent("Version", value: Self.version)
                        .contentShape(Rectangle())
                        .onLongPressGesture { showDiagnostics = true }
                        .accessibilityAction(named: "Open diagnostics") { showDiagnostics = true }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .navigationDestination(isPresented: $showDiagnostics) {
                DiagnosticsView { dismiss() }
            }
        }
        .fileImporter(isPresented: $importingLUT, allowedContentTypes: [.data]) { result in
            switch result {
            case .success(let url): model.importLUT(from: url)
            case .failure(let error): Log.shared.error("LUT picker failed: \(error.localizedDescription)")
            }
        }
    }

    private static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "-"
    }

    private var recording: some View {
        Section("Recording") {
            Picker("Codec", selection: $model.encoderPreset) {
                ForEach(EncoderPreset.all) { Text($0.label).tag($0) }
            }
            Picker("Size", selection: $model.encoderSize) {
                ForEach(EncoderSize.all) { Text($0.label).tag($0) }
            }
            Picker("Aspect", selection: $model.widescreen) {
                Text("4:3 open gate").tag(false)
                Text("16:9").tag(true)
            }
            Picker("Stop after", selection: $model.recordSeconds) {
                Text("Never").tag(0.0)
                Text("10 seconds").tag(10.0)
                Text("30 seconds").tag(30.0)
                Text("1 minute").tag(60.0)
                Text("2 minutes").tag(120.0)
                Text("5 minutes").tag(300.0)
                Text("10 minutes").tag(600.0)
                Text("30 minutes").tag(1800.0)
            }
        }
    }

    private var image: some View {
        Section("Image") {
            Picker("Log curve", selection: $model.processing.curve) {
                ForEach(LogCurve.allCases) { Text($0.label).tag($0) }
            }
            LabeledContent("Color space", value: "Rec.2020")
            Picker("Pipeline", selection: $model.processing.pipeline) {
                ForEach(PipelineMode.allCases) { Text($0.label).tag($0) }
            }
            Picker("Debayer", selection: $model.processing.demosaic) {
                ForEach(DemosaicMethod.allCases) { Text($0.label).tag($0) }
            }
            labeled(String(format: "Exposure %+.1f", model.processing.exposureStops)) {
                Slider(value: $model.processing.exposureStops, in: -3...3, step: 0.1)
            }
            Toggle("Reduce load when hot", isOn: $model.processing.reduceLoadWhenHot)
        }
    }

    private var monitor: some View {
        Section("Monitor") {
            Picker("Monitor", selection: $model.processing.monitor) {
                ForEach(MonitorMode.allCases) { Text($0.label).tag($0) }
            }
            Picker("Monitor LUT", selection: $model.selectedLUT) {
                Text("Rec.709").tag("")
                ForEach(model.lutNames, id: \.self) { Text($0).tag($0) }
            }
            Button("Import .cube LUT") { importingLUT = true }
            if !model.selectedLUT.isEmpty {
                Picker("LUT input", selection: $model.processing.lutExpectsRec709) {
                    Text("Log").tag(false)
                    Text("Rec.709").tag(true)
                }
            }
            Picker("Exposure tool", selection: $model.processing.overlay) {
                ForEach(ExposureOverlay.allCases) { Text($0.label).tag($0) }
            }
            Toggle("Monitor off while recording", isOn: $model.processing.pauseMonitorWhileRecording)
            Toggle("Telemetry while recording", isOn: $model.showTelemetry)
            Picker("Mains", selection: $model.mainsHz) {
                Text("50 Hz").tag(50)
                Text("60 Hz").tag(60)
            }
        }
    }

    private var tools: some View {
        Section {
            ForEach(Tool.allCases) { tool in
                Toggle(isOn: Binding(
                    get: { model.toolbar.contains(tool) },
                    set: { model.setTool(tool, inToolbar: $0) })
                ) {
                    Label(tool.title, systemImage: tool.symbol)
                }
            }
        } header: {
            Text("Toolbar")
        } footer: {
            Text("All choices save to VibeLog.config.json in the VibeLog folder. Edit it in the Files app, then reopen VibeLog.")
        }
    }

    private var whiteBalance: some View {
        Section("White balance") {
            labeled("Tint \(Int(model.tint))") {
                Slider(value: $model.tint, in: -150...150)
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
