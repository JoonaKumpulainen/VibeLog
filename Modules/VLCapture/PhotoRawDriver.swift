import AVFoundation
import AudioToolbox
import ObjCGuard
import VLCore

/// Runs a continuous capture loop on AVCapturePhotoOutput and turns each Bayer RAW
/// photo into a RawFrame.
final class PhotoRawDriver: NSObject {
    var onFrame: ((RawFrame) -> Void)?
    var onFailure: ((String) -> Void)?
    var onReference: ((Data?, [String: Any]) -> Void)?

    private let output: AVCapturePhotoOutput
    private let device: AVCaptureDevice
    private let method: CaptureMethod
    private let rawFormat: OSType
    private let size: PhotoSize
    private let bracketCount: Int
    private let queue = DispatchQueue(label: "vibelog.photo-loop", qos: .userInitiated)
    private let maxInFlight = 4

    private var running = false
    private var inFlight = 0
    private var wantReference = false
    private var lastEvent = Date()
    private var watchdog: DispatchSourceTimer?
    private var coordinator: AVCapturePhotoOutputReadinessCoordinator?

    init(
        output: AVCapturePhotoOutput, device: AVCaptureDevice, method: CaptureMethod,
        rawFormat: OSType, size: PhotoSize, bracketCount: Int
    ) {
        self.output = output
        self.device = device
        self.method = method
        self.rawFormat = rawFormat
        self.size = size
        self.bracketCount = bracketCount
    }

    func start() {
        queue.async { [self] in
            running = true
            inFlight = 0
            lastEvent = Date()
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
            onFailure?("capturePhoto raised \(exception.name.rawValue): \(exception.reason ?? "")")
            return
        }
        inFlight += 1
    }

    private func finishedRequest() {
        queue.async { [self] in
            inFlight = max(0, inFlight - 1)
            lastEvent = Date()
            if method == .photoReadiness {
                if output.captureReadiness == .ready { fire() }
            } else {
                fire()
            }
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
    }

    func photoOutput(
        _ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto,
        error: Error?
    ) {
        if let error {
            let details = error as NSError
            onFailure?("Photo failed: \(details.domain) \(details.code) \(details.localizedDescription) \(details.userInfo)")
            return
        }
        guard let buffer = photo.pixelBuffer else {
            onFailure?("Photo has no pixelBuffer (isRawPhoto=\(photo.isRawPhoto))")
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
            fire()
        }
    }
}
