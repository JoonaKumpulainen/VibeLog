import AVFoundation
import AVKit
import SwiftUI
import VLCore
import VLProcessing
import VLRecording

/// Bakes a look into a copy of a take: Monitor's Rec.709 view, an ACES look or a LUT, with its
/// grade and effects, played through first. The copy is tagged Rec.709, or PQ or HLG for HDR,
/// and saved beside the take with its audio; the take itself is left as it is.
struct ExportView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let take: Take
    @StateObject private var job = LookExportJob()
    @State private var lutName = ""
    @State private var lutMadeForRec709 = false
    @State private var codec = "hevc420"
    @State private var player = AVPlayer()
    @State private var previewReady = false
    @State private var previewFailure: String?
    /// Only the newest look reaches the player, however the builds finish.
    @State private var previewGeneration = 0
    /// The export's own grade, starting neutral, so a take isn't graded until the owner grades it,
    /// and changing it here leaves the camera's alone.
    @State private var grade = LookGrade()
    @State private var effects = LookEffects()
    @State private var target = BakeTarget.sdr
    @State private var editingGrade = false
    @State private var beforeEditing: (lut: String, grade: LookGrade, effects: LookEffects)?

    private static let codecs = ["hevc420", "prores422hq"]

    private var curve: LogCurve { ExportChoice.curve(of: take) }

    private var gamut: Gamut { ExportChoice.gamut(of: take) }

    private var isLog: Bool { ExportChoice.isLog(take) }

    var body: some View {
        NavigationStack {
            // The preview holds still and only the settings scroll. Sideways, it sits on the
            // side of the phone's top, with the settings beside it.
            GeometryReader { geometry in
                let sideways = geometry.size.width > geometry.size.height
                let layout = sideways ? AnyLayout(HStackLayout(spacing: 0)) : AnyLayout(VStackLayout(spacing: 0))
                layout {
                    if !sideways || previewLeads { preview(sideways) }
                    Form {
                        if editingGrade {
                            ExportGradeEditor(
                                lutName: $lutName, lutMadeForRec709: $lutMadeForRec709, grade: $grade, effects: $effects)
                        } else {
                            settingsSections
                        }
                    }
                    // Grouped in every orientation, on the same ground as the preview.
                    .formStyle(.grouped)
                    .scrollContentBackground(.hidden)
                    if sideways, !previewLeads { preview(sideways) }
                }
                .background(Self.ground)
                .onChange(of: geometry.size) { _, _ in readOrientation() }
                .onAppear { readOrientation() }
            }
            .navigationTitle(editingGrade ? "Grade" : "Export with look")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if editingGrade {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Cancel") {
                            if let before = beforeEditing {
                                lutName = before.lut
                                grade = before.grade
                                effects = before.effects
                            }
                            editingGrade = false
                        }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done") { editingGrade = false }
                            .fontWeight(.semibold)
                    }
                } else {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done") {
                            job.cancel()
                            player.pause()
                            dismiss()
                        }
                    }
                }
            }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            // The camera's look, or ACES 2.0 when the camera shows log or Apple's preview.
            let cameraLook = model.processing.monitor == .rec709 ? model.selectedLUT : BuiltInLook.aces20.name
            lutName = model.isAvailableLook(cameraLook) || cameraLook.isEmpty ? cameraLook : BuiltInLook.aces20.name
            lutMadeForRec709 = model.processing.lutExpectsRec709
            target = model.bakeTarget
            player.replaceCurrentItem(with: AVPlayerItem(url: take.url))
            refreshPreview()
        }
        .onDisappear { player.pause() }
        .onChange(of: lutName) { _, _ in refreshPreview() }
        .onChange(of: lutMadeForRec709) { _, _ in refreshPreview() }
        .onChange(of: grade) { _, _ in refreshSoon() }
        .onChange(of: effects) { _, _ in refreshSoon() }
        .interactiveDismissDisabled(job.progress != nil || editingGrade)
        .haptic(.selection, trigger: lutName)
        .haptic(.selection, trigger: codec)
        .haptic(.selection, trigger: target)
        .haptic(.selection, trigger: editingGrade)
        .haptic(.success, trigger: job.message) { _, message in message?.hasPrefix("Saved") == true }
    }

    /// One ground behind the preview and the settings, which keep their own row colour.
    static let ground = Color(uiColor: .systemGroupedBackground)

    /// Whether the phone's top is on the screen's leading side, held sideways.
    @State private var previewLeads = true

    private func readOrientation() {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        // Landscape right has the Dynamic Island on the left.
        previewLeads = scene?.interfaceOrientation != .landscapeLeft
    }

    private func preview(_ sideways: Bool) -> some View {
        VStack(spacing: 4) {
            ZStack {
                Color.black
                VideoPlayer(player: player)
                    .opacity(previewReady ? 1 : 0)
                if !previewReady {
                    Text(previewFailure ?? "Loading preview")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .aspectRatio(4 / 3, contentMode: .fit)
            Text("\(curve.label) in \(gamut.label). Plays with the look, as the export will write it"
                + (grade.isNeutral ? "." : ", graded."))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .padding(.horizontal, 12)
        }
        .padding(.bottom, 6)
        .frame(maxWidth: sideways ? .infinity : nil, maxHeight: sideways ? .infinity : nil)
        .background(Self.ground)
    }

    /// The look, codec and export button, which the grade editor replaces while it's open.
    @ViewBuilder private var settingsSections: some View {
                Section("Look") {
                    Picker("LUT", selection: $lutName) {
                        Text("Monitor (Rec.709)").tag("")
                        ForEach(model.lookNames, id: \.self) { Text($0).tag($0) }
                    }
                    if !lutName.isEmpty, BuiltInLook.named(lutName) == nil {
                        Picker("LUT made for", selection: $lutMadeForRec709) {
                            Text("Log").tag(false)
                            Text("Rec.709").tag(true)
                        }
                    }
                    Button {
                        beforeEditing = (lutName, grade, effects)
                        editingGrade = true
                    } label: {
                        LabeledContent("Grade", value: grade.isNeutral && effects.isNeutral ? "None" : "Changed")
                    }
                    .disabled(job.progress != nil)
                    if lutName == BuiltInLook.aces20.name {
                        Picker("Output", selection: $target) {
                            ForEach(BakeTarget.allCases) { Text($0.label).tag($0) }
                        }
                    }
                    Picker("Codec", selection: $codec) {
                        Text("HEVC 4:2:0, small").tag("hevc420")
                        Text("ProRes 422 HQ").tag("prores422hq")
                    }
                }
                Section {
                    if let progress = job.progress {
                        ProgressView(value: progress) {
                            Text("Exporting \(Int(progress * 100))%")
                        }
                        Button("Cancel", role: .destructive) { job.cancel() }
                    } else {
                        Button("Export") { startExport() }
                            .disabled(!isLog)
                    }
                    if let message = job.message {
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } footer: {
                    Text(isLog
                        ? "Writes a new take beside this one, tagged Rec.709, or Rec.2020 PQ or HLG for HDR. Keep VibeLog open until it's done."
                        : "This take already has its look baked in.")
                }
    }

    /// A slider drags faster than a look builds, so the preview waits for a pause in the drag.
    private func refreshSoon() {
        previewGeneration += 1
        let generation = previewGeneration
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 150_000_000)
            if generation == previewGeneration { refreshPreview() }
        }
    }

    private var choice: ExportChoice {
        ExportChoice(
            lutName: lutName, lutMadeForRec709: lutMadeForRec709, grade: grade, effects: effects, target: target,
            codec: codec)
    }

    /// Gives the player the chosen look. The item keeps its place, and a paused one redraws.
    private func refreshPreview() {
        let (chosen, takeCurve, takeGamut) = (choice, curve, gamut)
        let sourceRec709 = ExportChoice.sourceRec709(take)
        let url = take.url
        previewGeneration += 1
        let generation = previewGeneration
        Task.detached(priority: .userInitiated) {
            do {
                let look = chosen.previewLook(curve: takeCurve, gamut: takeGamut, sourceRec709: sourceRec709)
                guard let exporter = LookExporter(look: look) else { throw LookExporter.Failure.gpu }
                let composition = try await LookPlayback.composition(for: AVURLAsset(url: url), exporter: exporter)
                await MainActor.run {
                    guard generation == previewGeneration, let item = player.currentItem else { return }
                    item.videoComposition = composition
                    if player.rate == 0 {
                        player.seek(to: player.currentTime(), toleranceBefore: .zero, toleranceAfter: .zero)
                    }
                    previewReady = true
                    previewFailure = nil
                }
            } catch {
                await MainActor.run {
                    guard generation == previewGeneration else { return }
                    previewReady = false
                    previewFailure = "\(error)"
                }
            }
        }
    }

    private func startExport() {
        job.start(take: take, choice: choice)
    }
}

