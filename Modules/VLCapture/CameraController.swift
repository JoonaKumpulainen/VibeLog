import AVFoundation
import ObjCGuard
import VLCore

/// Owns the capture session, device controls and the active capture driver.
public final class CameraController: NSObject {
    public let session = AVCaptureSession()

    public var onFrame: ((RawFrame) -> Void)?
    public var onCaptureDrop: ((String) -> Void)?
    public var onCaptureFailure: ((String) -> Void)?
    public var onReference: ((Data?, [String: Any]) -> Void)?
    /// Runs on the main queue when options change after configuring.
    public var onOptionsChanged: ((CaptureOptions) -> Void)?
    /// Survives session rebuilds. It records nothing until `begin()`.
    public let timing = CaptureTimingLog()

    private let queue = DispatchQueue(label: "vibelog.session", qos: .userInitiated)
    private var device: AVCaptureDevice?
    private var priorityTimer: DispatchSourceTimer?
    private var input: AVCaptureDeviceInput?
    private var photoOutput: AVCapturePhotoOutput?
    private var videoOutput: AVCaptureVideoDataOutput?
    private var photoDriver: PhotoRawDriver?
    private var videoDriver: VideoDataDriver?
    private var options: CaptureOptions?
    private var observers: [NSObjectProtocol] = []
    private var pressureObservation: NSKeyValueObservation?

