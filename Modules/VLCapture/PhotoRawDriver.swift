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

    private let output: AVCapturePhotoOutput
    private let device: AVCaptureDevice
    private let method: CaptureMethod
    private let rawFormat: OSType
    private let size: PhotoSize
    private let bracketCount: Int
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

    init(
        output: AVCapturePhotoOutput, device: AVCaptureDevice, method: CaptureMethod,
        rawFormat: OSType, size: PhotoSize, bracketCount: Int, frameRate: Double
    ) {
        self.output = output
        self.device = device
        self.method = method
        self.rawFormat = rawFormat
        self.size = size
        self.bracketCount = bracketCount
        minimumRequestInterval = 0.9 / frameRate
    }

    func start() {
        queue.async { [self] in
            running = true
            inFlight = 0
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
            Log.shared.warn("Photo loop stalled with \(self.inFlight) in flight, restarting it")
            self.inFlight = 0
            self.lastEvent = Date()
            self.fire()
        }
        timer.resume()
        watchdog = timer
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
        guard running, inFlight < maxInFlight else { return }
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
            reportFailure(error as NSError)
            return
        }
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
        finishedRequest()
    }
}

extension PhotoRawDriver: AVCapturePhotoOutputReadinessCoordinatorDelegate {
    func readinessCoordinator(
        _ coordinator: AVCapturePhotoOutputReadinessCoordinator,
        captureReadinessDidChange captureReadiness: AVCapturePhotoOutput.CaptureReadiness
    ) {
        guard captureReadiness == .ready else { return }
        queue.async { [self] in
            lastEvent = Date()
            requestWhenReady()
        }
    }
}