/// Runs one export off the main thread and reports on it. Every export, finished or not, leaves
/// its details in the session log and a row in `logs/exports.csv`.
@MainActor
final class LookExportJob: ObservableObject {
    @Published var progress: Double?
    @Published var message: String?
    /// Counts finished exports, so the test link can tell one outcome from the next.
    @Published private(set) var runs = 0
    private let stop = StopFlag()

    /// Read from the export's own thread.
    final class StopFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var stopped = false
        var isSet: Bool {
            lock.lock()
            defer { lock.unlock() }
            return stopped
        }

        func set(_ value: Bool) {
            lock.lock()
            stopped = value
            lock.unlock()
        }
    }

    /// The step an export is on and how far it got, so a failure can say where it stopped.
    final class Trace: @unchecked Sendable {
        private let lock = NSLock()
        private var current = "building the look"
        private var done = 0.0

        var step: String {
            lock.lock()
            defer { lock.unlock() }
            return current
        }

        var share: Double {
            lock.lock()
            defer { lock.unlock() }
            return done
        }

        func begin(_ step: String) {
            lock.lock()
            current = step
            lock.unlock()
        }

        func reached(_ value: Double) {
            lock.lock()
            done = value
            lock.unlock()
        }
    }

    /// A step that failed outside the look exporter, named as it is.
    struct StepFailure: Error, CustomStringConvertible {
        let description: String
    }

    func cancel() { stop.set(true) }

    func start(take: Take, choice: ExportChoice) {
        guard progress == nil else { return }
        stop.set(false)
        progress = 0
        message = nil
        let stop = stop
        Task.detached(priority: .userInitiated) { [weak self] in
            let trace = Trace()
            let began = Date()
            let curve = ExportChoice.curve(of: take)
            let gamut = ExportChoice.gamut(of: take)
            let label = choice.label
            let name = take.url.lastPathComponent
            Log.shared.info(
                "Export of \(name) started: \(curve.label) in \(gamut.label), tagged \(take.info?.metadata["fileTag"] ?? "?"), "
                    + "\(take.info.map { "\($0.width)x\($0.height) \($0.preset)" } ?? "no sidecar"), "
                    + "into \(choice.preset.label) as \(choice.fileTag.label): \(label)")
            let outcome: String
            var saved: URL?
            var failure: String?
            do {
                let look = choice.exportLook(curve: curve, gamut: gamut, sourceRec709: ExportChoice.sourceRec709(take))
                saved = try await Self.export(
                    take: take, look: look, preset: choice.preset, lookLabel: label, fileTag: choice.fileTag, stop: stop,
                    trace: trace
                ) { share in
                    trace.reached(share)
                    Task { @MainActor in self?.progress = share }
                }
                outcome = "Saved as \(saved?.lastPathComponent ?? "")"
                let megabytes = Double((try? saved?.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) / 1_000_000
                Log.shared.info(
                    "Exported \(name) as \(saved?.lastPathComponent ?? "") in "
                        + String(format: "%.1f s, %.1f MB", Date().timeIntervalSince(began), megabytes) + ": \(label)")
            } catch {
                outcome = "\(error)"
                failure = "\(error)"
                let at = String(format: "%.0f%%", trace.share * 100)
                if case LookExporter.Failure.cancelled = error {
                    Log.shared.info("Export of \(name) cancelled while \(trace.step), at \(at)")
                } else {
                    Log.shared.error(
                        "Export of \(name) failed while \(trace.step), at \(at), after "
                            + String(format: "%.1f s", Date().timeIntervalSince(began))
                            + ": \(error) [\(curve.label) in \(gamut.label), \(choice.preset.id), \(choice.fileTag.label), \(label)]"
                            + Self.details(of: error))
                }
            }
            Self.record(
                take: take, curve: curve, gamut: gamut, choice: choice, label: label, saved: saved, failure: failure,
                step: trace.step, share: trace.share, seconds: Date().timeIntervalSince(began))
            await MainActor.run {
                self?.progress = nil
                self?.message = outcome
                self?.runs += 1
            }
        }
    }

    /// What an NSError carries beyond its message, which is where AVFoundation names the cause.
    nonisolated private static func details(of error: Error) -> String {
        guard !(error is LookExporter.Failure), !(error is StepFailure) else { return "" }
        let error = error as NSError
        var text = " (\(error.domain) \(error.code)"
        if let reason = error.localizedFailureReason { text += ", \(reason)" }
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError {
            text += ", underlying \(underlying.domain) \(underlying.code) \(underlying.localizedDescription)"
        }
        return text + ")"
    }

    /// One row per export in `logs/exports.csv`, which the test link can fetch by name.
    nonisolated private static func record(
        take: Take, curve: LogCurve, gamut: Gamut, choice: ExportChoice, label: String, saved: URL?, failure: String?,
        step: String, share: Double, seconds: Double
    ) {
        let file = Storage.logs.appendingPathComponent("exports.csv")
        let header = "time,source,curve,gamut,sourceTag,codec,fileTag,look,result,step,progress,seconds,output,error\n"
        let fields = [
            Storage.timestamp(), take.url.lastPathComponent, curve.label, gamut.label,
            take.info?.metadata["fileTag"] ?? "", choice.preset.id, choice.fileTag.label, label,
            failure == nil ? "saved" : failure == "\(LookExporter.Failure.cancelled)" ? "cancelled" : "failed",
            failure == nil ? "" : step, String(format: "%.2f", share), String(format: "%.1f", seconds),
            saved?.lastPathComponent ?? "", failure ?? "",
        ]
        let row = fields.map { "\"\($0.replacingOccurrences(of: "\"", with: "\"\""))\"" }.joined(separator: ",") + "\n"
        exportsLock.lock()
        defer { exportsLock.unlock() }
        if !FileManager.default.fileExists(atPath: file.path) {
            FileManager.default.createFile(atPath: file.path, contents: Data(header.utf8))
        }
        guard let handle = try? FileHandle(forWritingTo: file) else {
            Log.shared.warn("Export: can't write \(file.lastPathComponent)")
            return
        }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data(row.utf8))
    }

    nonisolated private static let exportsLock = NSLock()

    /// Writes the video with the look to a scratch file, then joins it with the take's audio
    /// into the videos folder, with a sidecar and a copy of the gyro log.
    nonisolated private static func export(
        take: Take, look: LookExporter.Look, preset: EncoderPreset, lookLabel: String, fileTag: FileTag, stop: StopFlag,
        trace: Trace, progress: @escaping (Double) -> Void
    ) async throws -> URL {
        trace.begin("setting up the GPU")
        guard let exporter = LookExporter(look: look) else { throw LookExporter.Failure.gpu }
        trace.begin("reading the take's size and length")
        let source = try await LookExporter.describe(take.url)
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mov")
        defer { try? FileManager.default.removeItem(at: scratch) }
        let name = take.url.deletingPathExtension().lastPathComponent + "_look.mov"
        let destination = Storage.videos.appendingPathComponent(name)

        var metadata = take.info?.metadata ?? [:]
        metadata["look"] = lookLabel
        metadata["fileTag"] = fileTag.label
        metadata["exportedFrom"] = take.url.lastPathComponent
        let rate = take.info?.metadata["frameRate"].flatMap(Double.init) ?? 30
        trace.begin("starting the \(preset.id) encoder at \(source.width)x\(source.height), \(rate) fps")
        let encoder = try VideoEncoder(config: .init(
            url: scratch, preset: preset, size: EncoderSize(width: source.width, height: source.height),
            frameRate: rate, audio: false, realTime: false, metadata: metadata, fileTag: fileTag))
        trace.begin("baking frames")
        try await exporter.export(
            from: take.url, into: encoder, seconds: source.seconds, progress: progress, cancelled: { stop.isSet })
        trace.begin("finishing the encoder")
        var result = await withCheckedContinuation { continuation in
            encoder.finish { continuation.resume(returning: $0) }
        }
        if let failure = result.failure { throw StepFailure(description: "The encoder failed: \(failure)") }
        if result.framesWritten == 0 { throw StepFailure(description: "The encoder wrote no frames") }

        trace.begin("joining the take's audio")
        try? FileManager.default.removeItem(at: destination)
        try await joinAudio(video: scratch, from: take.url, into: destination)
        trace.begin("writing the sidecar")
        result.file = name
        do {
            try JSONEncoder().encode(result).write(to: TakeLibrary.sidecar(for: destination))
        } catch {
            Log.shared.warn("Export: can't write the sidecar for \(name): \(error)")
        }
        let gyro = TakeLibrary.gyroLog(for: take.url)
        if FileManager.default.fileExists(atPath: gyro.path) {
            do {
                try? FileManager.default.removeItem(at: TakeLibrary.gyroLog(for: destination))
                try FileManager.default.copyItem(at: gyro, to: TakeLibrary.gyroLog(for: destination))
            } catch {
                Log.shared.warn("Export: can't copy the gyro log for \(name): \(error)")
            }
        }
        return destination
    }

    /// The new video with the take's audio and rotation, copied without re-encoding.
    nonisolated private static func joinAudio(video: URL, from original: URL, into destination: URL) async throws {
        let baked = AVURLAsset(url: video)
        let take = AVURLAsset(url: original)
        guard let bakedVideo = try await baked.loadTracks(withMediaType: .video).first,
            let takeVideo = try await take.loadTracks(withMediaType: .video).first
        else { throw LookExporter.Failure.noVideo }
        let composition = AVMutableComposition()
        let videoRange = try await bakedVideo.load(.timeRange)
        let takeStart = try await takeVideo.load(.timeRange).start
        let videoTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
        try videoTrack?.insertTimeRange(videoRange, of: bakedVideo, at: .zero)
        videoTrack?.preferredTransform = try await takeVideo.load(.preferredTransform)
        if let takeAudio = try await take.loadTracks(withMediaType: .audio).first {
            // Audio keeps its place against the take's first frame.
            let audioRange = try await takeAudio.load(.timeRange)
            let offset = CMTimeMaximum(audioRange.start - takeStart, .zero)
            let audioTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
            try audioTrack?.insertTimeRange(audioRange, of: takeAudio, at: offset)
        }
        guard let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough) else {
            throw StepFailure(description: "Can't join the audio: no export session")
        }
        session.outputURL = destination
        session.outputFileType = .mov
        await withCheckedContinuation { continuation in
            session.exportAsynchronously { continuation.resume() }
        }
        if session.status != .completed {
            throw session.error ?? StepFailure(description: "Can't join the audio: export status \(session.status.rawValue)")
        }
    }
}

