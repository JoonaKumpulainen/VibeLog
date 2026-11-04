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
    @State private var search = ""
    @State private var namingPreset = false
    @State private var presetName = ""
    @State private var confirmingReset = false
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
                if search.isEmpty {
                    advancedSection
                } else if matches(Self.processingTerms) {
                    Section("Advanced") { processingRows }
                }
                if matches(Self.distortionTerms), !search.isEmpty {
                    Section("Advanced") { distortionRow }
                }
                if matches(Self.twelveBitTerms), !search.isEmpty {
                    Section("Advanced") { twelveBitRow }
                }
                if matches("about version saved config file legal license licenses trademark") {
                    aboutSection
                }
            }
            .overlay {
                if !search.isEmpty, !hasResults {
                    ContentUnavailableView.search(text: search)
                }
            }
            .searchable(text: $search, prompt: "Search settings")
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
    private static let presetTerms = "preset save saved recall format default reset delete startup"
    private static let stopTerms = "stop after limit duration time timer"
    private static let autoTerms = "auto exposure shutter iso white balance during take recording freeze lock start roll"
    private static let heatTerms = "hot heat thermal cool long takes viewfinder slow"
    private static let audioTerms = "audio pcm aac sound uncompressed microphone stereo mono channels"
    private static let gyroTerms = "gyro gyroflow stabilization motion gcsv log"
    private static let mainsTerms = "flicker mains lights hz power frequency shutter"
    private static let recordingTerms = [stopTerms, autoTerms, audioTerms, gyroTerms, heatTerms, mainsTerms].joined(separator: " ")
    private static let lookTerms = "look monitor rec.709 log preview isp viewfinder"
    private static let lutTerms = "lut cube import look monitor input"
    private static let bakeTerms = "bake baked look lut rec.709 file record prores hevc"
    private static let pauseTerms = "pause viewfinder monitor off gpu recording idle heat sleep"
    private static let peakingTerms = "focus peaking sensitivity low high detail"
    private static let guideTerms = "frame guide aspect scope 2.39 1.85 framing"
    private static let desqueezeTerms = "anamorphic desqueeze squeeze lens"
    private static let viewfinderTerms = [lookTerms, lutTerms, pauseTerms, peakingTerms, guideTerms, desqueezeTerms].joined(separator: " ")
    private static let offsetTerms = "exposure offset stops brightness baked"
    private static let gamutTerms = "color colour space gamut native pair sync s-gamut3 s-gamut3.cine cine s-gamut s-log3 s-log2 arri wide logc3 logc4 awg3 awg4 canon cinema rec.2020"
    private static let tagTerms = "file tag color colour rec.709 rec.2020 hlg editor"
    private static let processingTerms = "pipeline debayer demosaic quality processing efficient bilinear malvar hot advanced"
    private static let distortionTerms = "lens distortion correction ultra wide advanced"
    private static let twelveBitTerms = "12-bit 12 bit prores 4444 depth color advanced"
    private static let imageTerms = [offsetTerms, bakeTerms, gamutTerms, tagTerms].joined(separator: " ")

    /// Every word typed has to appear, so a phrase can come in any order.
    private func matches(_ terms: String) -> Bool {
        search.split(separator: " ").allSatisfy { terms.localizedCaseInsensitiveContains($0) }
    }

    private var hasResults: Bool {
        matches(Self.formatTerms) || matches(Self.presetTerms) || matches(Self.recordingTerms)
            || matches(Self.viewfinderTerms) || matches(Self.imageTerms) || matches(Self.processingTerms)
            || matches(Self.distortionTerms) || matches(Self.twelveBitTerms) || matches("about version saved config file legal license licenses trademark")
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

    /// Tapping one applies it. Saved ones go with a swipe or from their menu.
    private var presetSection: some View {
        Section {
            ForEach(model.presets) { presetRow($0) }
                .onDelete { model.deletePresets(at: $0) }
            Button("Save current settings") {
                presetName = ""
                namingPreset = true
            }
            Button("Reset all settings", role: .destructive) { confirmingReset = true }
                .disabled(model.isRecording)
        } header: {
            Text("Presets")
        } footer: {
            Text("The default opens every time. With none set, VibeLog opens on your last choices.")
        }
        .alert("Save preset", isPresented: $namingPreset) {
            TextField("Name", text: $presetName)
            Button("Save") { model.savePreset(named: presetName) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Keeps every setting except the test link. A name in use is replaced.")
        }
        .alert("Reset all settings?", isPresented: $confirmingReset) {
            Button("Reset", role: .destructive) { model.resetSettings() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Returns every setting and manual control to the app's own. Presets, takes and the test link stay.")
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
                Button("Update to current settings") { model.update(preset) }
                    .disabled(model.isCurrent(preset))
                Button(isDefault ? "Remove default" : "Set as default") {
                    model.defaultPreset = isDefault ? "" : preset.name
                }
                Button("Delete", role: .destructive) { model.delete(preset) }
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
                Toggle(isOn: $model.stereoAudio) {
                    explained("Stereo audio", "Records left and right from the built-in microphones. Off records mono.")
                }
                .disabled(model.isRecording)
                Toggle(isOn: $model.pcmAudio) {
                    explained("Uncompressed audio", "Records 24-bit PCM instead of AAC, about 0.5 GB an hour in mono and 1 GB in stereo.")
                }
            }
            if matches(Self.gyroTerms) {
                Toggle(isOn: $model.saveGyroLog) {
                    explained("Save gyro data", "Saves a .gcsv file beside each take for stabilizing in Gyroflow.")
                }
            }
            if matches(Self.heatTerms) {
                Toggle(isOn: $model.processing.reduceLoadWhenHot) {
                    explained("Slow viewfinder when hot", "Draws fewer frames once the phone is hot, leaving more for the take.")
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
                    ForEach(model.lookNames, id: \.self) { Text($0).tag($0) }
                } label: {
                    explained("LUT", "Replaces Rec.709 in the viewfinder, and in the file when the look is baked.")
                }
                Button("Import .cube LUT") { importingLUT = true }
                // Built-in looks always work on log.
                if !model.selectedLUT.isEmpty, BuiltInLook.named(model.selectedLUT) == nil {
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
                Picker(selection: $model.idlePauseMinutes) {
                    Text("Never").tag(0.0)
                    Text("1 minute").tag(1.0)
                    Text("2 minutes").tag(2.0)
                    Text("5 minutes").tag(5.0)
                } label: {
                    explained("Pause camera when idle", "Stops the camera with no touch, to save heat. A tap wakes it.")
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
        if model.bakeLook { return "Not used while Bake is on: baked takes are recorded in Rec.709." }
        let processing = model.processing
        guard processing.pairsGamut else {
            return "Changes the color space alone. Apple Wide Gamut is only for Apple Log 2."
        }
        return "Also sets the log curve, to \(processing.pairing.curve(for: processing.gamut).label) for this one. Pairs are set under Advanced."
    }

    private func gamutLabel(_ gamut: Gamut) -> String {
        guard model.processing.pairsGamut else { return gamut.label }
        return "\(gamut.label) · \(model.processing.pairing.curve(for: gamut).label)"
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
            if matches(Self.bakeTerms) {
                bakeRow
                if model.bakeLook {
                    bakeToProResRow
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            if matches(Self.gamutTerms) {
                Picker(selection: $model.processing.gamut) {
                    ForEach(Gamut.allCases) { Text(gamutLabel($0)).tag($0) }
                } label: {
                    explained("Color space", gamutDetail)
                }
                // A baked take is display Rec.709, so the recorded gamut has no say in the file.
                .disabled(model.bakeLook)
                Toggle(isOn: $model.processing.pairsGamut) {
                    explained(
                        "Pair curve and color space",
                        "Choosing a log curve also chooses its color space, and the other way round. Off, either changes alone.")
                }
            }
            if matches(Self.tagTerms) {
                Picker(selection: $model.fileTag) {
                    ForEach(FileTag.allCases) { Text($0.label).tag($0) }
                } label: {
                    explained("File tag", "What the file tells an editor. The picture doesn't change.")
                }
            }
        }
    }

    /// Rarely changed, so it's a page of its own. A search shows these rows on the main page.
    private var advancedSection: some View {
        Section {
            NavigationLink("Advanced") { advancedPage }
        }
    }

    private var advancedPage: some View {
        Form {
            Section("Processing") { processingRows }
            Section("Capture") { distortionRow }
            Section("Recording") { twelveBitRow }
            Section {
                NavigationLink("Color spaces and LUTs") { PairingView() }
            } footer: {
                Text("Which color space each log curve records, and a viewfinder LUT for each. Kept in presets.")
            }
            Section {
                NavigationLink("Diagnostics") {
                    DiagnosticsView { dismiss() }
                }
            } footer: {
                Text("Tests, logs and the test link.")
            }
        }
        .navigationTitle("Advanced")
        .navigationBarTitleDisplayMode(.inline)
    }

    /// Each choice sits with what can replace it while the phone is hot.
    @ViewBuilder
    private var processingRows: some View {
        Picker(selection: $model.processing.pipeline) {
            ForEach(PipelineMode.allCases) { Text($0.label).tag($0) }
        } label: {
            explained("Pipeline", "How frames reach the encoder. Maximum quality is the reference.")
        }
        Toggle(isOn: $model.processing.efficientWhenHot) {
            explained(
                "Efficient when hot",
                "Frames go straight to the encoder instead of through a full RGB image, and the viewfinder gets its own half-size picture. The file matches to within rounding.")
        }
        Picker(selection: $model.processing.demosaic) {
            ForEach(DemosaicMethod.allCases) { Text($0.label).tag($0) }
        } label: {
            explained("Debayer", "How color is rebuilt from the sensor. Malvar-He-Cutler keeps more detail and grain. Bilinear is softer and cleaner.")
        }
        Toggle(isOn: $model.processing.bilinearWhenHot) {
            explained("Bilinear when hot", "Saves GPU time, but the picture turns softer partway through a take.")
        }
    }

    private var bakeRow: some View {
        // Animated, so the ProRes row slides out from under it.
        Toggle(isOn: $model.bakeLook.animation(.easeInOut(duration: 0.25))) {
            explained(
                "Bake",
                "Records the viewfinder's look, Rec.709 or its LUT, into takes instead of log, tagged Rec.709. It can't be graded back. Switches to HEVC 4:2:0 for small files, or ProRes, and the look is fixed as a take starts. Also in the LOOK panel under MON.")
        }
        .disabled(model.isRecording)
    }

    private var bakeToProResRow: some View {
        Toggle(isOn: $model.bakeToProRes) {
            explained(
                "Bake to ProRes",
                "Baked takes record ProRes 422 HQ instead of HEVC 4:2:0: about 160 MB/s instead of 25 to 30, with 4:2:2 color and no compression smear, for finishing in an editor.")
        }
        .disabled(model.isRecording)
    }

    private var twelveBitRow: some View {
        Toggle(isOn: $model.twelveBitProRes) {
            explained(
                "12-bit ProRes 4444",
                "Keeps 12 bits of color instead of 10, for heavy grading. About the same file size, but more memory, and a 10-minute take is untested.")
        }
        .disabled(model.isRecording)
    }

    private var distortionRow: some View {
        Toggle(isOn: $model.distortionCorrection) {
            explained(
                "Lens distortion correction",
                "Off keeps the sensor's plain frame, and lets the ultra wide reach 30 fps. On, the camera reshapes frames to correct the lens.")
        }
    }

    private var aboutSection: some View {
        Section {
            LabeledContent("Version", value: Self.version)
            NavigationLink("Legal") { LegalView() }
        } header: {
            Text("About")
        } footer: {
            Text("Choices save to VibeLog.config.json in the VibeLog folder. Edit it in the Files app, then reopen VibeLog.")
        }
    }
}
