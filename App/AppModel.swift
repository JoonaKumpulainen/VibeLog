import AVFoundation
import Combine
import Foundation
import UIKit
import VLCapture
import VLCore
import VLProcessing
import VLRecording

final class AppModel: ObservableObject {
    let camera = CameraController()
    let pipeline = ProcessingPipeline()

    @Published var lenses: [LensInfo] = []
    @Published var formats: [FormatInfo] = []
    @Published var options: CaptureOptions?
    @Published var stats = FrameStats.Snapshot()
    @Published var status = SystemLine()
    @Published var isStreaming = false
    @Published var isRecording = false
    @Published var isBusy: String?
    @Published var lastResult: String?
    @Published var permissionDenied = false
    @Published var lastFrameLabel = "-"

    @Published var lensID = "" { didSet { if lensID != oldValue { lensChanged() } } }
    @Published var formatIndex = 0 { didSet { if formatIndex != oldValue { reconfigure() } } }
    @Published var method = CaptureMethod.photoReadiness { didSet { if method != oldValue { reconfigure() } } }
    @Published var rawFormat: OSType = 0 { didSet { if rawFormat != oldValue { reconfigure() } } }
    @Published var photoSize: PhotoSize? { didSet { if photoSize != oldValue { reconfigure() } } }
    @Published var videoFormat: OSType = 0 { didSet { if videoFormat != oldValue { reconfigure() } } }
    @Published var videoFPS = 30.0 { didSet { if videoFPS != oldValue { reconfigure() } } }
    @Published var bracketCount = 3 { didSet { if bracketCount != oldValue { reconfigure() } } }
    @Published var usePhotoPreset = true { didSet { if usePhotoPreset != oldValue { reconfigure() } } }

    @Published var processing = ProcessingSettings() { didSet { pipeline?.update(processing) } }
    @Published var pipelineStats = PipelineStats()

    @Published var recordEncoded = true
    /// The best preset proven at full size on an iPhone 14 Pro at 30 fps.
    @Published var encoderPreset = EncoderPreset.all.first { $0.id == "prores422hq" } ?? EncoderPreset.all[0]
    @Published var encoderSize = EncoderSize.all[0]
    @Published var widescreen = false { didSet { updateCrop() } }
    @Published var lutNames: [String] = []
    /// Empty selects the built-in Rec.709 LUT.
    @Published var selectedLUT = "" { didSet { if selectedLUT != oldValue { loadSelectedLUT() } } }
    @Published var recordElapsed = 0

    /// Zero records until stopped.
    @Published var recordSeconds = 120.0
    @Published var writeFrames = true

    @Published var exposureLocked = false { didSet { applyExposure() } }
    @Published var iso: Float = 100 { didSet { if exposureLocked { applyExposure() } } }
    /// Log2 of the shutter denominator: 6.64 is 1/100 s.
    @Published var shutterStops: Double = 6.64 { didSet { if exposureLocked { applyExposure() } } }
    @Published var whiteBalanceLocked = false { didSet { applyWhiteBalance() } }
    @Published var temperature: Float = 5600 { didSet { if whiteBalanceLocked { applyWhiteBalance() } } }
    @Published var tint: Float = 0 { didSet { if whiteBalanceLocked { applyWhiteBalance() } } }
    @Published var focusLocked = false { didSet { applyFocus() } }
    @Published var lensPosition: Float = 0.8 { didSet { if focusLocked { applyFocus() } } }

    var shutterLabel: String { "1/\(Int(pow(2, shutterStops).rounded()))" }

    struct SystemLine {
        var thermal = "-"
        var footprintMB = 0
        var availableMB = 0
        var freeDiskGB = 0
        var battery = "?"
    }

    private let router = FrameRouter()
    private var timer: Timer?
    private var applyingOptions = false
    private var thermalObserver: NSObjectProtocol?
    private var recordDeadline: Date?
    private var started = false
    private var ticksSinceReport = 0
    private var recordStart = Date()
    private var recordStarting = false
    private let statsQueue = DispatchQueue(label: "vibelog.stats", qos: .utility)

