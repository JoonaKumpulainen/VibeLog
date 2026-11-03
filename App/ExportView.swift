import AVFoundation
import SwiftUI
import VLCore
import VLProcessing
import VLRecording

/// Bakes a look into a copy of a take: the Rec.709 view, or a LUT, previewed first. The copy is
/// tagged Rec.709 and saved beside the take, with its audio, and the take itself is left as it is.
struct ExportView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let take: Take
    @StateObject private var job = LookExportJob()
    @State private var lutName = ""
    @State private var lutMadeForRec709 = false
    @State private var codec = "hevc420"
    @State private var seconds = 0.0
    @State private var length = 0.0
    @State private var preview: CGImage?
    @State private var previewFailure: String?

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
                        if let preview {
                            Image(decorative: preview, scale: 1)
                                .resizable()
                                .scaledToFit()
                        } else {
                            Text(previewFailure ?? "Loading preview")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .aspectRatio(4 / 3, contentMode: .fit)
                    .listRowInsets(EdgeInsets())
                    if length > 0 {
                        Slider(value: $seconds, in: 0...length) { editing in
                            if !editing { refreshPreview() }
                        }
                        .accessibilityLabel("Preview time")
                    }
                } footer: {
                    Text("\(curve.label) in \(gamut.label), from the take's details.")
                }
                Section("Look") {
                    Picker("LUT", selection: $lutName) {
                        Text("Rec.709 view").tag("")
                        ForEach(model.lookNames, id: \.self) { Text($0).tag($0) }
                    }
                    if !lutName.isEmpty, BuiltInLook.named(lutName) == nil {
                        Picker("LUT made for", selection: $lutMadeForRec709) {
                            Text("Log").tag(false)
                            Text("Rec.709").tag(true)
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
                        ? "Writes a new take tagged Rec.709 beside this one. Keep VibeLog open until it's done."
                        : "This take already has its look baked in.")
                }
            }
            .navigationTitle("Export with look")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        job.cancel()
                        dismiss()
                    }
                }
            }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            lutName = model.linkedLUT(curve, gamut) ?? model.selectedLUT
            if !model.isAvailableLook(lutName) { lutName = "" }
            lutMadeForRec709 = model.processing.lutExpectsRec709
            Task {
                length = (try? await LookExporter.describe(take.url).seconds) ?? 0
                seconds = length / 2
                refreshPreview()
            }
        }
        .onChange(of: lutName) { _, _ in refreshPreview() }
        .onChange(of: lutMadeForRec709) { _, _ in refreshPreview() }
        .interactiveDismissDisabled(job.progress != nil)
    }

    /// Reading a .cube or building an ACES look takes a moment, so this runs off the main thread.
    nonisolated private static func makeLook(
        name: String, curve: LogCurve, gamut: Gamut, madeForRec709: Bool, sourceRec709: Bool
    ) -> LookExporter.Look {
        if let builtIn = BuiltInLook.named(name) {
            return LookExporter.Look(
                curve: curve, gamut: gamut, lut: builtIn.lut(curve: curve, gamut: gamut), lutExpectsRec709: false,
                sourceRec709: sourceRec709)
        }
        var lut: CubeLUT?
        if !name.isEmpty {
            let url = Storage.luts.appendingPathComponent(name)
            lut = (try? String(contentsOf: url, encoding: .utf8)).flatMap { try? CubeLUT(text: $0) }
        }
        return LookExporter.Look(
            curve: curve, gamut: gamut, lut: lut, lutExpectsRec709: madeForRec709, sourceRec709: sourceRec709)
    }

    private var lookInputs: (String, LogCurve, Gamut, Bool, Bool) {
        (lutName, curve, gamut, lutMadeForRec709, take.info?.metadata["fileTag"] == FileTag.rec709.label)
    }

    private func refreshPreview() {
        let (name, curve, gamut, madeFor, sourceRec709) = lookInputs
        let url = take.url
        let time = seconds
        Task.detached(priority: .userInitiated) {
            do {
                let look = Self.makeLook(
                    name: name, curve: curve, gamut: gamut, madeForRec709: madeFor, sourceRec709: sourceRec709)
                guard let exporter = LookExporter(look: look) else { throw LookExporter.Failure.gpu }
                let image = try await exporter.preview(of: url, at: time, width: 960)
                await MainActor.run {
                    preview = image
                    previewFailure = nil
                }
            } catch {
                await MainActor.run { previewFailure = "\(error)" }
            }
        }
    }

    private func startExport() {
        let preset = EncoderPreset.all.first { $0.id == codec } ?? EncoderPreset.all[0]
        let lutLabel = lutName.isEmpty
            ? "Rec.709 view, baked in"
            : BuiltInLook.named(lutName) != nil ? "\(lutName) Rec.709, baked in"
            : "\(lutName), baked in" + (lutMadeForRec709 ? " after the Rec.709 view" : " on log")
        let (name, curve, gamut, madeFor, sourceRec709) = lookInputs
        let take = take
        Task.detached(priority: .userInitiated) {
            let look = Self.makeLook(
                name: name, curve: curve, gamut: gamut, madeForRec709: madeFor, sourceRec709: sourceRec709)
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