/// The export's grade at full size: the same LOOKS, ADJUST and COLOR as the camera's LOOK panel,
/// each as a list of every slider, so a grade can be built while the take plays above. Save as
/// Style keeps it under its look for the camera too.
struct ExportGradeEditor: View {
    @EnvironmentObject private var model: AppModel
    @Binding var lutName: String
    @Binding var lutMadeForRec709: Bool
    @Binding var grade: LookGrade
    @Binding var effects: LookEffects
    @State private var tab = Tab.adjust
    @State private var haptics = DetentHaptics()
    @State private var naming = false
    @State private var styleName = ""

    enum Tab: String, CaseIterable { case looks = "Looks", adjust = "Adjust", color = "Color", fx = "FX" }

    var body: some View {
        Section {
            Picker("Page", selection: $tab.animation()) {
                ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets())
            .haptic(.selection, trigger: tab)
        }
        switch tab {
        case .looks: looks
        case .adjust: adjust
        case .color: colors
        case .fx: fx
        }
        Section {
            Button("Save as Style…") {
                styleName = ""
                naming = true
            }
            .disabled(grade.isNeutral)
        } footer: {
            Text("Keeps this grade, COLOR included, under \(lutName.isEmpty ? "Monitor" : lutName) in the LOOK panel's styles.")
        }
        .alert("Save Style", isPresented: $naming) {
            TextField("Name", text: $styleName)
            Button("Save") { model.saveStyle(named: styleName, look: lutName, grade: grade) }
            Button("Cancel", role: .cancel) {}
        }
    }

