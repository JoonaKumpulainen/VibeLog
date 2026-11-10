import AVFoundation
import AudioToolbox
import ObjCGuard
import VLCore

/// Runs a continuous capture loop on AVCapturePhotoOutput and turns each Bayer RAW
/// photo into a RawFrame.
final class PhotoRawDriver: NSObject {
    var onFrame: ((RawFrame) -> Void)?
    /// The flag says whether this failure should be logged.
    var onFailure: ((String, Bool) -> Void)?
    var onReference: ((Data?, [String: Any]) -> Void)?
    /// Runs on the loop's queue when requests have stopped finishing. True means the owner
    /// rebuilds the session, so the loop stops. False keeps it retrying in place.
    var onStalled: (() -> Bool)?

    private let output: AVCapturePhotoOutput
    private let device: AVCaptureDevice
    private let method: CaptureMethod
    private let rawFormat: OSType
    private let size: PhotoSize
    private let bracketCount: Int
    private let timing: CaptureTimingLog
    private let queue = DispatchQueue(label: "vibelog.photo-loop", qos: .userInitiated)
    private let maxInFlight = 4
    /// Keeps requests from outrunning the sensor when several events trigger one.
    private let minimumRequestInterval: Double

    private var running = false
    private var inFlight = 0
    private var wantReference = false
    private var lastEvent = Date()
    private var lastRequest = Date.distantPast
    private var retryScheduled = false
    private var failureCounts: [Int: Int] = [:]
    private var watchdog: DispatchSourceTimer?
    private var coordinator: AVCapturePhotoOutputReadinessCoordinator?
    private var stalls = StallCounter()
    /// Written from the photo callbacks' threads, so a stall can say how far its request got.
    private let traceLock = NSLock()
    private var lastCallback = "none"
    private var framesDelivered = 0

    init(
        output: AVCapturePhotoOutput, device: AVCaptureDevice, method: CaptureMethod,
        rawFormat: OSType, size: PhotoSize, bracketCount: Int, frameRate: Double,
        timing: CaptureTimingLog
    ) {
        self.output = output
        self.device = device
        self.method = method
        self.rawFormat = rawFormat
        self.size = size
        self.bracketCount = bracketCount
        self.timing = timing
        minimumRequestInterval = 0.9 / frameRate
    }

    private func note(
        _ event: CaptureTimingLog.Event, request: Int64 = 0, sensorTime: Double? = nil, inFlight: Int? = nil
    ) {
        timing.record(
            event, time: CMTimeGetSeconds(CMClockGetTime(CMClockGetHostTimeClock())), request: request,
            sensorTime: sensorTime, inFlight: inFlight)
    }

    private func trace(_ callback: String, frame: Bool = false) {
        traceLock.lock()
        lastCallback = callback
        if frame { framesDelivered += 1 }
        traceLock.unlock()
    }

    private func readTrace(reset: Bool = false) -> (callback: String, frames: Int) {
        traceLock.lock()
        defer { traceLock.unlock() }
        let result = (lastCallback, framesDelivered)
        if reset {
            lastCallback = "none"
            framesDelivered = 0
        }
        return result
    }

    private var readinessName: String {
        switch output.captureReadiness {
        case .sessionNotRunning: return "session not running"
        case .ready: return "ready"
        case .notReadyMomentarily: return "not ready momentarily"
        case .notReadyWaitingForCapture: return "waiting for capture"
        case .notReadyWaitingForProcessing: return "waiting for processing"
        @unknown default: return "unknown"
        }
    }

    func start() {
        queue.async { [self] in
            running = true
            inFlight = 0
            stalls.reset()
            _ = readTrace(reset: true)
            lastEvent = Date()
            failureCounts = [:]
            if method == .photoReadiness {
                let coordinator = AVCapturePhotoOutputReadinessCoordinator(photoOutput: output)
                coordinator.delegate = self
                self.coordinator = coordinator
            }
            startWatchdog()
            fire()
        }
    }

    func stop() {
        queue.sync {
            running = false
            watchdog?.cancel()
            watchdog = nil
            coordinator?.delegate = nil
            coordinator = nil
        }
    }

    func requestReference() {
        queue.async { [self] in wantReference = true }
    }