    func onAppear() {
        guard !started else { return }
        started = true
        router.pipeline = pipeline
        SystemStatus.enableBatteryMonitoring()
        refreshLUTs()
        router.onRecordingElapsed = { [weak self] in
            DispatchQueue.main.async { self?.stopRecording() }
        }
        camera.onFrame = { [router] frame in router.handle(frame) }
        camera.onCaptureDrop = { [router] reason in router.handleDrop(reason) }
        camera.onCaptureFailure = { [router] _ in router.handleFailure() }
        camera.onReference = { [weak self] data, metadata in self?.handleReference(data, metadata) }
        camera.onOptionsChanged = { [weak self] options in self?.adopt(options) }

        thermalObserver = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: nil
        ) { [weak self] _ in
            Log.shared.warn("Thermal state changed to \(SystemStatus.thermalName)")
            self?.updateHeatMode()
        }
        updateHeatMode()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.tick()
        }

        AVCaptureDevice.requestAccess(for: .video) { granted in
            DispatchQueue.main.async { [self] in
                if granted {
                    loadLenses()
                    AVCaptureDevice.requestAccess(for: .audio) { _ in }
                } else {
                    permissionDenied = true
                    Log.shared.error("Camera permission denied")
                }
            }
        }
    }

    func enteredBackground() {
        if isRecording { stopRecording() }
        if isStreaming { toggleStream() }
    }

    func toggleStream() {
        if isStreaming {
            if isRecording { stopRecording() }
            camera.stop()
            isStreaming = false
        } else {
            router.stats.reset()
            pipeline?.resetStats()
            if method.isPhoto { camera.requestReference() }
            camera.start()
            isStreaming = true
        }
    }

    func runEncoderTest() {
        guard !isRecording, isBusy == nil else { return }
        isBusy = "Releasing camera"
        isStreaming = false
        camera.teardown { [self] in
            EncoderProbe.run(progress: { text in
                DispatchQueue.main.async { self.isBusy = text }
            }, completion: { [self] url in
                isBusy = nil
                lastResult = "Encoder test saved: probes/\(url.lastPathComponent)"
                reconfigure()
            })
        }
    }

    func importLUT(from url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let text = try String(contentsOf: url, encoding: .utf8)
            let lut = try CubeLUT(text: text)
            let target = Storage.luts.appendingPathComponent(url.lastPathComponent)
            try text.write(to: target, atomically: true, encoding: .utf8)
            Log.shared.info("Imported LUT \(url.lastPathComponent), size \(lut.size)")
            refreshLUTs()
            selectedLUT = url.lastPathComponent
        } catch {
            Log.shared.error("LUT import failed for \(url.lastPathComponent): \(error)")
        }
    }

    private func refreshLUTs() {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: Storage.luts.path)) ?? []
        lutNames = files.filter { $0.lowercased().hasSuffix(".cube") }.sorted()
    }

    private func loadSelectedLUT() {
        let name = selectedLUT
        guard !name.isEmpty else {
            pipeline?.setCustomLUT(nil)
            return
        }
        DispatchQueue.global(qos: .userInitiated).async { [pipeline] in
            do {
                let url = Storage.luts.appendingPathComponent(name)
                let lut = try CubeLUT(text: String(contentsOf: url, encoding: .utf8))
                pipeline?.setCustomLUT(lut)
            } catch {
                Log.shared.error("Cannot load LUT \(name): \(error)")
            }
        }
    }

    private func updateHeatMode() {
        let state = ProcessInfo.processInfo.thermalState
        pipeline?.setHot(state == .serious || state == .critical)
    }

    private var outputSize: EncoderSize { widescreen ? encoderSize.widescreen : encoderSize }

    private func updateCrop() {
        // The sensor is 4:3, so 16:9 keeps three quarters of its height.
        processing.cropFraction = widescreen ? 0.75 : 1
    }

    func toggleRecord() {
        isRecording ? stopRecording() : startRecording()
    }

    func runProbe() {
        guard !isRecording, isBusy == nil else { return }
        isBusy = "Releasing camera"
        isStreaming = false
        camera.teardown { [self] in
            CaptureProbe.run(progress: { text in
                DispatchQueue.main.async { self.isBusy = text }
            }, completion: { [self] url in
                isBusy = nil
                lastResult = "Probe saved: probes/\(url.lastPathComponent)"
                reconfigure()
            })
        }
    }

    // MARK: Private

    func saveStill() {
        guard let pipeline else { return }
        guard isStreaming else {
            Log.shared.warn("Start streaming before saving a still")
            return
        }
        pipeline.requestStill { [weak self] still in
            guard let still else {
                Log.shared.error("Still readback failed")
                return
            }
            DispatchQueue.global(qos: .utility).async {
                do {
                    let (folder, spot) = try StillExporter.export(still)
                    let message = "Still saved: stills/\(folder.lastPathComponent)"
                    Log.shared.info("\(message), center log \(spot.log) linear \(spot.linear)")
                    DispatchQueue.main.async { self?.lastResult = message }
                } catch {
                    Log.shared.error("Still export failed: \(error)")
                }
            }
        }
    }

    private func loadLenses() {
        lenses = CameraController.lenses()
        guard let lens = lenses.first else {
            Log.shared.error("No rear camera found")
            return
        }
        lensID = lens.id
    }

    private func lensChanged() {
        formats = CameraController.formats(lensID: lensID)
        guard let format = CameraController.defaultFormat(in: formats) else { return }
        applyingOptions = true
        formatIndex = format.id
        applyingOptions = false
        reconfigure()
    }

    private func reconfigure() {
        guard !applyingOptions, !lensID.isEmpty else { return }
        let wasStreaming = isStreaming
        if isRecording { stopRecording() }
        isStreaming = false
        let config = CaptureConfig(
            lensID: lensID, formatIndex: formatIndex, method: method,
            rawPixelFormat: rawFormat == 0 ? nil : rawFormat, photoSize: photoSize,
            videoPixelFormat: videoFormat == 0 ? nil : videoFormat, videoFPS: videoFPS,
            bracketCount: bracketCount, usePhotoPreset: usePhotoPreset)
        camera.configure(config) { [self] options in
            guard let options else { return }
            adopt(options)
            applyExposure()
            applyWhiteBalance()
            applyFocus()
            if wasStreaming { toggleStream() }
        }
    }

    private func adopt(_ options: CaptureOptions) {
        applyingOptions = true
        self.options = options
        rawFormat = options.config.rawPixelFormat ?? 0
        photoSize = options.config.photoSize
        videoFormat = options.config.videoPixelFormat ?? 0
        bracketCount = options.config.bracketCount
        iso = min(max(iso, options.isoRange.lowerBound), options.isoRange.upperBound)
        applyingOptions = false
    }

    private func applyExposure() {
        guard !applyingOptions else { return }
        camera.setExposure(exposureLocked ? .locked : .auto, seconds: 1 / pow(2, shutterStops), iso: iso)
    }

    private func applyWhiteBalance() {
        guard !applyingOptions else { return }
        camera.setWhiteBalance(whiteBalanceLocked ? .locked : .auto, temperature: temperature, tint: tint)
    }

    private func applyFocus() {
        guard !applyingOptions else { return }
        camera.setFocus(focusLocked ? .locked : .auto, lensPosition: lensPosition)
    }

    private func startRecording() {
        guard !isRecording, !recordStarting else { return }
        let warmUp = !isStreaming
        if warmUp { toggleStream() }
        if recordEncoded {
            // The first frames after a stream starts are unreliable, so give it a moment.
            recordStarting = true
            DispatchQueue.main.asyncAfter(deadline: .now() + (warmUp ? 1 : 0)) { [self] in
                recordStarting = false
                if isStreaming { startEncoding() }
            }
            return
        }
        let name = "clip_\(Storage.timestamp())"
        let budget = min(1_000_000_000, SystemStatus.availableMemory * 2 / 5)
        let lens = lenses.first { $0.id == lensID }?.name ?? lensID
        let context = ClipContext(
            method: method.rawValue, lens: lens, format: options?.formatDescription ?? "",
            requestedSeconds: rawDumpSeconds)
        do {
            let recorder = try RawRecorder(config: .init(
                directory: Storage.clips.appendingPathComponent(name, isDirectory: true),
                writeFrames: writeFrames, memoryBudget: budget, context: context))
            if method.isPhoto {
                recorder.beginReference()
                pendingReferences.append(recorder)
                camera.requestReference()
            }
            router.stats.reset()
            pipeline?.resetStats()
            router.beginRecording(recorder, seconds: rawDumpSeconds)
            recordDeadline = Date().addingTimeInterval(rawDumpSeconds + 5)
            recordStart = Date()
            isRecording = true
            Log.shared.info("Recording \(name) for \(rawDumpSeconds)s, write=\(writeFrames), budget \(budget / 1_000_000) MB")
        } catch {
            Log.shared.error("Cannot start recording: \(error.localizedDescription)")
        }
    }

    /// RAW dumps need an end time, so until-stopped means an hour.
    private var rawDumpSeconds: Double { recordSeconds > 0 ? recordSeconds : 3600 }

    private func startEncoding() {
        guard let pipeline, processing.enabled, method.isPhoto else {
            Log.shared.error("Encoding needs a photo method and the GPU pipeline")
            return
        }
        let name = "video_\(Storage.timestamp())"
        let url = Storage.videos.appendingPathComponent(name + ".mov")
        let metadata = [
            "curve": processing.curve.label, "gamut": "Rec.2020",
            "matrix": "Rec.2020 non-constant luminance, video range",
            "exposureStops": String(processing.exposureStops),
            "aspect": widescreen ? "16:9 center crop" : "4:3 open gate",
            "pipeline": processing.pipeline.label,
            "note": "The file's transfer tag is nominal; decode with the curve named here.",
        ]
        do {
            let encoder = try VideoEncoder(config: .init(
                url: url, preset: encoderPreset, size: outputSize, audio: true, metadata: metadata))
            audio.onSample = { [weak encoder] sample in encoder?.appendAudio(sample) }
            encoder.onFailure = { [weak self] message in
                Log.shared.error("Recording stopped: \(message)")
                self?.stopRecording()
            }
            audio.start { _ in }
            activeEncoder = encoder
            router.stats.reset()
            pipeline.resetStats()
            pipeline.setSink(encoder)
            recordStart = Date()
            isRecording = true
            let seconds = recordSeconds
            Log.shared.info("Encoding \(name): \(encoderPreset.label) \(outputSize.label), \(processing.curve.label), \(processing.pipeline.label) pipeline, \(seconds > 0 ? "\(seconds)s" : "until stopped"), battery \(SystemStatus.batteryText), thermal \(SystemStatus.thermalName), free \(SystemStatus.freeDisk / 1_000_000_000) GB")
            guard seconds > 0 else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self, weak encoder] in
                guard let self, let encoder, self.activeEncoder === encoder else { return }
                self.stopRecording()
            }
        } catch {
            Log.shared.error("Cannot start \(encoderPreset.label) \(outputSize.label): \(error)")
        }
    }

    private func stopEncoding(_ encoder: VideoEncoder) {
        activeEncoder = nil
        isRecording = false
        pipeline?.setSink(nil)
        audio.stop()
        let capture = router.stats.snapshot()
        let gpu = pipeline?.currentStats() ?? PipelineStats()
        encoder.finish { [self] result in
            let summary = String(
                format: "%@ %dx%d: %.2f fps written, %d frames, %d dropped (%d no buffer, %d not ready), %.1f MB/s, audio %d, capture %.2f fps fail %d, gpu %.1f recent %.1f max ms drop %d",
                result.preset, result.width, result.height, result.fps, result.framesWritten,
                result.framesDropped, result.droppedNoBuffer, result.droppedNotReady,
                result.megabytesPerSecond, result.audioSamplesWritten,
                capture.sustainedFPS, capture.captureFailures, gpu.gpuRecentMs, gpu.gpuMaxMs, gpu.dropped)
            if let failure = result.failure {
                Log.shared.error("VIDEO FAILED \(result.file): \(failure)")
            }
            Log.shared.info("VIDEO RESULT \(result.file): \(summary)")
            lastResult = summary
            guard result.framesWritten > 0 else { return }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let sidecar = Storage.videos.appendingPathComponent(result.file + ".json")
            try? encoder.encode(result).write(to: sidecar)
        }
    }

    private func stopRecording() {
        if let encoder = activeEncoder {
            stopEncoding(encoder)
            return
        }
        recordDeadline = nil
        guard isRecording, let recorder = router.endRecording() else { return }
        isRecording = false
        // A photo reference that never arrives must not block the clip from closing.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [self] in
            if let index = pendingReferences.firstIndex(where: { $0 === recorder }) {
                pendingReferences.remove(at: index)
                recorder.finishReference(dng: nil, metadata: [:])
            }
        }
        recorder.finish { [self] result in
            lastResult = result.summary
        }
    }

    private var pendingReferences: [RawRecorder] = []
    private let audio = AudioCapture()
    private var activeEncoder: VideoEncoder?

    /// Runs off the main thread with a DNG from the capture driver.
    private func handleReference(_ data: Data?, _ metadata: [String: Any]) {
        let levels = RawLevels(photoMetadata: metadata)
        pipeline?.setCalibration(data.flatMap { try? DNGMetadata(dng: $0) }, levels: levels)
        if let levels {
            Log.shared.info("RAW buffer levels: black \(levels.black) white \(levels.white) clip \(levels.clipValue)")
        } else {
            Log.shared.warn("Photo metadata has no RAW levels")
        }
        if let data, let parsed = try? DNGMetadata(dng: data) {
            Log.shared.info("DNG: cfa=\(parsed.cfaPattern ?? "?") black=\(parsed.blackLevel ?? []) "
                + "white=\(parsed.whiteLevel ?? []) neutral=\(parsed.asShotNeutral ?? []) "
                + "model=\(parsed.model ?? "?")")
        } else {
            Log.shared.warn("Reference DNG missing or unreadable (\(data?.count ?? 0) bytes)")
        }
        DispatchQueue.main.async { [self] in
            guard !pendingReferences.isEmpty else { return }
            let recorder = pendingReferences.removeFirst()
            DispatchQueue.global(qos: .utility).async {
                recorder.finishReference(dng: data, metadata: metadata)
            }
        }
    }

    /// Measures off the main thread, which capture readiness callbacks depend on.
    private func tick() {
        let battery = SystemStatus.batteryText
        statsQueue.async { [self] in
            let snapshot = router.stats.snapshot()
            let gpu = pipeline?.currentStats() ?? PipelineStats()
            let line = SystemLine(
                thermal: SystemStatus.thermalName,
                footprintMB: SystemStatus.footprint / 1_000_000,
                availableMB: SystemStatus.availableMemory / 1_000_000,
                freeDiskGB: Int(SystemStatus.freeDisk / 1_000_000_000), battery: battery)
            DispatchQueue.main.async { [self] in show(snapshot, gpu, line) }
        }
    }

    private func show(_ snapshot: FrameStats.Snapshot, _ gpu: PipelineStats, _ line: SystemLine) {
        stats = snapshot
        pipelineStats = gpu
        if isRecording {
            recordElapsed = Int(Date().timeIntervalSince(recordStart))
            if line.thermal == "CRITICAL" {
                Log.shared.warn("Stopping at \(recordElapsed)s: thermal state is critical")
                stopRecording()
            } else if line.freeDiskGB < 2 {
                Log.shared.warn("Stopping at \(recordElapsed)s: less than 2 GB free")
                stopRecording()
            }
        }
        status = line
        if isRecording {
            ticksSinceReport += 1
            if ticksSinceReport >= 5 {
                ticksSinceReport = 0
                let line = String(
                    format: "Recording: %.2f fps now, n=%d, fail %d, writer drops %d, gpu %d done %d dropped %.1f recent %.1f max ms, mem %d MB, avail %d MB, thermal %@, free %d GB, battery %@",
                    stats.rollingFPS, stats.frames, stats.captureFailures, stats.writerDrops,
                    gpu.processed, gpu.dropped, gpu.gpuRecentMs, gpu.gpuMaxMs,
                    status.footprintMB, status.availableMB,
                    status.thermal, status.freeDiskGB, status.battery)
                if let activeEncoder {
                    activeEncoder.counts { written, dropped in
                        Log.shared.info("\(line), encoder \(written) written \(dropped) dropped")
                    }
                } else {
                    Log.shared.info(line)
                }
            }
        }
        if let deadline = recordDeadline, Date() > deadline {
            Log.shared.warn("Recording stopped by deadline, frames stopped arriving")
            stopRecording()
        }
    }
}
