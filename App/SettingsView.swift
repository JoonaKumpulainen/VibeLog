import SwiftUI
import UniformTypeIdentifiers
import VLCore
import VLProcessing
import VLRecording

/// Full-screen settings, laid out like Apple's: a list of icons that open their own pages.
struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var importingLUT = false
    @State private var showDiagnostics = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    row("Recording", "record.circle", "Codec, size and aspect", model.encoderPreset.label) {
                        recording
                    }
                    row("Image", "camera.aperture", "Log curve, pipeline and debayer", model.curveLabel) {
                        image
                    }
                    row("Monitor", "display", "What the viewfinder shows", model.processing.monitor.label) {
                        monitor
                    }
                    row("Camera", "slider.horizontal.3", "Locks and mains", "\(model.mainsHz) Hz") {
                        camera
                    }
                }
                Section {
                    row("About", "info.circle", "Version and saved settings", Self.version) {
                        about
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
        .tint(Tokens.held)
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

    /// An icon, a title with a line about it, and the current value.
    private func row<Page: View>(
        _ title: String, _ symbol: String, _ detail: String, _ value: String,
        @ViewBuilder page: () -> Page
    ) -> some View {
        NavigationLink {
            Form { page() }
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.system(size: 16))
                    .foregroundStyle(Tokens.held)
                    .frame(width: 30, height: 30)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Text(value)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    /// A setting's name, with a line explaining it.
    private func explained(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var recording: some View {
        Picker(selection: $model.encoderPreset) {
            ForEach(EncoderPreset.all) { Text($0.label).tag($0) }
        } label: {
            explained("Codec", "ProRes 422 HQ is about 9.5 GB a minute.")
        }
        Picker(selection: $model.encoderSize) {
            ForEach(EncoderSize.all) { Text($0.label).tag($0) }
        } label: {
            explained("Size", "The largest size keeps every sensor pixel.")
        }
        Picker(selection: $model.widescreen) {
            Text("4:3 open gate").tag(false)
            Text("16:9").tag(true)
        } label: {
            explained("Aspect", "Open gate keeps the whole sensor height.")
        }
        Picker(selection: $model.recordSeconds) {
            Text("Never").tag(0.0)
            Text("10 seconds").tag(10.0)
            Text("30 seconds").tag(30.0)
            Text("1 minute").tag(60.0)
            Text("2 minutes").tag(120.0)
            Text("5 minutes").tag(300.0)
            Text("10 minutes").tag(600.0)
            Text("30 minutes").tag(1800.0)
        } label: {
            explained("Stop after", "Ends a take on its own.")
        }
    }

    @ViewBuilder
    private var image: some View {
        Picker(selection: $model.processing.curve) {
            ForEach(LogCurve.allCases) { Text($0.label).tag($0) }
        } label: {
            explained("Log curve", "Baked into the file. Match it when grading.")
        }
        LabeledContent("Color space", value: "Rec.2020")
        Picker(selection: $model.processing.pipeline) {
            ForEach(PipelineMode.allCases) { Text($0.label).tag($0) }
        } label: {
            explained("Pipeline", "Maximum quality is the proven default.")
        }
        Picker(selection: $model.processing.demosaic) {
            ForEach(DemosaicMethod.allCases) { Text($0.label).tag($0) }
        } label: {
            explained("Debayer", "How color is rebuilt from the sensor.")
        }
        VStack(alignment: .leading) {
            explained(
                String(format: "Exposure offset %+.1f", model.processing.exposureStops),
                "Baked into the file, in stops.")
            Slider(value: $model.processing.exposureStops, in: -3...3, step: 0.1)
                .accessibilityLabel("Exposure offset")
        }
        Toggle(isOn: $model.processing.reduceLoadWhenHot) {
            explained("Reduce load when hot", "Uses a cheaper debayer to keep recording. A popup shows when it starts.")
        }
    }

    @ViewBuilder
    private var monitor: some View {
        Picker(selection: $model.processing.monitor) {
            ForEach(MonitorMode.allCases) { Text($0.label).tag($0) }
        } label: {
            explained("Monitor", "The ISP preview turns off the monitoring tools.")
        }
        Picker(selection: $model.selectedLUT) {
            Text("Rec.709").tag("")
            ForEach(model.lutNames, id: \.self) { Text($0).tag($0) }
        } label: {
            explained("Monitor LUT", "Changes the viewfinder only, not the file.")
        }
        Button("Import .cube LUT") { importingLUT = true }
        if !model.selectedLUT.isEmpty {
            Picker(selection: $model.processing.lutExpectsRec709) {
                Text("Log").tag(false)
                Text("Rec.709").tag(true)
            } label: {
                explained("LUT input", "The signal this LUT was made for.")
            }
        }
        Toggle(isOn: $model.processing.pauseMonitorWhileRecording) {
            explained("Monitor off while recording", "Saves GPU time, but the picture stops.")
        }
    }

    @ViewBuilder
    private var camera: some View {
        Toggle(isOn: $model.lockAtRoll) {
            explained("Lock exposure at roll", "Freezes exposure and white balance when a take starts. Focus always locks.")
        }
        Picker(selection: $model.mainsHz) {
            Text("50 Hz").tag(50)
            Text("60 Hz").tag(60)
        } label: {
            explained("Mains", "Sets the shutter stops that avoid light flicker.")
        }
    }

    @ViewBuilder
    private var about: some View {
        LabeledContent("Version", value: Self.version)
            .contentShape(Rectangle())
            .onLongPressGesture { showDiagnostics = true }
            .accessibilityAction(named: "Open diagnostics") { showDiagnostics = true }
            .navigationDestination(isPresented: $showDiagnostics) {
                DiagnosticsView { dismiss() }
            }
        Text("All choices save to VibeLog.config.json in the VibeLog folder. Edit it in the Files app, then reopen VibeLog.")
            .font(.footnote)
            .foregroundStyle(.secondary)
    }
}