    private func startWatchdog() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 2, repeating: 1)
        timer.setEventHandler { [weak self] in
            guard let self, self.running, Date().timeIntervalSince(self.lastEvent) > 2 else { return }
            self.handleStall()
        }
        timer.resume()
        watchdog = timer
    }

    /// Runs on `queue`. One stall is retried in place. A second with no frame between them means
    /// the requests aren't finishing, and each new one would pile onto the camera's limit, so the
    /// owner is asked to rebuild the session another way.
    private func handleStall() {
        let seen = readTrace()
        let detail = "\(inFlight) in flight, last callback \(seen.callback), "
            + "\(seen.frames) frames since start, readiness \(readinessName)"
        let now = CMTimeGetSeconds(CMClockGetTime(CMClockGetHostTimeClock()))
        if stalls.stalled(at: now) == .giveUp, onStalled?() == true {
            Log.shared.warn("Photo loop stalled again with \(detail), so the session is rebuilt")
            running = false
            watchdog?.cancel()
            watchdog = nil
            return
        }
        Log.shared.warn("Photo loop stalled with \(detail), restarting it")
        inFlight = 0
        lastEvent = Date()
        fire()
    }

    private func makeSettings() -> AVCapturePhotoSettings {
        let settings: AVCapturePhotoSettings
        if method == .photoBracket {
            settings = AVCapturePhotoBracketSettings(
                rawPixelFormatType: rawFormat, processedFormat: nil,
                bracketedSettings: makeBracket())
        } else {
            settings = AVCapturePhotoSettings(rawPixelFormatType: rawFormat)
        }
        settings.maxPhotoDimensions = CMVideoDimensions(
            width: Int32(size.width), height: Int32(size.height))
        settings.photoQualityPrioritization = .speed
        settings.flashMode = .off
        if #available(iOS 18.0, *), output.isShutterSoundSuppressionSupported {
            settings.isShutterSoundSuppressionEnabled = true
        }
        return settings
    }

    private func makeBracket() -> [AVCaptureBracketedStillImageSettings] {
        let isManual = device.exposureMode == .custom
        return (0..<bracketCount).map { _ -> AVCaptureBracketedStillImageSettings in
            if isManual {
                return AVCaptureManualExposureBracketedStillImageSettings.manualExposureSettings(
                    exposureDuration: device.exposureDuration, iso: device.iso)
            }
            return AVCaptureAutoExposureBracketedStillImageSettings.autoExposureSettings(
                exposureTargetBias: 0)
        }
    }

    /// Runs on `queue`. Exceptions here mean the settings are invalid for this
    /// configuration, so the loop stops rather than crashing the app.
    private func fire() {
        guard running, inFlight < maxInFlight else { return }
        let settings = makeSettings()
        note(.request, request: settings.uniqueID, inFlight: inFlight)
        let exception = VLTryCatch {
            self.coordinator?.startTrackingCaptureRequest(using: settings)
            self.output.capturePhoto(with: settings, delegate: self)
            self.coordinator?.stopTrackingCaptureRequest(using: settings.uniqueID)
        }
        if let exception {
            running = false
            onFailure?("capturePhoto raised \(exception.name.rawValue): \(exception.reason ?? "")", true)
            return
        }
        inFlight += 1
        lastRequest = Date()
    }

    /// Runs on `queue`. Readiness callbacks arrive on the main thread, so capture events
    /// also trigger requests and UI work cannot delay the next frame.
    private func requestWhenReady() {
        guard running else { return }
        guard inFlight < maxInFlight else {
            note(.heldInFlight)
            return
        }
        let wait = minimumRequestInterval - Date().timeIntervalSince(lastRequest)
        if wait > 0 {
            guard !retryScheduled else { return }
            retryScheduled = true
            queue.asyncAfter(deadline: .now() + wait) { [self] in
                retryScheduled = false
                requestWhenReady()
            }
        } else if output.captureReadiness == .ready {
            fire()
        } else {
            note(.heldNotReady)
        }
    }

    private func finishedRequest() {
        queue.async { [self] in
            inFlight = max(0, inFlight - 1)
            lastEvent = Date()
            if method == .photoReadiness {
                requestWhenReady()
            } else {
                fire()
            }
        }
    }

    /// Reports the first failure of each code and then every 50th, to keep the log readable.
    private func reportFailure(_ error: NSError) {
        queue.async { [self] in
            let count = (failureCounts[error.code] ?? 0) + 1
            failureCounts[error.code] = count
            let underlying = (error.userInfo[NSUnderlyingErrorKey] as? NSError)?.code ?? 0
            let message = "Photo failed: \(error.domain) \(error.code), underlying \(underlying), count \(count)"
            onFailure?(message, count == 1 || count % 50 == 0)
        }
    }
}

extension PhotoRawDriver: AVCapturePhotoCaptureDelegate {
    func photoOutput(
        _ output: AVCapturePhotoOutput,
        willCapturePhotoFor resolvedSettings: AVCaptureResolvedPhotoSettings
    ) {
        note(.willCapture, request: resolvedSettings.uniqueID)
        trace("willCapture")
        // Removes the shutter sound on iOS 17, where suppression has no public API.
        AudioServicesDisposeSystemSoundID(1108)
        if method == .photoReadiness {
            queue.async { [self] in requestWhenReady() }
        }
    }

    func photoOutput(
        _ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto,
        error: Error?
    ) {
        if let error {
            note(.failed, request: photo.resolvedSettings.uniqueID)
            trace("photo failed \((error as NSError).code)")
            reportFailure(error as NSError)
            return
        }
        note(.frame, request: photo.resolvedSettings.uniqueID, sensorTime: CMTimeGetSeconds(photo.timestamp))
        trace("photo", frame: true)
        queue.async { [self] in stalls.frameArrived() }
        guard let buffer = photo.pixelBuffer else {
            onFailure?("Photo has no pixelBuffer (isRawPhoto=\(photo.isRawPhoto))", true)
            return
        }
        let gains = device.deviceWhiteBalanceGains
        onFrame?(RawFrame(
            buffer: buffer, pts: CMTimeGetSeconds(photo.timestamp),
            exposureSeconds: CMTimeGetSeconds(device.exposureDuration), iso: device.iso,
            whiteBalanceGains: [gains.redGain, gains.greenGain, gains.blueGain]))

        queue.async { [self] in
            guard wantReference else { return }
            wantReference = false
            DispatchQueue.global(qos: .utility).async { [self] in
                onReference?(photo.fileDataRepresentation(), photo.metadata)
            }
        }
    }

    func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings, error: Error?
    ) {
        note(.finished, request: resolvedSettings.uniqueID)
        trace("finished")
        finishedRequest()
    }
}

extension PhotoRawDriver: AVCapturePhotoOutputReadinessCoordinatorDelegate {
    func readinessCoordinator(
        _ coordinator: AVCapturePhotoOutputReadinessCoordinator,
        captureReadinessDidChange captureReadiness: AVCapturePhotoOutput.CaptureReadiness
    ) {
        note(captureReadiness == .ready ? .ready : .notReady)
        guard captureReadiness == .ready else { return }
        queue.async { [self] in
            lastEvent = Date()
            requestWhenReady()
        }
    }
}