    @ViewBuilder private var looks: some View {
        Section("Look") {
            lookRow("Monitor (Rec.709)", "")
            ForEach(model.lookNames, id: \.self) { lookRow($0, $0) }
            if !lutName.isEmpty, BuiltInLook.named(lutName) == nil {
                Picker("LUT made for", selection: $lutMadeForRec709) {
                    Text("Log").tag(false)
                    Text("Rec.709").tag(true)
                }
            }
        }
        let styles = model.styles(for: lutName)
        if !styles.isEmpty {
            Section("Styles") {
                ForEach(styles, id: \.name) { style in
                    Button {
                        // A second tap on the checked style takes it off, back to no grade.
                        grade = grade == style.grade ? LookGrade() : style.grade
                    } label: {
                        HStack {
                            Text(style.name).foregroundStyle(.primary)
                            Spacer()
                            if grade == style.grade { Image(systemName: "checkmark") }
                        }
                    }
                }
            }
        }
    }

    private func lookRow(_ title: String, _ name: String) -> some View {
        Button {
            lutName = name
        } label: {
            HStack {
                Text(title).foregroundStyle(.primary)
                Spacer()
                if lutName == name { Image(systemName: "checkmark") }
            }
        }
    }

    @ViewBuilder private var adjust: some View {
        Section {
            ForEach(GradeControl.allCases) { control in
                sliderRow(
                    control.name, text: control.text(grade[keyPath: control.keyPath]),
                    value: Binding(
                        get: { grade[keyPath: control.keyPath] },
                        set: { grade[keyPath: control.keyPath] = control.snapped($0) }),
                    range: control.range)
            }
            Button("Reset Adjustments", role: .destructive) {
                let bands = grade.bands
                grade = LookGrade()
                grade.bands = bands
            }
        }
    }