    public override init() {
        super.init()
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: .AVCaptureSessionRuntimeError, object: session, queue: nil
        ) { note in
            let error = note.userInfo?[AVCaptureSessionErrorKey] as? NSError
            Log.shared.error("Session runtime error: \(error?.localizedDescription ?? "?") code \(error?.code ?? 0)")
        })
        observers.append(center.addObserver(
            forName: .AVCaptureSessionWasInterrupted, object: session, queue: nil
        ) { note in
            Log.shared.warn("Session interrupted: \(note.userInfo ?? [:])")
        })
    }

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    public static func lenses() -> [LensInfo] {
        let wanted: [(AVCaptureDevice.DeviceType, String)] = [
            (.builtInWideAngleCamera, "1x Main"),
            (.builtInUltraWideCamera, "0.5x Ultra Wide"),
            (.builtInTelephotoCamera, "3x Tele"),
        ]
        return wanted.compactMap { type, name in
            AVCaptureDevice.default(type, for: .video, position: .back).map {
                LensInfo(id: $0.uniqueID, name: name)
            }
        }
    }

    public static func formats(lensID: String) -> [FormatInfo] {
        guard let device = AVCaptureDevice(uniqueID: lensID) else { return [] }
        return device.formats.enumerated().map { index, format in
            let size = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            let photo = format.photoSizes.map(\.width).max() ?? 0
            let label = "\(format.fourCC) \(size.width)x\(size.height) "
                + "\(Int(format.maxFPS))fps photo \(photo)w #\(index)"
            return FormatInfo(
                id: index, label: label, width: Int(size.width), height: Int(size.height),
                subtype: format.fourCC, maxFPS: format.maxFPS, maxPhotoWidth: photo)
        }
    }

    /// 12 MP 4:3 at its highest frame rate, the likeliest format for fast Bayer stills.
    public static func defaultFormat(in formats: [FormatInfo]) -> FormatInfo? {
        let photoFormats = formats.filter { $0.width == 4032 && $0.height == 3024 }
        return photoFormats.max { $0.maxFPS < $1.maxFPS } ?? formats.last
    }

    /// Rebuilds the session. The completion runs on the main queue with what the
    /// configuration really supports and the values it resolved to.
    public func configure(_ requested: CaptureConfig, completion: @escaping (CaptureOptions?) -> Void) {
        queue.async { [self] in
            let options = applyConfiguration(requested)
            DispatchQueue.main.async { completion(options) }
        }
    }

    public func start() {
        queue.async { [self] in
            guard !session.isRunning else { return }
            session.startRunning()
            guard session.isRunning else {
                Log.shared.error("Session did not start")
                return
            }
            if var options, let device {
                Log.shared.info("Streaming with \(options.config.method.label)")
                Log.shared.info(
                    "Frame timing: \(CMTimeGetSeconds(device.activeVideoMinFrameDuration)) to "
                        + "\(CMTimeGetSeconds(device.activeVideoMaxFrameDuration)) s, "
                        + "auto exposure limit \(CMTimeGetSeconds(device.activeMaxExposureDuration)) s")
                if options.config.method.isPhoto, photoDriver == nil {
                    configurePhoto(device: device, options: &options)
                    self.options = options
                    let updated = options
                    DispatchQueue.main.async { self.onOptionsChanged?(updated) }
                }
            }
            photoDriver?.start()
        }
    }

    public func stop() {
        queue.async { [self] in
            photoDriver?.stop()
            if session.isRunning { session.stopRunning() }
        }
    }

    /// Releases the camera so the probe can use it.
    public func teardown(completion: @escaping () -> Void) {
        queue.async { [self] in
            photoDriver?.stop()
            if session.isRunning { session.stopRunning() }
            removeAll()
            DispatchQueue.main.async(execute: completion)
        }
    }

    public func requestReference() {
        queue.async { [self] in photoDriver?.requestReference() }
    }

    // MARK: Manual controls

    public func setExposure(_ mode: ControlMode, seconds: Double, iso: Float) {
        withLockedDevice { device in
            switch mode {
            case .auto:
                if device.isExposureModeSupported(.continuousAutoExposure) {
                    device.exposureMode = .continuousAutoExposure
                }
            case .locked:
                let format = device.activeFormat
                let low = CMTimeGetSeconds(format.minExposureDuration)
                let high = CMTimeGetSeconds(format.maxExposureDuration)
                let duration = CMTime(seconds: min(max(seconds, low), high), preferredTimescale: 1_000_000_000)
                let clampedISO = min(max(iso, format.minISO), format.maxISO)
                device.setExposureModeCustom(duration: duration, iso: clampedISO, completionHandler: nil)
            }
        }
    }

    /// Keeps the shutter and moves ISO four times a second, to follow the camera's meter.
    public func setShutterPriority(seconds: Double, iso: Float) {
        setExposure(.locked, seconds: seconds, iso: iso)
        queue.async { [self] in
            priorityTimer?.cancel()
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + 0.25, repeating: 0.25)
            timer.setEventHandler { [weak self] in self?.stepPriorityISO() }
            timer.resume()
            priorityTimer = timer
        }
    }

    public func stopShutterPriority() {
        queue.async { [self] in
            priorityTimer?.cancel()
            priorityTimer = nil
        }
    }

    /// Runs on `queue`.
    private func stepPriorityISO() {
        guard let device, device.exposureMode == .custom else { return }
        let format = device.activeFormat
        guard let iso = ShutterPriority.nextISO(
            current: device.iso, offset: device.exposureTargetOffset, range: format.minISO...format.maxISO)
        else { return }
        withLockedDevice { device in
            device.setExposureModeCustom(
                duration: AVCaptureDevice.currentExposureDuration, iso: iso, completionHandler: nil)
        }
    }

    public func setWhiteBalance(_ mode: ControlMode, temperature: Float, tint: Float) {
        withLockedDevice { device in
            switch mode {
            case .auto:
                if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
                    device.whiteBalanceMode = .continuousAutoWhiteBalance
                }
            case .locked:
                guard device.isLockingWhiteBalanceWithCustomDeviceGainsSupported else {
                    Log.shared.warn("Custom white balance gains are not supported on this lens")
                    return
                }
                var gains = device.deviceWhiteBalanceGains(
                    for: AVCaptureDevice.WhiteBalanceTemperatureAndTintValues(
                        temperature: temperature, tint: tint))
                let limit = device.maxWhiteBalanceGain
                gains.redGain = min(max(gains.redGain, 1), limit)
                gains.greenGain = min(max(gains.greenGain, 1), limit)
                gains.blueGain = min(max(gains.blueGain, 1), limit)
                device.setWhiteBalanceModeLocked(with: gains, completionHandler: nil)
            }
        }
    }

    public func setFocus(_ mode: ControlMode, lensPosition: Float) {
        withLockedDevice { device in
            switch mode {
            case .auto:
                if device.isFocusModeSupported(.continuousAutoFocus) {
                    device.focusMode = .continuousAutoFocus
                }
            case .locked:
                guard device.isLockingFocusWithCustomLensPositionSupported else {
                    Log.shared.warn("Manual focus is not supported on this lens")
                    return
                }
                device.setFocusModeLocked(lensPosition: min(max(lensPosition, 0), 1), completionHandler: nil)
            }
        }
    }

    /// Freezes exposure where it is, which stored values could only approximate.
    public func holdExposure() {
        withLockedDevice { device in
            if device.isExposureModeSupported(.locked) {
                device.exposureMode = .locked
            }
        }
    }

    /// Freezes white balance where it is.
    public func holdWhiteBalance() {
        withLockedDevice { device in
            if device.isWhiteBalanceModeSupported(.locked) {
                device.whiteBalanceMode = .locked
            }
        }
    }

    /// Stops the lens where it is, which a stored lens position could only approximate.
    public func holdFocus() {
        withLockedDevice { device in
            if device.isFocusModeSupported(.locked) {
                device.focusMode = .locked
            }
        }
    }

    /// Runs a single autofocus at a sensor point, then holds the lens there.
    public func focus(at point: CGPoint) {
        withLockedDevice { device in
            if device.isFocusPointOfInterestSupported {
                device.focusPointOfInterest = point
            }
            if device.isFocusModeSupported(.autoFocus) {
                device.focusMode = .autoFocus
            }
        }
    }

    /// Moves auto exposure's metering to a sensor point.
    public func meter(at point: CGPoint) {
        withLockedDevice { device in
            if device.isExposurePointOfInterestSupported {
                device.exposurePointOfInterest = point
            }
            if device.isExposureModeSupported(.continuousAutoExposure) {
                device.exposureMode = .continuousAutoExposure
            }
        }
    }

    /// Offsets auto exposure at the sensor, unlike the pipeline's digital exposure offset.
    public func setExposureBias(_ stops: Float) {
        withLockedDevice { device in
            let bias = min(max(stops, device.minExposureTargetBias), device.maxExposureTargetBias)
            device.setExposureTargetBias(bias, completionHandler: nil)
        }
    }

    /// The completion runs on the session queue, and only while the session runs.
    public func liveValues(completion: @escaping (LiveCameraValues) -> Void) {
        queue.async { [self] in
            guard let device, session.isRunning else { return }
            var values = LiveCameraValues(
                iso: device.iso, seconds: CMTimeGetSeconds(device.exposureDuration),
                lensPosition: device.lensPosition)
            // Gains can be outside the range this conversion accepts.
            _ = VLTryCatch {
                let balance = device.temperatureAndTintValues(for: device.deviceWhiteBalanceGains)
                values.temperature = balance.temperature
                values.tint = balance.tint
            }
            completion(values)
        }
    }

    private func withLockedDevice(_ body: @escaping (AVCaptureDevice) -> Void) {
        queue.async { [self] in
            guard let device else { return }
            do {
                try device.lockForConfiguration()
                if let exception = VLTryCatch({ body(device) }) {
                    Log.shared.error("Device control raised: \(exception.reason ?? exception.name.rawValue)")
                }
                device.unlockForConfiguration()
            } catch {
                Log.shared.error("lockForConfiguration failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: Configuration

    private func removeAll() {
        photoDriver = nil
        videoDriver = nil
        session.beginConfiguration()
        session.inputs.forEach(session.removeInput)
        session.outputs.forEach(session.removeOutput)
        session.commitConfiguration()
        input = nil
        photoOutput = nil
        videoOutput = nil
        device = nil
    }

    private func applyConfiguration(_ requested: CaptureConfig) -> CaptureOptions? {
        photoDriver?.stop()
        if session.isRunning { session.stopRunning() }
        removeAll()

        guard let device = AVCaptureDevice(uniqueID: requested.lensID),
            device.formats.indices.contains(requested.formatIndex)
        else {
            Log.shared.error("Lens or format is not available")
            return nil
        }
        let usePhotoPreset = requested.method.isPhoto && requested.usePhotoPreset

        do {
            let input = try AVCaptureDeviceInput(device: device)
            session.beginConfiguration()
            defer { session.commitConfiguration() }
            guard session.canAddInput(input) else {
                Log.shared.error("Cannot add camera input")
                return nil
            }
            session.addInput(input)
            self.input = input
            self.device = device

            if requested.method.isPhoto {
                let output = AVCapturePhotoOutput()
                guard session.canAddOutput(output) else {
                    Log.shared.error("Cannot add photo output")
                    return nil
                }
                session.addOutput(output)
                photoOutput = output
            } else {
                let output = AVCaptureVideoDataOutput()
                output.alwaysDiscardsLateVideoFrames = true
                guard session.canAddOutput(output) else {
                    Log.shared.error("Cannot add video data output")
                    return nil
                }
                session.addOutput(output)
                videoOutput = output
            }

            if usePhotoPreset, session.canSetSessionPreset(.photo) {
                session.sessionPreset = .photo
            } else {
                session.sessionPreset = .inputPriority
                try device.lockForConfiguration()
                device.activeFormat = device.formats[requested.formatIndex]
                device.unlockForConfiguration()
            }
        } catch {
            Log.shared.error("Configure failed: \(error.localizedDescription)")
            return nil
        }

        let format = device.activeFormat
        var options = CaptureOptions(config: requested)
        options.formatDescription = format.description
        options.isoRange = format.minISO...format.maxISO
        options.shutterRange = CMTimeGetSeconds(format.minExposureDuration)...CMTimeGetSeconds(format.maxExposureDuration)
        options.maxWhiteBalanceGain = device.maxWhiteBalanceGain
        options.photoSizes = format.photoSizes

        Log.shared.info("Format: \(format.description)")
        if requested.method.isPhoto {
            applyFrameRate(device: device, format: format, options: &options)
            configurePhoto(device: device, options: &options)
        } else {
            configureVideo(device: device, format: format, options: &options)
        }
        self.options = options
        observePressure(on: device)
        return options
    }

    private func observePressure(on device: AVCaptureDevice) {
        pressureObservation = device.observe(\.systemPressureState, options: [.new]) { device, _ in
            let state = device.systemPressureState
            Log.shared.warn("Camera pressure \(state.level.rawValue), factors \(state.factors.rawValue)")
        }
    }

    /// Fixes the sensor at one frame time and keeps auto exposure inside it, so a dark scene can't
    /// slow a take. Without `fixedFrameTime`, 30 fps can stretch to 1/15 s per frame.
    private func applyFrameRate(
        device: AVCaptureDevice, format: AVCaptureDevice.Format, options: inout CaptureOptions
    ) {
        let wanted = options.config.frameRate
        let isOffered = format.videoSupportedFrameRateRanges.contains {
            $0.minFrameRate <= wanted && wanted <= $0.maxFrameRate
        }
        let fps = isOffered ? wanted : 30
        if !isOffered {
            Log.shared.warn("\(FrameRates.label(wanted)) fps is not offered by this format")
            options.frameRateUnavailable = true
        }
        options.config.frameRate = fps
        let timing = FrameRates.frameTime(fps)
        let frameTime = CMTime(value: timing.value, timescale: timing.timescale)
        let fixesFrameTime = fps < 30 || options.config.fixedFrameTime
        let correctsDistortion = options.config.distortionCorrection
        do {
            try device.lockForConfiguration()
            // The longest duration goes first, because the shortest can't pass it.
            let exception = VLTryCatch {
                if fixesFrameTime {
                    device.activeVideoMaxFrameDuration = frameTime
                    device.activeVideoMinFrameDuration = frameTime
                }
                device.activeMaxExposureDuration = frameTime
                if device.isGeometricDistortionCorrectionSupported {
                    device.isGeometricDistortionCorrectionEnabled = correctsDistortion
                    Log.shared.info("Distortion correction \(correctsDistortion ? "on" : "off")")
                }
            }
            device.unlockForConfiguration()
            if let exception {
                Log.shared.error("Frame rate \(FrameRates.label(fps)) rejected: \(exception.reason ?? exception.name.rawValue)")
            }
        } catch {
            Log.shared.error("Frame rate setup failed: \(error.localizedDescription)")
        }
    }

    private func configurePhoto(device: AVCaptureDevice, options: inout CaptureOptions) {
        guard let output = photoOutput else { return }
        output.isAppleProRAWEnabled = false
        let bayer = output.availableRawPhotoPixelFormatTypes.filter(AVCapturePhotoOutput.isBayerRAWPixelFormat)
        options.rawPhotoTypes = bayer
        options.maxBracketCount = output.maxBracketedCapturePhotoCount

        let size = options.config.photoSize.flatMap { options.photoSizes.contains($0) ? $0 : nil }
            ?? options.photoSizes.first { $0.width <= 4032 && $0.width > 2000 }
            ?? options.photoSizes.last
        guard let size else {
            Log.shared.error("Format reports no photo dimensions")
            return
        }
        options.config.photoSize = size

        guard let raw = options.config.rawPixelFormat.flatMap({ bayer.contains($0) ? $0 : nil }) ?? bayer.first else {
            let message = "No Bayer RAW photo format (preset \(session.sessionPreset.rawValue), "
                + "running \(session.isRunning)). All RAW types: ["
                + output.availableRawPhotoPixelFormatTypes.map(PixelFormats.fourCC).joined(separator: " ") + "]"
            // The list can fill in once the session runs, so only that case is a failure.
            if session.isRunning {
                Log.shared.error(message)
                options.config.rawPixelFormat = nil
            } else {
                Log.shared.info(message)
            }
            return
        }
        options.config.rawPixelFormat = raw
        options.config.bracketCount = max(1, min(options.config.bracketCount, output.maxBracketedCapturePhotoCount))

        let exception = VLTryCatch {
            output.maxPhotoDimensions = CMVideoDimensions(
                width: Int32(size.width), height: Int32(size.height))
            output.maxPhotoQualityPrioritization = .speed
            let wantsFast = options.config.method == .photoReadiness
            if output.isZeroShutterLagSupported {
                output.isZeroShutterLagEnabled = wantsFast
            }
            if output.isResponsiveCaptureSupported {
                output.isResponsiveCaptureEnabled = wantsFast
            }
            if output.isFastCapturePrioritizationSupported {
                output.isFastCapturePrioritizationEnabled = wantsFast
            }
        }
        if let exception {
            Log.shared.error("Photo output setup raised: \(exception.reason ?? exception.name.rawValue)")
        }

        Log.shared.info(
            "Photo output: raw=\(PixelFormats.fourCC(raw)) size=\(size.label) "
                + "bayerTypes=[\(bayer.map(PixelFormats.fourCC).joined(separator: " "))] "
                + "ZSL=\(output.isZeroShutterLagSupported)/\(output.isZeroShutterLagEnabled) "
                + "responsive=\(output.isResponsiveCaptureSupported)/\(output.isResponsiveCaptureEnabled) "
                + "fastPrio=\(output.isFastCapturePrioritizationSupported)/\(output.isFastCapturePrioritizationEnabled) "
                + "maxBracket=\(output.maxBracketedCapturePhotoCount)")

        let driver = PhotoRawDriver(
            output: output, device: device, method: options.config.method, rawFormat: raw,
            size: size, bracketCount: options.config.bracketCount,
            frameRate: options.config.frameRate, timing: timing)
        driver.onFrame = { [weak self] in self?.onFrame?($0) }
        driver.onFailure = { [weak self] message, shouldLog in
            if shouldLog { Log.shared.error(message) }
            self?.onCaptureFailure?(message)
        }
        driver.onReference = { [weak self] data, metadata in self?.onReference?(data, metadata) }
        photoDriver = driver
    }

    private func configureVideo(device: AVCaptureDevice, format: AVCaptureDevice.Format, options: inout CaptureOptions) {
        guard let output = videoOutput else { return }
        options.videoTypes = output.availableVideoPixelFormatTypes
        Log.shared.info("Video output types: \(options.videoTypes.map(PixelFormats.fourCC).joined(separator: " "))")

        if let pixelFormat = options.config.videoPixelFormat ?? options.videoTypes.first {
            options.config.videoPixelFormat = pixelFormat
            let exception = VLTryCatch {
                output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: pixelFormat]
            }
            if let exception {
                Log.shared.error("Video format \(PixelFormats.fourCC(pixelFormat)) rejected: \(exception.reason ?? "")")
            }
        }

        let fps = min(options.config.videoFPS, format.maxFPS)
        do {
            try device.lockForConfiguration()
            let duration = CMTime(value: 1000, timescale: CMTimeScale(fps * 1000))
            device.activeVideoMinFrameDuration = duration
            device.activeVideoMaxFrameDuration = duration
            device.unlockForConfiguration()
        } catch {
            Log.shared.error("Frame rate setup failed: \(error.localizedDescription)")
        }

        let driver = VideoDataDriver(device: device)
        driver.onFrame = { [weak self] in self?.onFrame?($0) }
        driver.onDrop = { [weak self] in self?.onCaptureDrop?($0) }
        output.setSampleBufferDelegate(driver, queue: driver.queue)
        videoDriver = driver
    }
}
