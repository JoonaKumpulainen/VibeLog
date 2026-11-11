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
    let openLook: () -> Void

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
                if matches(Self.twelveBitTerms), !search.isEmpty, model.encoderSupport.supportsTwelveBit {
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

    // Each group's words include its rows' explanations, so a search finds a setting by what it does.
    private static let autoDetail = "Shutter, ISO and white balance keep following the scene. Off freezes them at the start. Values you set stay, and focus always holds."
    private static let stereoDetail = "Records left and right from the built-in microphones. Off records mono."
    private static let pcmDetail = "Records 24-bit PCM instead of AAC, about 0.5 GB an hour in mono and 1 GB in stereo."
    private static let gyroDetail = "Saves a .gcsv file beside each take for stabilizing in Gyroflow."
    private static let slowDetail = "Draws fewer frames once the phone is hot, leaving more for the take."
    private static let mainsDetail = "Match your country's power, shown as major stops on the shutter dial."
    private static let ispDetail = "Shows Apple's own processed picture instead of VibeLog's. Looks, monitoring tools and scopes don't show on it."
    private static let lookDetail = "Opens the LOOK panel: Monitor, VibeLog's Rec.709 view for judging exposure, the ACES looks and imported LUTs, with their grade and effects."
    private static let freezeDetail = "Saves GPU time, but the picture stops."
    private static let idleDetail = "Stops the camera with no touch, to save heat. A tap wakes it."
    private static let peakingDetail = "High also marks softer detail."
    private static let guideDetail = "The shape the GUIDE tool marks. It never reaches the file."
    private static let desqueezeDetail = "Viewfinder only. The file stays squeezed."
    private static let hdrViewfinderDetail = "While ACES 2.0's dynamic range is HDR PQ or HLG, the viewfinder shows the HDR picture at up to 1000 nits, using the screen's extra brightness, baked or not. Zebras, false color and peaking stay at SDR white. Off shows the SDR look."
    private static let hapticsDetail = "Ticks for dials, sliders, carousels and taps across the app. Off silences every one."
    private static let scopeDetail = "RGB and YRGB draw their channels in one waveform, mixing toward white where they agree. Off sets them side by side."
    private static let offsetDetail = "Baked into the file, in stops."
    private static let bakeDetail = "Records the look into takes instead of log: Monitor's Rec.709 view, an ACES look or a LUT, with its grade, tagged Rec.709 or HDR. It can't be graded back. Switches to HEVC 4:2:0 for small files, or ProRes, and the look is fixed as a take starts. BAKE in the LOOK panel does the same. FX are baked only with FX in baked takes on."
    private static let proResDetail = "Baked takes record ProRes 422 HQ instead of HEVC 4:2:0: about 160 MB/s instead of 25 to 30, with 4:2:2 color and no compression smear, for finishing in an editor."
    private static let rangeDetail = "HDR records ACES 2.0 at 1000 nits in Rec.2020, as PQ for HDR10 with its mastering metadata, or as HLG. Other looks bake SDR. The viewfinder still shows SDR. Also from ACES 2.0 in the LOOK panel."
    private static let pairDetail = "Choosing a log curve also chooses its color space, and the other way round. Off, either changes alone."
    private static let tagDetail = "What the file tells an editor. The picture doesn't change."
    private static let pipelineDetail = "How frames reach the encoder. Maximum quality is the reference."
    private static let efficientDetail = "Frames go straight to the encoder instead of through a full RGB image, and the viewfinder gets its own half-size picture. The file matches to within rounding."
    private static let debayerDetail = "How color is rebuilt from the sensor. Malvar-He-Cutler keeps more detail and grain. Bilinear is softer and cleaner."
    private static let bilinearDetail = "Saves GPU time, but the picture turns softer partway through a take."
    private static let twelveBitDetail = "Keeps 12 bits of color instead of 10, for heavy grading. About the same file size, but more memory, and a 10-minute take is untested."
    private static let distortionDetail = "Off keeps the sensor's plain frame, and lets the ultra wide reach 30 fps. On, the camera reshapes frames to correct the lens."

    private static let formatTerms = "format codec size resolution frame rate fps log curve aspect open gate chroma"
    private static let presetTerms = "preset save saved recall format default reset delete startup"
    private static let stopTerms = "stop after limit duration time timer"
    private static let autoTerms = "auto exposure shutter iso white balance during take recording freeze lock start roll " + autoDetail
    private static let heatTerms = "hot heat thermal cool long takes viewfinder slow " + slowDetail
    private static let audioTerms = "audio pcm aac sound uncompressed microphone stereo mono channels " + stereoDetail + pcmDetail
    private static let gyroTerms = "gyro gyroflow stabilization motion gcsv log " + gyroDetail
    private static let mainsTerms = "flicker mains lights hz power frequency shutter " + mainsDetail
    private static let recordingTerms = [stopTerms, autoTerms, audioTerms, gyroTerms, heatTerms, mainsTerms].joined(separator: " ")
    private static let lookTerms = "look monitor rec.709 log preview isp apple viewfinder " + ispDetail
    private static let lutTerms = "lut cube import look looks aces style styles grade adjust color fx effects monitor input " + lookDetail
    private static let pauseTerms = "pause viewfinder monitor off gpu recording idle heat sleep freeze " + freezeDetail + idleDetail
    private static let peakingTerms = "focus peaking sensitivity low high detail " + peakingDetail
    private static let guideTerms = "frame guide aspect 2.39 1.85 framing " + guideDetail
    private static let desqueezeTerms = "anamorphic desqueeze squeeze lens " + desqueezeDetail
    private static let scopeTerms = "scope scopes waveform parade rgb yrgb overlay blend vectorscope histogram " + scopeDetail
    private static let hapticTerms = "haptics haptic vibration vibrate taptic feedback ticks " + hapticsDetail
    private static let hdrViewfinderTerms = "hdr viewfinder edr extended dynamic range pq hlg brightness nits " + hdrViewfinderDetail
    private static let viewfinderTerms = [lookTerms, lutTerms, pauseTerms, peakingTerms, guideTerms, desqueezeTerms, scopeTerms, hapticTerms, hdrViewfinderTerms].joined(separator: " ")
    private static let offsetTerms = "exposure offset stops brightness baked " + offsetDetail
    private static let bakeTerms = "bake baked look lut rec.709 file record prores hevc hdr pq hlg hdr10 dynamic range " + bakeDetail + proResDetail + rangeDetail
    private static let gamutTerms = "color colour space gamut native pair sync s-gamut3 s-gamut3.cine cine s-gamut s-log3 s-log2 arri wide logc3 logc4 awg3 awg4 canon cinema rec.2020 " + pairDetail
    private static let tagTerms = "file tag color colour rec.709 rec.2020 hlg editor " + tagDetail
    private static let processingTerms = "pipeline debayer demosaic quality processing efficient bilinear malvar hot advanced " + pipelineDetail + efficientDetail + debayerDetail + bilinearDetail
    private static let distortionTerms = "lens distortion correction ultra wide advanced vignette shading corners " + distortionDetail + vignetteDetail
    private static let fineLUTDetail = "Builds the look at 129 points a side instead of 65, about a quarter of the colour error in saturated colours, for the viewfinder and baked takes. Its cost during a take isn't measured yet. Exports always use 129."
    private static let vignetteDetail = "Brightens the corners by Apple's own lens shading for the lens, up to about two stops on the 1x, as Apple's photos and DNG editors do. Corners get noisier with it. Off keeps the sensor's plain fall-off."
    private static let twelveBitTerms = "12-bit 12 bit prores 4444 depth color advanced " + twelveBitDetail
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

    /// A switch whose explanation slides out only while it's on, so the page stays short. A search
    /// shows every explanation, since it may be what matched.
    private func switchRow(
        _ title: String, _ detail: String, isOn: Binding<Bool>
    ) -> some View {
        let shows = isOn.wrappedValue || !search.isEmpty
        return Toggle(isOn: isOn.animation(.easeInOut(duration: 0.25))) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if shows {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
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
                switchRow("Auto exposure and white balance during a take", Self.autoDetail, isOn: autoDuringTake)
            }
            if matches(Self.audioTerms) {
                switchRow("Stereo audio", Self.stereoDetail, isOn: $model.stereoAudio)
                    .disabled(model.isRecording)
                switchRow("Uncompressed audio", Self.pcmDetail, isOn: $model.pcmAudio)
            }
            if matches(Self.gyroTerms) {
                switchRow("Save gyro data", Self.gyroDetail, isOn: $model.saveGyroLog)
            }
            if matches(Self.heatTerms) {
                switchRow("Slow viewfinder when hot", Self.slowDetail, isOn: $model.processing.reduceLoadWhenHot)
            }
            if matches(Self.mainsTerms) {
                Picker(selection: $model.mainsHz) {
                    Text("50 Hz").tag(50)
                    Text("60 Hz").tag(60)
                } label: {
                    explained("Flicker-free shutter", Self.mainsDetail)
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
                switchRow("ISP preview", ispPreviewDetail, isOn: ispPreview)
                    // It holds for a take, as the look does.
                    .disabled(model.isRecording)
            }
            if matches(Self.lutTerms) {
                Button {
                    dismiss()
                    openLook()
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Look")
                                .foregroundStyle(Tokens.value)
                            Text(lookSummary)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .disabled(model.isRecording && model.processing.monitor == .isp)
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
            if matches(Self.scopeTerms) {
                switchRow("Overlay scope channels", Self.scopeDetail, isOn: $model.scopeOverlaid)
            }
            if matches(Self.hapticTerms) {
                switchRow("Haptics", Self.hapticsDetail, isOn: $model.hapticsOn)
            }
            if matches(Self.hdrViewfinderTerms) {
                switchRow("HDR viewfinder", Self.hdrViewfinderDetail, isOn: $model.hdrViewfinder)
            }
            if matches(Self.pauseTerms) {
                switchRow("Freeze viewfinder during a take", Self.freezeDetail, isOn: $model.processing.pauseMonitorWhileRecording)
                Picker(selection: $model.idlePauseMinutes) {
                    Text("Never").tag(0.0)
                    Text("1 minute").tag(1.0)
                    Text("2 minutes").tag(2.0)
                    Text("5 minutes").tag(5.0)
                } label: {
                    explained("Pause camera when idle", Self.idleDetail)
                }
            }
            if matches(Self.peakingTerms) {
                Picker(selection: $model.processing.peakingSensitivity) {
                    ForEach(PeakingSensitivity.allCases) { Text($0.label).tag($0) }
                } label: {
                    explained("Focus peaking sensitivity", Self.peakingDetail)
                }
            }
            if matches(Self.guideTerms) {
                Picker(selection: $model.frameGuide) {
                    ForEach(FrameGuide.allCases) { Text($0.label).tag($0) }
                } label: {
                    explained("Frame guide", Self.guideDetail)
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
                    explained("Anamorphic desqueeze", Self.desqueezeDetail)
                }
            }
        }
    }

    /// On, while Apple's preview shows, what it means for looks and takes.
    private var ispPreviewDetail: String {
        guard model.processing.monitor == .isp else { return Self.ispDetail }
        return model.bakeLook
            ? "Apple's own picture shows. Baked takes still record \(lookName), which the viewfinder won't show. Choosing a look turns this off."
            : "Apple's own picture shows, without looks, tools or scopes. Takes record log as always. Choosing a look turns this off."
    }

    private var ispPreview: Binding<Bool> {
        Binding(
            get: { model.processing.monitor == .isp },
            set: { model.processing.monitor = $0 ? .isp : .rec709 })
    }

    private var lookName: String {
        model.selectedLUT.isEmpty ? "Monitor (Rec.709)" : model.selectedLUT
    }

    /// The look, how it's graded and whether it's baked, on one line.
    private var lookSummary: String {
        var parts = [lookName]
        if model.selectedLUT == BuiltInLook.aces20.name, model.bakeLook { parts.append(model.bakeTarget.shortLabel) }
        if let style = model.currentStyle { parts.append(style.name) } else if !model.lookGrade.isNeutral { parts.append("graded") }
        if !model.lookEffects.isNeutral { parts.append("FX") }
        if model.bakeLook { parts.append("baked") }
        return parts.joined(separator: " · ")
    }

    private var gamutDetail: String {
        if model.bakeLook { return "Not used while Bake is on: baked takes are recorded in Rec.709 or, for HDR, Rec.2020." }
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
                        Self.offsetDetail)
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
                    Picker(selection: $model.bakeTarget) {
                        ForEach(BakeTarget.allCases) { Text($0.label).tag($0) }
                    } label: {
                        explained("Bake as", Self.rangeDetail)
                    }
                    .disabled(model.isRecording)
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
                switchRow("Pair curve and color space", Self.pairDetail, isOn: $model.processing.pairsGamut)
            }
            if matches(Self.tagTerms) {
                Picker(selection: $model.fileTag) {
                    // PQ only describes an HDR bake, never log.
                    ForEach(FileTag.allCases.filter { $0 != .pq }) { Text($0.label).tag($0) }
                } label: {
                    explained("File tag", Self.tagDetail)
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
            Section("Processing") {
                processingRows
                switchRow("Fine look LUT", Self.fineLUTDetail, isOn: $model.fineLookLUT)
            }
            Section("Capture") { distortionRow }
            // 12-bit needs ProRes 4444, which only the Pro phones from the 13 Pro on have.
            if model.encoderSupport.supportsTwelveBit {
                Section("Recording") { twelveBitRow }
            }
            Section {
                NavigationLink("Color spaces and LUTs") { PairingView() }
            } footer: {
                Text("Which color space each log curve records, and a viewfinder LUT for each. Kept in presets.")
            }
            Section {
                NavigationLink("Lenses") {
                    LensesView { dismiss() }
                }
            } footer: {
                Text("This phone's lens profiles, from Apple's calibration. Kept on the phone, out of presets.")
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
            explained("Pipeline", Self.pipelineDetail)
        }
        switchRow("Efficient when hot", Self.efficientDetail, isOn: $model.processing.efficientWhenHot)
        Picker(selection: $model.processing.demosaic) {
            ForEach(DemosaicMethod.allCases) { Text($0.label).tag($0) }
        } label: {
            explained("Debayer", Self.debayerDetail)
        }
        switchRow("Bilinear when hot", Self.bilinearDetail, isOn: $model.processing.bilinearWhenHot)
    }

    private var bakeRow: some View {
        // Animated, so the rows under it slide out.
        switchRow("Bake", Self.bakeDetail, isOn: $model.bakeLook)
            .disabled(model.isRecording)
    }

    @ViewBuilder private var bakeToProResRow: some View {
        if model.encoderSupport.hasProRes {
            switchRow("Bake to ProRes", Self.proResDetail, isOn: $model.bakeToProRes)
                .disabled(model.isRecording)
        }
        switchRow("FX in baked takes", Self.bakeEffectsDetail, isOn: $model.processing.bakeEffects)
            .disabled(model.isRecording)
    }

    private static let bakeEffectsDetail = "Records the FX tab's halation, bloom, diffusion, vignette and grain into baked takes, as the viewfinder shows them, fixed as a take starts. Each frame then makes its own glow, which the viewfinder shares during the take rather than making a second one. These takes use the Efficient pipeline throughout, since Maximum quality fell behind after about two minutes. Log takes never get FX. Grain suits ProRes better than HEVC, which smears it."

    private var twelveBitRow: some View {
        switchRow("12-bit ProRes 4444", Self.twelveBitDetail, isOn: $model.twelveBitProRes)
            .disabled(model.isRecording)
    }

    @ViewBuilder private var distortionRow: some View {
        switchRow("Lens distortion correction", Self.distortionDetail, isOn: $model.distortionCorrection)
        switchRow("Lens shading correction", Self.vignetteDetail, isOn: $model.processing.vignetteCorrection)
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