    @ViewBuilder private var fx: some View {
        Section {
            ForEach(FXControl.allCases) { control in
                sliderRow(
                    control.name, text: control.text(effects[keyPath: control.keyPath]),
                    value: Binding(
                        get: { effects[keyPath: control.keyPath] },
                        set: { effects[keyPath: control.keyPath] = ($0 * 100).rounded() / 100 }),
                    range: control.range)
            }
            Button("Reset Effects", role: .destructive) { effects = LookEffects() }
                .disabled(effects.isNeutral)
        } footer: {
            Text("Halation and bloom glow from highlights, diffusion softens like a mist filter, and grain follows brightness. Grain suits ProRes better than HEVC, which smears it.")
        }
    }

    @ViewBuilder private var colors: some View {
        ForEach(ColorBand.allCases) { band in
            Section {
                ForEach(BandControl.allCases) { control in
                    let value = grade.bands[band.rawValue][keyPath: control.keyPath]
                    sliderRow(
                        control.name, text: String(format: "%+.0f", value * 100),
                        value: Binding(
                            get: { grade.bands[band.rawValue][keyPath: control.keyPath] },
                            set: { grade.bands[band.rawValue][keyPath: control.keyPath] = ($0 * 100).rounded() / 100 }),
                        range: -1...1, tint: band.swatch)
                }
                if !grade.bands[band.rawValue].isNeutral {
                    Button("Reset \(band.name.capitalized)", role: .destructive) {
                        grade.bands[band.rawValue] = BandAdjust()
                    }
                }
            } header: {
                HStack(spacing: 6) {
                    Circle().fill(band.swatch).frame(width: 10, height: 10)
                    Text(band.name.capitalized)
                }
            }
        }
    }

    private func sliderRow(
        _ title: String, text: String, value: Binding<Double>, range: ClosedRange<Double>, tint: Color = Tokens.held
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text(text)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Slider(value: ticking(value, range: range), in: range) { editing in
                if editing { haptics.prepare() }
            }
            .tint(tint)
            .accessibilityLabel(title)
            .accessibilityValue(text)
        }
    }

    /// The same ticks as the LOOK panel's sliders, one per hundredth of the range's width.
    private func ticking(_ value: Binding<Double>, range: ClosedRange<Double>) -> Binding<Double> {
        let step = (range.upperBound - range.lowerBound) / 100
        return Binding(
            get: { value.wrappedValue },
            set: { new in
                let old = value.wrappedValue
                value.wrappedValue = new
                haptics.moved(
                    from: Int((old / step).rounded()), to: Int((value.wrappedValue / step).rounded()),
                    neutral: range.contains(0) ? 0 : Int((1 / step).rounded()))
            })
    }
}
