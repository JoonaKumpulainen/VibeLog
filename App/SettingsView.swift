import SwiftUI
import UniformTypeIdentifiers
import VLCore
import VLProcessing
import VLRecording

/// One page, ordered by how often a setting changes, with search for the rest. What gets recorded
/// lives in the format panel, so it has one home.
struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var importingLUT = false
    @State private var showDiagnostics = false
    @State private var search = ""
    @State private var showsProcessing = false
    @State private var namingPreset = false
    @State private var presetName = ""
    let openFormat: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                if matches(Self.formatTerms) {
                    formatSection
                }
                if matches(Self.presetTerms) {
                    presetSection
                }
                if matches(Self.recordingTerms) {
                    recordingSection
                }
                if matches(Self.viewfinderTerms) {
                    viewfinderSection
                }
                if matches(Self.imageTerms) {
                    imageSection
                }
                if matches("about version saved config file diagnostics") {
                    aboutSection
                }
            }
            .overlay {
                if !search.isEmpty, !hasResults {
                    ContentUnavailableView.search(text: search)
                }
            }
            .searchable(text: $search, prompt: "Search settings")
            .navigationDestination(isPresented: $showDiagnostics) {
                DiagnosticsView { dismiss() }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
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

    private static let formatTerms = "format codec size resolution frame rate fps log curve aspect open gate chroma"
    private static let presetTerms = "preset save saved recall format default stock delete startup"
    private static let stopTerms = "stop after limit duration time timer"
    private static let autoTerms = "auto exposure shutter iso white balance during take recording freeze lock start roll"
    private static let heatTerms = "hot heat thermal cool long takes debayer"
    private static let audioTerms = "audio pcm aac sound uncompressed microphone"
    private static let gyroTerms = "gyro gyroflow stabilization motion gcsv log"
    private static let mainsTerms = "flicker mains lights hz power frequency shutter"
    private static let recordingTerms = [stopTerms, autoTerms, audioTerms, gyroTerms, heatTerms, mainsTerms].joined(separator: " ")
    private static let lookTerms = "look monitor rec.709 log preview isp viewfinder"
    private static let lutTerms = "lut cube import look monitor input"
    private static let pauseTerms = "pause viewfinder monitor off gpu recording"
    private static let peakingTerms = "focus peaking sensitivity low high detail"
    private static let guideTerms = "frame guide aspect scope 2.39 1.85 framing"
    private static let desqueezeTerms = "anamorphic desqueeze squeeze lens"
    private static let viewfinderTerms = [lookTerms, lutTerms, pauseTerms, peakingTerms, guideTerms, desqueezeTerms].joined(separator: " ")
    private static let offsetTerms = "exposure offset stops brightness baked"
    private static let gamutTerms = "color colour space gamut native s-gamut3 s-log3 arri wide logc3 awg3 rec.2020"
    private static let tagTerms = "file tag color colour rec.709 rec.2020 hlg editor"
    private static let processingTerms = "pipeline debayer demosaic quality processing"
    private static let imageTerms = [offsetTerms, gamutTerms, tagTerms, processingTerms].joined(separator: " ")

    /// Every word typed has to appear, so a phrase can come in any order.
    private func matches(_ terms: String) -> Bool {
        search.split(separator: " ").allSatisfy { terms.localizedCaseInsensitiveContains($0) }
    }

    private var hasResults: Bool {
        matches(Self.formatTerms) || matches(Self.presetTerms) || matches(Self.recordingTerms)
            || matches(Self.viewfinderTerms) || matches(Self.imageTerms)
            || matches("about version saved config file diagnostics")
    }

    private static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "-"
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

    /// What gets recorded is changed beside the picture, so this only leads there.
    private var formatSection: some View {
        Section("Format") {
            Button {
                dismiss()
                openFormat()
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Change format")
                        Text("\(model.codecLabel) · \(model.curveLabel) · \(model.outputLabel) · \(model.frameRateLabel) fps")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    /// Tapping one applies it. Saved ones go with a swipe or from their menu, and Stock stays.
    private var presetSection: some View {
        Section {
            presetRow(.stock)
            ForEach(model.presets) { presetRow($0) }
                .onDelete { model.deletePresets(at: $0) }
            Button("Save current format") {
                presetName = ""
                namingPreset = true
            }
        } header: {
            Text("Presets")
        } footer: {
            Text("The default opens every time. With none set, VibeLog opens on your last choices.")
        }
        .alert("Save preset", isPresented: $namingPreset) {
            TextField("Name", text: $presetName)
            Button("Save") { model.savePreset(named: presetName) }
                .disabled(FormatPreset.isReserved(presetName))
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Keeps the codec, size, aspect, frame rate, log curve, pipeline, debayer and exposure offset. A name in use is replaced. Stock can't be.")
        }
    }

    private func presetRow(_ preset: FormatPreset) -> some View {
        let isDefault = model.defaultPreset == preset.name
        return HStack {
            Button {
                model.apply(preset)
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(preset.name)
                            .foregroundStyle(Tokens.value)
                        if isDefault {
                            Text("Default")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    if model.isCurrent(preset) {
                        Image(systemName: "checkmark")
                            .accessibilityLabel("In use")
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            Menu {
                Button(isDefault ? "Remove default" : "Set as default") {
                    model.defaultPreset = isDefault ? "" : preset.name
                }
                if !preset.isStock {
                    Button("Delete", role: .destructive) { model.delete(preset) }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("\(preset.name) options")
        }
    }

    private var recordingSection: some View {
        Section("Recording") {
            if matches(Self.stopTerms) {
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
            if matches(Self.autoTerms) {
                Toggle(isOn: autoDuringTake) {
                    explained(
                        "Auto exposure and white balance during a take",
                        "Shutter, ISO and white balance keep following the scene. Off freezes them at the start. Values you set stay, and focus always holds.")
                }
            }
            if matches(Self.audioTerms) {
                Toggle(isOn: $model.pcmAudio) {
                    explained("Uncompressed audio", "Records 24-bit PCM instead of AAC, about 0.5 GB an hour.")
                }
            }
            if matches(Self.gyroTerms) {
                Toggle(isOn: $model.saveGyroLog) {
                    explained("Save gyro data", "Saves a .gcsv file beside each take for stabilizing in Gyroflow.")
                }
            }
            if matches(Self.heatTerms) {
                Toggle(isOn: $model.processing.reduceLoadWhenHot) {
                    explained("Keep recording when hot", "Uses a cheaper debayer once the phone is hot.")
                }
            }
            if matches(Self.mainsTerms) {
                Picker(selection: $model.mainsHz) {
                    Text("50 Hz").tag(50)
                    Text("60 Hz").tag(60)
                } label: {
                    explained("Flicker-free shutter", "Match your country's power, shown as major stops on the shutter dial.")
                }
            }
        }
    }

    private var autoDuringTake: Binding<Bool> {
        Binding(get: { !model.lockAtRoll }, set: { model.lockAtRoll = !$0 })
    }

    private var viewfinderSection: some View {
        Section("Viewfinder") {
            if matches(Self.lookTerms) {
                Picker(selection: $model.processing.monitor) {
                    ForEach(MonitorMode.allCases) { Text($0.label).tag($0) }
                } label: {
                    explained("Look", "Never changes the file. The ISP preview turns off monitoring tools.")
                }
            }
            if matches(Self.lutTerms) {
                Picker(selection: $model.selectedLUT) {
                    Text("None").tag("")
                    ForEach(model.lutNames, id: \.self) { Text($0).tag($0) }
                } label: {
                    explained("LUT", "Replaces Rec.709 in the viewfinder only.")
                }
                Button("Import .cube LUT") { importingLUT = true }
                if !model.selectedLUT.isEmpty {
                    Picker(selection: $model.processing.lutExpectsRec709) {
                        Text("Log").tag(false)
                        Text("Rec.709").tag(true)
                    } label: {
                        explained("LUT made for", "The signal this LUT expects.")
                    }
                }
            }
            if matches(Self.pauseTerms) {
                Toggle(isOn: $model.processing.pauseMonitorWhileRecording) {
                    explained("Freeze viewfinder during a take", "Saves GPU time, but the picture stops.")
                }
            }
            if matches(Self.peakingTerms) {
                Picker(selection: $model.processing.peakingSensitivity) {
                    ForEach(PeakingSensitivity.allCases) { Text($0.label).tag($0) }
                } label: {
                    explained("Focus peaking sensitivity", "High also marks softer detail.")
                }
            }
            if matches(Self.guideTerms) {
                Picker(selection: $model.frameGuide) {
                    ForEach(FrameGuide.allCases) { Text($0.label).tag($0) }
                } label: {
                    explained("Frame guide", "The shape the GUIDE tool marks. It never reaches the file.")
                }
            }
            if matches(Self.desqueezeTerms) {
                Picker(selection: $model.processing.desqueeze) {
                    Text("Off").tag(1.0)
                    Text("1.33x").tag(1.33)
                    Text("1.5x").tag(1.5)
                    Text("1.8x").tag(1.8)
                    Text("2x").tag(2.0)
                } label: {
                    explained("Anamorphic desqueeze", "Viewfinder only. The file stays squeezed.")
                }
            }
        }
    }

    private var gamutDetail: String {
        guard let curve = model.processing.gamut.curve else {
            return "Every log curve can record this. Other gamuts need their own curve."
        }
        return "Sets the log curve to \(curve.label), which this gamut belongs to."
    }

    private var imageSection: some View {
        Section("Image") {
            if matches(Self.offsetTerms) {
                VStack(alignment: .leading) {
                    explained(
                        String(format: "Exposure offset %+.1f", model.processing.exposureStops),
                        "Baked into the file, in stops.")
                    Slider(value: $model.processing.exposureStops, in: -3...3, step: 0.1)
                        .accessibilityLabel("Exposure offset")
                        .accessibilityValue(String(format: "%+.1f stops", model.processing.exposureStops))
                }
            }
            if matches(Self.gamutTerms) {
                Picker(selection: $model.processing.gamut) {
                    ForEach(Gamut.allCases) { Text($0.pairedLabel).tag($0) }
                } label: {
                    explained("Color space", gamutDetail)
                }
            }
            if matches(Self.tagTerms) {
                Picker(selection: $model.fileTag) {
                    ForEach(FileTag.allCases) { Text($0.label).tag($0) }
                } label: {
                    explained("File tag", "What the file tells an editor. The picture doesn't change.")
                }
            }
            if matches(Self.processingTerms) {
                // A search opens this by showing its rows directly.
                if search.isEmpty {
                    DisclosureGroup("Processing", isExpanded: $showsProcessing) {
                        processingRows
                    }
                } else {
                    processingRows
                }
            }
        }
    }

    @ViewBuilder
    private var processingRows: some View {
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
    }

    private var aboutSection: some View {
        Section {
            LabeledContent("Version", value: Self.version)
                .contentShape(Rectangle())
                .onLongPressGesture { showDiagnostics = true }
                .accessibilityAction(named: "Open diagnostics") { showDiagnostics = true }
        } header: {
            Text("About")
        } footer: {
            Text("Choices save to VibeLog.config.json in the VibeLog folder. Edit it in the Files app, then reopen VibeLog.")
        }
    }
}
