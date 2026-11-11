import AVFoundation
import ImageIO
import ObjCGuard
import VLCore

/// Reports everything the device exposes about RAW capture. The result goes to the
/// log and to Documents/probes.
public enum CaptureProbe {
    private static let rawPattern =
        "raw|bayer|sensor|unprocessed|bypass|demosaic|debayer|isp|proRes|cinema"

    /// Runs on a background queue. The camera must be released first.
    public static func run(
        progress: @escaping (String) -> Void, completion: @escaping (URL) -> Void
    ) {
        DispatchQueue.global(qos: .userInitiated).async {
            var report: [String] = []
            func add(_ line: String) {
                report.append(line)
                print(line)
            }

            add("VibeLog probe \(Storage.timestamp())")
            add("device=\(SystemStatus.deviceModel) iOS=\(ProcessInfo.processInfo.operatingSystemVersionString)")

            let devices = AVCaptureDevice.DiscoverySession(
                deviceTypes: [
                    .builtInWideAngleCamera, .builtInUltraWideCamera, .builtInTelephotoCamera,
                    .builtInDualCamera, .builtInDualWideCamera, .builtInTripleCamera,
                    .builtInLiDARDepthCamera, .builtInTrueDepthCamera,
                ],
                mediaType: .video, position: .unspecified
            ).devices

            for device in devices {
                progress("Probing \(device.localizedName)")
                add("")
                add("=== \(device.localizedName) type=\(device.deviceType.rawValue) "
                    + "position=\(device.position.rawValue) formats=\(device.formats.count) "
                    + "virtual=\(device.isVirtualDevice) "
                    + "constituents=\(device.constituentDevices.map(\.localizedName))")
                let isRearPhysical = device.position == .back && !device.isVirtualDevice
                for (index, format) in device.formats.enumerated() {
                    add("[\(index)] \(format.description)")
                    add("    photoDims=\(format.photoSizes.map(\.label)) "
                        + "extensions=\(extensions(of: format))")
                }
                if isRearPhysical {
                    add("--- RAW availability by session setup")
                    probeRawMatrix(device: device, add: add)
                    add("--- per-format output capabilities")
                    probeOutputs(device: device, add: add)
                }
            }

            progress("Probing lens calibration")
            add("")
            add("=== lens calibration: what each rear camera hands over per photo")
            for device in devices where device.position == .back {
                for raw in [true, false] { probeCalibration(device: device, raw: raw).forEach(add) }
            }

            progress("Probing lens stabilization")
            add("")
            add("=== lens stabilization: whether a RAW bracket can switch the optical stabilizer")
            for device in devices where device.position == .back && !device.isVirtualDevice {
                probeLensStabilization(device: device).forEach(add)
            }

            progress("Scanning AVCapture runtime")
            add("")
            add("=== runtime members matching /\(rawPattern)/i on AVCapture* classes")
            VLRuntimeScan("AVCapture", rawPattern).forEach(add)

            let url = Storage.probes.appendingPathComponent("probe_\(Storage.timestamp()).txt")
            do {
                try report.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
                Log.shared.info("Probe saved to probes/\(url.lastPathComponent) (\(report.count) lines)")
            } catch {
                Log.shared.error("Probe save failed: \(error.localizedDescription)")
            }
            DispatchQueue.main.async { completion(url) }
        }
    }

    private static func extensions(of format: AVCaptureDevice.Format) -> String {
        guard let values = CMFormatDescriptionGetExtensions(format.formatDescription) else {
            return "{}"
        }
        return String(describing: values).replacingOccurrences(of: "\n", with: " ")
    }

