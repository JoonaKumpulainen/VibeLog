import AVFoundation
import AVKit
import SwiftUI
import VLCore
import VLProcessing
import VLRecording

/// Bakes a look into a copy of a take: the Rec.709 view, or a LUT, played through first. The copy is
/// tagged Rec.709 and saved beside the take, with its audio, and the take itself is left as it is.
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
    /// The export's own grade, starting from the LOOK panel's, so changing it here leaves the
    /// camera's alone.
    @State private var grade = LookGrade()
    @State private var editingGrade = false
    @State private var beforeEditing: (lut: String, grade: LookGrade)?

    private static let codecs = ["hevc420", "prores422hq"]

    private var curve: LogCurve {
        LogCurve.allCases.first { $0.label == take.info?.metadata["curve"] } ?? .appleLog
    }

    private var gamut: Gamut {
        Gamut.allCases.first { $0.label == take.info?.metadata["gamut"] } ?? curve.nativeGamut
    }

    /// A take recorded with a look baked in has no log left to convert.
    private var isLog: Bool {
        guard let look = take.info?.metadata["look"] else { return true }
        return look == "log, as recorded"
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
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
                    .listRowInsets(EdgeInsets())
                } footer: {
                    Text("\(curve.label) in \(gamut.label), from the take's details. Plays with the look, as the export will write it"
                        + (grade.isNeutral ? "." : ", graded: \(grade.label)."))
                }
                if editingGrade {
                    ExportGradeEditor(lutName: $lutName, lutMadeForRec709: $lutMadeForRec709, grade: $grade)
                } else {
                    settingsSections
                }
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
            lutName = model.linkedLUT(curve, gamut) ?? model.selectedLUT
            if !model.isAvailableLook(lutName) { lutName = "" }
            lutMadeForRec709 = model.processing.lutExpectsRec709
            grade = model.lookGrade
            player.replaceCurrentItem(with: AVPlayerItem(url: take.url))
            refreshPreview()
        }
        .onDisappear { player.pause() }
        .onChange(of: lutName) { _, _ in refreshPreview() }
        .onChange(of: lutMadeForRec709) { _, _ in refreshPreview() }
        .onChange(of: grade) { _, _ in refreshSoon() }
        .interactiveDismissDisabled(job.progress != nil || editingGrade)
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
                        beforeEditing = (lutName, grade)
                        editingGrade = true
                    } label: {
                        LabeledContent("Grade", value: grade.isNeutral ? "None" : "Changed")
                    }
                    .disabled(job.progress != nil)
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
                        ? "Writes a new take tagged Rec.709 beside this one. Keep VibeLog open until it's done."
                        : "This take already has its look baked in.")
                }
    }

    /// Reading a .cube or building an ACES look takes a moment, so this runs off the main thread.
    nonisolated private static func makeLook(
        name: String, curve: LogCurve, gamut: Gamut, madeForRec709: Bool, sourceRec709: Bool, grade: LookGrade
    ) -> LookExporter.Look {
        if let builtIn = BuiltInLook.named(name) {
            return LookExporter.Look(
                curve: curve, gamut: gamut, lut: builtIn.lut(curve: curve, gamut: gamut, grade: grade),
                lutExpectsRec709: false, sourceRec709: sourceRec709)
        }
        if name.isEmpty, !grade.isNeutral {
            return LookExporter.Look(
                curve: curve, gamut: gamut, lut: BuiltInLook.rec709LUT(curve: curve, gamut: gamut, grade: grade),
                lutExpectsRec709: false, sourceRec709: sourceRec709)
        }
        var lut: CubeLUT?
        if !name.isEmpty {
            let url = Storage.luts.appendingPathComponent(name)
            lut = (try? String(contentsOf: url, encoding: .utf8)).flatMap { try? CubeLUT(text: $0) }
        }
        if let cube = lut, !grade.isNeutral {
            return LookExporter.Look(
                curve: curve, gamut: gamut,
                lut: BuiltInLook.graded(cube, expectsRec709: madeForRec709, curve: curve, gamut: gamut, grade: grade),
                lutExpectsRec709: false, sourceRec709: sourceRec709)
        }
        return LookExporter.Look(
            curve: curve, gamut: gamut, lut: lut, lutExpectsRec709: madeForRec709, sourceRec709: sourceRec709)
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

    private var lookInputs: (String, LogCurve, Gamut, Bool, Bool, LookGrade) {
        (lutName, curve, gamut, lutMadeForRec709, take.info?.metadata["fileTag"] == FileTag.rec709.label, grade)
    }

    /// Gives the player the chosen look. The item keeps its place, and a paused one redraws.
    private func refreshPreview() {
        let (name, curve, gamut, madeFor, sourceRec709, grade) = lookInputs
        let url = take.url
        previewGeneration += 1
        let generation = previewGeneration
        Task.detached(priority: .userInitiated) {
            do {
                let look = Self.makeLook(
                    name: name, curve: curve, gamut: gamut, madeForRec709: madeFor, sourceRec709: sourceRec709,
                    grade: grade)
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
        let preset = EncoderPreset.all.first { $0.id == codec } ?? EncoderPreset.all[0]
        let (name, curve, gamut, madeFor, sourceRec709, grade) = lookInputs
        let graded = grade.isNeutral ? "" : ", graded (\(grade.label))"
        let lutLabel = lutName.isEmpty
            ? "Rec.709 view\(graded), baked in"
            : BuiltInLook.named(lutName) != nil ? "\(lutName) Rec.709\(graded), baked in"
            : "\(lutName)\(graded), baked in" + (lutMadeForRec709 ? " after the Rec.709 view" : " on log")
        let take = take
        Task.detached(priority: .userInitiated) {
            let look = Self.makeLook(
                name: name, curve: curve, gamut: gamut, madeForRec709: madeFor, sourceRec709: sourceRec709,
                grade: grade)
            await MainActor.run { job.start(take: take, look: look, preset: preset, lookLabel: lutLabel) }
        }
    }
}

/// Runs one export off the main thread and reports on it.
@MainActor
final class LookExportJob: ObservableObject {
    @Published var progress: Double?
    @Published var message: String?
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

    func cancel() { stop.set(true) }

    func start(take: Take, look: LookExporter.Look, preset: EncoderPreset, lookLabel: String) {
        guard progress == nil else { return }
        stop.set(false)
        progress = 0
        message = nil
        let stop = stop
        Task.detached(priority: .userInitiated) { [weak self] in
            let outcome: String
            do {
                let saved = try await Self.export(
                    take: take, look: look, preset: preset, lookLabel: lookLabel, stop: stop
                ) { share in
                    Task { @MainActor in self?.progress = share }
                }
                outcome = "Saved as \(saved.lastPathComponent)"
                Log.shared.info("Exported \(take.url.lastPathComponent) as \(saved.lastPathComponent): \(lookLabel)")
            } catch {
                outcome = "\(error)"
                Log.shared.warn("Export of \(take.url.lastPathComponent) stopped: \(error)")
            }
            await MainActor.run {
                self?.progress = nil
                self?.message = outcome
            }
        }
    }

    /// Writes the video with the look to a scratch file, then joins it with the take's audio
    /// into the videos folder, with a sidecar and a copy of the gyro log.
    nonisolated private static func export(
        take: Take, look: LookExporter.Look, preset: EncoderPreset, lookLabel: String, stop: StopFlag,
        progress: @escaping (Double) -> Void
    ) async throws -> URL {
        guard let exporter = LookExporter(look: look) else { throw LookExporter.Failure.gpu }
        let source = try await LookExporter.describe(take.url)
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mov")
        defer { try? FileManager.default.removeItem(at: scratch) }
        let name = take.url.deletingPathExtension().lastPathComponent + "_look.mov"
        let destination = Storage.videos.appendingPathComponent(name)

        var metadata = take.info?.metadata ?? [:]
        metadata["look"] = lookLabel
        metadata["fileTag"] = FileTag.rec709.label
        metadata["exportedFrom"] = take.url.lastPathComponent
        let rate = take.info?.metadata["frameRate"].flatMap(Double.init) ?? 30
        let encoder = try VideoEncoder(config: .init(
            url: scratch, preset: preset, size: EncoderSize(width: source.width, height: source.height),
            frameRate: rate, audio: false, realTime: false, metadata: metadata, fileTag: .rec709))
        try await exporter.export(
            from: take.url, into: encoder, seconds: source.seconds, progress: progress, cancelled: { stop.isSet })
        var result = await withCheckedContinuation { continuation in
            encoder.finish { continuation.resume(returning: $0) }
        }
        if let failure = result.failure { throw LookExporter.Failure.cannotRead(failure) }

        try? FileManager.default.removeItem(at: destination)
        try await joinAudio(video: scratch, from: take.url, into: destination)
        result.file = name
        if let data = try? JSONEncoder().encode(result) {
            try? data.write(to: TakeLibrary.sidecar(for: destination))
        }
        let gyro = TakeLibrary.gyroLog(for: take.url)
        if FileManager.default.fileExists(atPath: gyro.path) {
            try? FileManager.default.copyItem(at: gyro, to: TakeLibrary.gyroLog(for: destination))
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
            throw LookExporter.Failure.cannotRead("can't join the audio")
        }
        session.outputURL = destination
        session.outputFileType = .mov
        await withCheckedContinuation { continuation in
            session.exportAsynchronously { continuation.resume() }
        }
        if session.status != .completed {
            throw LookExporter.Failure.cannotRead(session.error?.localizedDescription ?? "can't join the audio")
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
    @State private var tab = Tab.adjust
    @State private var naming = false
    @State private var styleName = ""

    enum Tab: String, CaseIterable { case looks = "Looks", adjust = "Adjust", color = "Color" }

    var body: some View {
        Section {
            Picker("Page", selection: $tab) {
                ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets())
        }
        switch tab {
        case .looks: looks
        case .adjust: adjust
        case .color: colors
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
                        grade = style.grade
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
            Slider(value: value, in: range)
                .tint(tint)
                .accessibilityLabel(title)
                .accessibilityValue(text)
        }
    }
}
