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
    let preview = RawPreviewRenderer()

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
    @Published var method = CaptureMethod.photoSequential { didSet { if method != oldValue { reconfigure() } } }
    @Published var rawFormat: OSType = 0 { didSet { if rawFormat != oldValue { reconfigure() } } }
    @Published var photoSize: PhotoSize? { didSet { if photoSize != oldValue { reconfigure() } } }
    @Published var videoFormat: OSType = 0 { didSet { if videoFormat != oldValue { reconfigure() } } }
    @Published var videoFPS = 30.0 { didSet { if videoFPS != oldValue { reconfigure() } } }
    @Published var bracketCount = 3 { didSet { if bracketCount != oldValue { reconfigure() } } }
    @Published var usePhotoPreset = true { didSet { if usePhotoPreset != oldValue { reconfigure() } } }

    @Published var recordSeconds = 5.0
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
    }

    private let router = FrameRouter()
    private var timer: Timer?
    private var applyingOptions = false
    private var thermalObserver: NSObjectProtocol?
    private var recordDeadline: Date?
    private var started = false

    func onAppear() {
        guard !started else { return }
        started = true
        router.preview = preview
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
        ) { _ in
            Log.shared.warn("Thermal state changed to \(SystemStatus.thermalName)")
        }
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.tick()
        }

        AVCaptureDevice.requestAccess(for: .video) { granted in
            DispatchQueue.main.async { [self] in
                if granted {
                    loadLenses()
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
            if method.isPhoto { camera.requestReference() }
            camera.start()
            isStreaming = true
        }
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
        guard !isRecording else { return }
        if !isStreaming { toggleStream() }
        let name = "clip_\(Storage.timestamp())"
        let budget = min(1_000_000_000, SystemStatus.availableMemory * 2 / 5)
        let lens = lenses.first { $0.id == lensID }?.name ?? lensID
        let context = ClipContext(
            method: method.rawValue, lens: lens, format: options?.formatDescription ?? "",
            requestedSeconds: recordSeconds)
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
            router.beginRecording(recorder, seconds: recordSeconds)
            recordDeadline = Date().addingTimeInterval(recordSeconds + 5)
            isRecording = true
            Log.shared.info("Recording \(name) for \(recordSeconds)s, write=\(writeFrames), budget \(budget / 1_000_000) MB")
        } catch {
            Log.shared.error("Cannot start recording: \(error.localizedDescription)")
        }
    }

    private func stopRecording() {
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

    /// Runs off the main thread with a DNG from the capture driver.
    private func handleReference(_ data: Data?, _ metadata: [String: Any]) {
        if let data, let parsed = try? DNGMetadata(dng: data) {
            let black = Float(parsed.blackLevel?.first ?? 0)
            let white = Float(parsed.whiteLevel?.first ?? 16383)
            preview?.setLevels(black: black, white: white)
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

    private func tick() {
        stats = router.stats.snapshot()
        status = SystemLine(
            thermal: SystemStatus.thermalName,
            footprintMB: SystemStatus.footprint / 1_000_000,
            availableMB: SystemStatus.availableMemory / 1_000_000,
            freeDiskGB: Int(SystemStatus.freeDisk / 1_000_000_000))
        if let deadline = recordDeadline, Date() > deadline {
            Log.shared.warn("Recording stopped by deadline, frames stopped arriving")
            stopRecording()
        }
    }
}