    /// RAW lists depend on the session, so this tries each preset with and without a
    /// video output, before and after the session starts.
    private static func probeRawMatrix(device: AVCaptureDevice, add: (String) -> Void) {
        let largest = device.formats.last { format in
            CMVideoFormatDescriptionGetDimensions(format.formatDescription).width == 4032
        }
        for usePhotoPreset in [true, false] {
            for addVideo in [false, true] {
                let session = AVCaptureSession()
                let photo = AVCapturePhotoOutput()
                let video = AVCaptureVideoDataOutput()
                guard let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) else {
                    add("cannot open \(device.localizedName)")
                    return
                }
                session.beginConfiguration()
                session.addInput(input)
                if session.canAddOutput(photo) { session.addOutput(photo) }
                if addVideo, session.canAddOutput(video) { session.addOutput(video) }
                if usePhotoPreset {
                    session.sessionPreset = .photo
                } else {
                    session.sessionPreset = .inputPriority
                    if let largest, (try? device.lockForConfiguration()) != nil {
                        device.activeFormat = largest
                        device.unlockForConfiguration()
                    }
                }
                session.commitConfiguration()

                let setup = "preset=\(usePhotoPreset ? "photo" : "inputPriority") videoOutput=\(addVideo)"
                add(rawLine(setup + " running=false", device: device, photo: photo))
                if addVideo {
                    add("    video=\(names(video.availableVideoPixelFormatTypes)) "
                        + "forcedVideoOK=\(forcedVideoFormats(video, extra: photo.availableRawPhotoPixelFormatTypes))")
                }
                session.startRunning()
                let line = rawLine(setup + " running=\(session.isRunning)", device: device, photo: photo)
                add(line)
                Log.shared.info("\(device.localizedName) \(line)")
                session.stopRunning()
                session.removeInput(input)
            }
        }
    }

    /// Tries Bayer formats on the video output, which raises when one is refused.
    private static func forcedVideoFormats(_ video: AVCaptureVideoDataOutput, extra: [OSType]) -> [String] {
        var accepted: [String] = []
        for candidate in PixelFormats.forcedVideoCandidates + extra {
            let name = PixelFormats.fourCC(candidate)
            let failure = VLTryCatch {
                video.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: candidate]
            }
            if failure == nil, !accepted.contains(name) {
                accepted.append(name)
            }
        }
        _ = VLTryCatch { video.videoSettings = [:] }
        return accepted
    }

    private static func rawLine(_ setup: String, device: AVCaptureDevice, photo: AVCapturePhotoOutput) -> String {
        let raw = photo.availableRawPhotoPixelFormatTypes
        let bayer = raw.filter(AVCapturePhotoOutput.isBayerRAWPixelFormat)
        let size = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
        return "\(setup) active=\(device.activeFormat.fourCC) \(size.width)x\(size.height) "
            + "bayer=\(names(bayer)) allRaw=\(names(raw)) "
            + "rawFiles=\(photo.availableRawPhotoFileTypes.map(\.rawValue)) "
            + "proRAWSupported=\(photo.isAppleProRAWSupported) "
            + "ZSL=\(photo.isZeroShutterLagSupported) responsive=\(photo.isResponsiveCaptureSupported) "
            + "demosaicedRaw=\(privateValue(photo, "isDemosaicedRawSupported"))"
    }

    /// Reads a private getter named in the runtime scan, for logging only.
    private static func privateValue(_ object: NSObject, _ key: String) -> String {
        guard object.responds(to: NSSelectorFromString(key)) else { return "n/a" }
        var text = "nil"
        let exception = VLTryCatch {
            if let value = object.value(forKey: key) { text = String(describing: value) }
        }
        return exception == nil ? text : "raised"
    }

    private static func fourCCValue(_ object: NSObject, _ key: String) -> String {
        let text = privateValue(object, key)
        return UInt32(text).map { PixelFormats.fourCC($0) } ?? text
    }

    private static func probeOutputs(device: AVCaptureDevice, add: (String) -> Void) {
        let session = AVCaptureSession()
        let photo = AVCapturePhotoOutput()
        let video = AVCaptureVideoDataOutput()
        guard let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) else {
            add("cannot open \(device.localizedName)")
            return
        }
        session.beginConfiguration()
        session.addInput(input)
        if session.canAddOutput(photo) { session.addOutput(photo) }
        if session.canAddOutput(video) { session.addOutput(video) }
        session.sessionPreset = .inputPriority
        session.commitConfiguration()
        defer { session.removeInput(input) }

        var seen = Set<String>()
        var seenBayer = Set<String>()
        for (index, format) in device.formats.enumerated() {
            let size = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            let key = "\(format.fourCC)-\(size.width)x\(size.height)-\(format.maxFPS)"
            guard seen.insert(key).inserted else { continue }

            let exception = VLTryCatch {
                session.beginConfiguration()
                if (try? device.lockForConfiguration()) != nil {
                    device.activeFormat = format
                    device.unlockForConfiguration()
                }
                session.commitConfiguration()
            }
            if let exception {
                add("[\(index)] \(key) activeFormat raised: \(exception.reason ?? "")")
                continue
            }

            let raw = photo.availableRawPhotoPixelFormatTypes
            let bayer = raw.filter(AVCapturePhotoOutput.isBayerRAWPixelFormat)
            let proRAW = raw.filter(AVCapturePhotoOutput.isAppleProRAWPixelFormat)
            bayer.forEach { seenBayer.insert(PixelFormats.fourCC($0)) }

            let accepted = forcedVideoFormats(video, extra: bayer)

            add("[\(index)] \(key) bayer=\(names(bayer)) proRAW=\(names(proRAW)) "
                + "video=\(names(video.availableVideoPixelFormatTypes)) forcedVideoOK=\(accepted) "
                + "maxBracket=\(photo.maxBracketedCapturePhotoCount) "
                + "ZSL=\(photo.isZeroShutterLagSupported) "
                + "responsive=\(photo.isResponsiveCaptureSupported) "
                + "fastPrio=\(photo.isFastCapturePrioritizationSupported) "
                + "maxPhoto=\(format.photoSizes.map(\.label).last ?? "-") "
                + "colorSpaces=\(format.supportedColorSpaces.map(\.rawValue)) "
                + "highestPhotoQuality=\(format.isHighestPhotoQualitySupported) "
                + "privRaw=\(fourCCValue(format, "supportedRawPixelFormat")) "
                + "privDemosaiced=\(fourCCValue(format, "supportedDemosaicedRawPixelFormat")) "
                + "privDemosaicedOK=\(privateValue(format, "isDemosaicedRawSupported")) "
                + "privPhotoFormat=\(privateValue(format, "isPhotoFormat")) "
                + "privSensor=\(privateValue(format, "sensorDimensions"))")
        }
        Log.shared.info("\(device.localizedName): Bayer photo types \(seenBayer.sorted())")
    }

    /// Whether a photo comes with Apple's factory calibration: the focal length in pixels, the
    /// optical centre and the lens distortion table, which a per-phone lens profile needs. It's
    /// documented for virtual cameras and depth, so each camera tries it with and without RAW.
    private static func probeCalibration(device: AVCaptureDevice, raw: Bool) -> [String] {
        let session = AVCaptureSession()
        let photo = AVCapturePhotoOutput()
        guard let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) else {
            return ["\(device.localizedName) raw=\(raw): cannot open"]
        }
        session.beginConfiguration()
        session.addInput(input)
        if session.canAddOutput(photo) { session.addOutput(photo) }
        session.sessionPreset = .photo
        session.commitConfiguration()
        // The output only offers these once it's in a session, and raises if set unsupported.
        if photo.isVirtualDeviceConstituentPhotoDeliverySupported {
            _ = VLTryCatch { photo.isVirtualDeviceConstituentPhotoDeliveryEnabled = true }
        }
        if !raw, photo.isDepthDataDeliverySupported {
            _ = VLTryCatch { photo.isDepthDataDeliveryEnabled = true }
        }
        session.startRunning()
        defer {
            session.stopRunning()
            session.removeInput(input)
        }

        let format = device.activeFormat
        let size = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
        var lines = ["\(device.localizedName) raw=\(raw) active \(size.width)x\(size.height) "
            + "calibrationSupported=\(photo.isCameraCalibrationDataDeliverySupported) "
            + "constituents=\(photo.isVirtualDeviceConstituentPhotoDeliveryEnabled) "
            + "depth=\(photo.isDepthDataDeliveryEnabled) "
            + "fov=\(format.videoFieldOfView) correctedFov=\(format.geometricDistortionCorrectedVideoFieldOfView)"]

        let settings: AVCapturePhotoSettings
        if raw {
            guard let bayer = photo.availableRawPhotoPixelFormatTypes.first(where: AVCapturePhotoOutput.isBayerRAWPixelFormat)
            else { return lines + ["    no Bayer RAW here"] }
            settings = AVCapturePhotoSettings(rawPixelFormatType: bayer)
        } else {
            settings = AVCapturePhotoSettings()
        }
        if photo.isVirtualDeviceConstituentPhotoDeliveryEnabled {
            settings.virtualDeviceConstituentPhotoDeliveryEnabledDevices = device.constituentDevices
        }
        settings.isDepthDataDeliveryEnabled = photo.isDepthDataDeliveryEnabled
        settings.isCameraCalibrationDataDeliveryEnabled = photo.isCameraCalibrationDataDeliverySupported

        let catcher = CalibrationCatcher()
        if let raised = VLTryCatch({ photo.capturePhoto(with: settings, delegate: catcher) }) {
            return lines + ["    capture raised: \(raised.reason ?? "")"]
        }
        if catcher.done.wait(timeout: .now() + 10) == .timedOut { lines.append("    timed out") }
        return lines + catcher.lines
    }

    /// Collects what each delivered photo carries, which for a virtual camera may be several.
    private final class CalibrationCatcher: NSObject, AVCapturePhotoCaptureDelegate {
        let done = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var collected: [String] = []
        var lines: [String] {
            lock.lock()
            defer { lock.unlock() }
            return collected
        }

        private func append(_ line: String) {
            lock.lock()
            collected.append(line)
            lock.unlock()
        }

        func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
            let exif = photo.metadata[kCGImagePropertyExifDictionary as String] as? [String: Any]
            var line = "    photo from \(photo.sourceDeviceType?.rawValue ?? "?") raw=\(photo.isRawPhoto) "
                + "focal=\(exif?[kCGImagePropertyExifFocalLength as String] ?? "-") mm "
                + "35mm=\(exif?[kCGImagePropertyExifFocalLenIn35mmFilm as String] ?? "-")"
            if let error { line += " error \((error as NSError).code)" }
            guard let calibration = photo.cameraCalibrationData ?? photo.depthData?.cameraCalibrationData else {
                append(line + " calibration none")
                return
            }
            let k = calibration.intrinsicMatrix
            let table = calibration.lensDistortionLookupTable.map { data in
                data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
            } ?? []
            append(line + " calibration yes")
            append("      intrinsics fx \(k.columns.0.x) fy \(k.columns.1.y) cx \(k.columns.2.x) cy \(k.columns.2.y) "
                + "for \(calibration.intrinsicMatrixReferenceDimensions), pixel \(calibration.pixelSize) mm, "
                + "distortion centre \(calibration.lensDistortionCenter)")
            append("      distortion table \(table.count) values: \(table.map { String(format: "%.5f", $0) }.joined(separator: " "))")
        }

        func photoOutput(_ output: AVCapturePhotoOutput, didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings, error: Error?) {
            if let error { append("    capture ended with error \((error as NSError).code)") }
            done.signal()
        }
    }

    /// Whether the optical stabilizer can be switched for Bayer RAW. The only public switch is a
    /// bracket's `isLensStabilizationEnabled`, so each lens takes plain RAW photos as the app's
    /// stream does, then brackets of one and of three with it off and on, one request at a time.
    /// Each line gives what the photos said of the stabilizer and how far apart they came, which
    /// shows whether a bracket could feed a 30 fps stream. One at a time, brackets left 133 ms
    /// between them on an iPhone 16, so a lens with the switch then tries brackets that overlap,
    /// the next asked for before the last ends, and the largest bracket, with it off.
    private static func probeLensStabilization(device: AVCaptureDevice) -> [String] {
        let session = AVCaptureSession()
        let photo = AVCapturePhotoOutput()
        guard let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) else {
            return ["\(device.localizedName): cannot open"]
        }
        session.beginConfiguration()
        session.addInput(input)
        if session.canAddOutput(photo) { session.addOutput(photo) }
        session.sessionPreset = .photo
        session.commitConfiguration()
        session.startRunning()
        defer {
            session.stopRunning()
            session.removeInput(input)
        }

        var lines = ["\(device.localizedName) switchSupported=\(photo.isLensStabilizationDuringBracketedCaptureSupported) "
            + "maxBracket=\(photo.maxBracketedCapturePhotoCount)"]
        guard let bayer = photo.availableRawPhotoPixelFormatTypes.first(where: AVCapturePhotoOutput.isBayerRAWPixelFormat)
        else { return lines + ["    no Bayer RAW here"] }
        // Exposure settles first, so the first case isn't slowed by it.
        Thread.sleep(forTimeInterval: 1)

        var cases: [(name: String, count: Int, stabilized: Bool?, requests: Int, inFlight: Int)] = [
            ("plain RAW", 0, nil, 8, 1),
            ("bracket of 1, stabilizer off", 1, false, 8, 1),
            ("bracket of 1, stabilizer on", 1, true, 8, 1),
            ("bracket of 3, stabilizer off", 3, false, 3, 1),
            ("bracket of 3, stabilizer on", 3, true, 3, 1),
        ]
        if photo.isLensStabilizationDuringBracketedCaptureSupported {
            let most = photo.maxBracketedCapturePhotoCount
            cases += [
                ("plain RAW, 2 in flight", 0, nil, 24, 2),
                ("bracket of 1, off, 2 in flight", 1, false, 24, 2),
                ("bracket of 1, off, 4 in flight", 1, false, 24, 4),
                ("bracket of 3, off, 2 in flight", 3, false, 8, 2),
                ("bracket of \(most), off, one at a time", most, false, 3, 1),
                ("bracket of \(most), off, 2 in flight", most, false, 4, 2),
                ("bracket of \(most), on, 2 in flight", most, true, 4, 2),
            ]
        }
        for test in cases {
            let catcher = StabilizationCatcher(inFlight: test.inFlight)
            var failure: String?
            let started = Date()
            for _ in 0..<test.requests {
                // A request waits for a free place, so no more than `inFlight` are out at once.
                if catcher.places.wait(timeout: .now() + 5) == .timedOut {
                    failure = "timed out"
                    break
                }
                let raised = VLTryCatch {
                    let settings: AVCapturePhotoSettings
                    if test.count == 0 {
                        settings = AVCapturePhotoSettings(rawPixelFormatType: bayer)
                    } else {
                        let exposures = (0..<test.count).map { _ in
                            AVCaptureAutoExposureBracketedStillImageSettings.autoExposureSettings(exposureTargetBias: 0)
                        }
                        let bracket = AVCapturePhotoBracketSettings(
                            rawPixelFormatType: bayer, processedFormat: nil, bracketedSettings: exposures)
                        if let stabilized = test.stabilized { bracket.isLensStabilizationEnabled = stabilized }
                        settings = bracket
                    }
                    photo.capturePhoto(with: settings, delegate: catcher)
                }
                if let raised {
                    catcher.places.signal()
                    failure = "raised: \(raised.reason ?? "")"
                    break
                }
            }
            // Every place free again means every request has ended.
            for _ in 0..<test.inFlight where catcher.places.wait(timeout: .now() + 5) == .timedOut {
                failure = failure ?? "timed out at the end"
            }
            let seconds = Date().timeIntervalSince(started)
            lines.append("    \(test.name): \(catcher.summary) in \(String(format: "%.2f", seconds)) s"
                + (failure.map { ", \($0)" } ?? ""))
        }
        return lines
    }

    /// Collects each photo's time, size and what it says the stabilizer did.
    private final class StabilizationCatcher: NSObject, AVCapturePhotoCaptureDelegate {
        /// One place for each request allowed out at once, given back as each ends.
        let places: DispatchSemaphore
        private let lock = NSLock()
        private var times: [Double] = []
        private var statuses: [String: Int] = [:]
        private var sizes: Set<String> = []
        private var errors: [Int] = []

        init(inFlight: Int) {
            // Made empty and then filled: a semaphore freed below the value it was made with
            // traps, which ended the app on the 14 Pro when a photo never came back.
            places = DispatchSemaphore(value: 0)
            for _ in 0..<inFlight { places.signal() }
        }

        var summary: String {
            lock.lock()
            defer { lock.unlock() }
            let sorted = times.sorted()
            let gaps = zip(sorted.dropFirst(), sorted).map { String(format: "%.0f", ($0 - $1) * 1000) }
            // The rate the photos' own times give, first to last, which is what a take would see.
            let span = (sorted.last ?? 0) - (sorted.first ?? 0)
            let rate = span > 0 ? String(format: " at %.1f fps", Double(sorted.count - 1) / span) : ""
            return "\(times.count) photos\(rate) \(sizes.sorted().joined(separator: " ")), "
                + "stabilizer \(statuses.sorted { $0.key < $1.key }.map { "\($0.key) x\($0.value)" }.joined(separator: " ")), "
                + "gaps ms [\(gaps.joined(separator: " "))]"
                + (errors.isEmpty ? "" : ", errors \(errors)")
        }

        func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
            let status: String
            switch photo.lensStabilizationStatus {
            case .unsupported: status = "unsupported"
            case .off: status = "off"
            case .active: status = "active"
            case .outOfRange: status = "outOfRange"
            case .unavailable: status = "unavailable"
            @unknown default: status = "unknown"
            }
            lock.lock()
            defer { lock.unlock() }
            if let error { errors.append((error as NSError).code) }
            statuses[status, default: 0] += 1
            guard error == nil else { return }
            times.append(photo.timestamp.seconds)
            if let buffer = photo.pixelBuffer {
                sizes.insert("\(CVPixelBufferGetWidth(buffer))x\(CVPixelBufferGetHeight(buffer))")
            }
        }

        func photoOutput(_ output: AVCapturePhotoOutput, didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings, error: Error?) {
            lock.lock()
            if let error { errors.append((error as NSError).code) }
            lock.unlock()
            places.signal()
        }
    }

    private static func names(_ types: [OSType]) -> String {
        "[" + types.map(PixelFormats.fourCC).joined(separator: " ") + "]"
    }
}
