import AVFoundation
import ObjCGuard
import VLCore

/// Finds out whether the main camera can give Bayer RAW at 48mm. It captures each mix of photo
/// size, zoom and quality priority, and compares the pictures with a plain 1x frame. The result
/// goes to the log and to Documents/probes, with one DNG per mix.
public enum ZoomRawProbe {
    private static let shotsPerCase = 5
    private static let baseSize = PhotoSize(width: 4032, height: 3024)

    /// Runs on a background queue. The camera must be released first, and the scene should
    /// hold still with plenty of detail, or the comparison can't prove anything.
    public static func run(
        progress: @escaping (String) -> Void, completion: @escaping (URL) -> Void
    ) {
        DispatchQueue.global(qos: .userInitiated).async {
            var report: [String] = []
            func add(_ line: String) {
                report.append(line)
                Log.shared.info("48mm probe: \(line)")
            }

            let name = "zoom_raw_\(Storage.timestamp())"
            let folder = Storage.probes.appendingPathComponent(name)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            add("device=\(SystemStatus.deviceModel) iOS=\(ProcessInfo.processInfo.operatingSystemVersionString)")
            probe(folder: folder, progress: progress, add: add)

            let url = Storage.probes.appendingPathComponent("\(name).txt")
            do {
                try report.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
                Log.shared.info("48mm probe saved to probes/\(url.lastPathComponent)")
            } catch {
                Log.shared.error("48mm probe save failed: \(error.localizedDescription)")
            }
            DispatchQueue.main.async { completion(url) }
        }
    }

    private static func probe(folder: URL, progress: (String) -> Void, add: (String) -> Void) {
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
            add("no main camera")
            return
        }
        let session = AVCaptureSession()
        let output = AVCapturePhotoOutput()
        guard let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input),
            session.canAddOutput(output)
        else {
            add("cannot open \(device.localizedName)")
            return
        }
        session.beginConfiguration()
        session.addInput(input)
        session.addOutput(output)
        session.sessionPreset = .photo
        session.commitConfiguration()
        session.startRunning()
        defer {
            setZoom(1, on: device)
            session.stopRunning()
            session.removeInput(input)
        }
        guard session.isRunning else {
            add("session did not start")
            return
        }

        output.isAppleProRAWEnabled = false
        let format = device.activeFormat
        let bayer = output.availableRawPhotoPixelFormatTypes.filter(AVCapturePhotoOutput.isBayerRAWPixelFormat)
        let secondary = format.secondaryNativeResolutionZoomFactors.map { Double($0) }
        add("format \(format.description)")
        add("bayer=\(bayer.map(PixelFormats.fourCC)) photoSizes=\(format.photoSizes.map(\.label)) secondaryZooms=\(secondary)")
        guard let raw = bayer.first else {
            add("no Bayer RAW type")
            return
        }

        let sizes = [baseSize] + format.photoSizes.filter { $0.width > baseSize.width }
        let priorities: [AVCapturePhotoOutput.QualityPrioritization] = [.speed, .quality]
        var reference: ZoomRawShot?
        for size in sizes {
            for zoom in [1] + secondary {
                for priority in priorities {
                    let label = "\(size.label) zoom \(zoom) \(priority == .speed ? "speed" : "quality")"
                    progress("48mm probe: \(label)")
                    setZoom(zoom, on: device)
                    if let exception = prepare(output, size: size, priority: priority) {
                        add("\(label): setup raised \(exception.reason ?? exception.name.rawValue)")
                        continue
                    }
                    Thread.sleep(forTimeInterval: 0.5)
                    let dng = folder.appendingPathComponent(
                        "\(size.width)_x\(zoom)_\(priority == .speed ? "speed" : "quality").dng")
                    let shots = capture(
                        output, raw: raw, size: size, priority: priority, dng: dng, label: label, add: add)
                    guard let shot = shots.last else { continue }
                    reference = reference ?? shot
                    add("\(label) at zoom \(device.videoZoomFactor): \(shot.summary) "
                        + "gaps=\(gaps(shots)) ms \(compare(shot, with: reference))")
                }
            }
        }
    }

    private static func setZoom(_ zoom: Double, on device: AVCaptureDevice) {
        guard (try? device.lockForConfiguration()) != nil else { return }
        defer { device.unlockForConfiguration() }
        _ = VLTryCatch { device.videoZoomFactor = CGFloat(zoom) }
    }

    /// Matches the capture settings of `PhotoRawDriver`, apart from the size and priority.
    private static func prepare(
        _ output: AVCapturePhotoOutput, size: PhotoSize,
        priority: AVCapturePhotoOutput.QualityPrioritization
    ) -> NSException? {
        VLTryCatch {
            output.maxPhotoDimensions = CMVideoDimensions(
                width: Int32(size.width), height: Int32(size.height))
            output.maxPhotoQualityPrioritization = priority
            if output.isZeroShutterLagSupported { output.isZeroShutterLagEnabled = true }
            if output.isResponsiveCaptureSupported { output.isResponsiveCaptureEnabled = true }
            if output.isFastCapturePrioritizationSupported { output.isFastCapturePrioritizationEnabled = true }
        }
    }

    /// Takes one photo at a time, so the gaps aren't the rate of the recording loop.
    private static func capture(
        _ output: AVCapturePhotoOutput, raw: OSType, size: PhotoSize,
        priority: AVCapturePhotoOutput.QualityPrioritization, dng: URL, label: String,
        add: (String) -> Void
    ) -> [ZoomRawShot] {
        var shots: [ZoomRawShot] = []
        for index in 0..<shotsPerCase {
            let settings = AVCapturePhotoSettings(rawPixelFormatType: raw)
            settings.maxPhotoDimensions = CMVideoDimensions(
                width: Int32(size.width), height: Int32(size.height))
            // RAW refuses quality prioritization on iOS 27, with an exception that ends the app.
            if let exception = VLTryCatch({ settings.photoQualityPrioritization = priority }) {
                add("\(label): settings raised \(exception.reason ?? exception.name.rawValue)")
                break
            }
            settings.flashMode = .off
            if #available(iOS 18.0, *), output.isShutterSoundSuppressionSupported {
                settings.isShutterSoundSuppressionEnabled = true
            }
            let catcher = ZoomRawCatcher(dng: index == 0 ? dng : nil)
            if let exception = VLTryCatch({ output.capturePhoto(with: settings, delegate: catcher) }) {
                add("\(label): capturePhoto raised \(exception.reason ?? exception.name.rawValue)")
                break
            }
            guard catcher.wait() else {
                add("\(label): no answer from the camera")
                break
            }
            if let shot = catcher.shot {
                shots.append(shot)
            } else {
                add("\(label): \(catcher.failure ?? "no photo")")
            }
        }
        return shots
    }

    private static func gaps(_ shots: [ZoomRawShot]) -> [Int] {
        zip(shots.dropFirst(), shots).map { Int((($0.time - $1.time) * 1000).rounded()) }
    }

    private static func compare(_ shot: ZoomRawShot, with reference: ZoomRawShot?) -> String {
        guard let reference, let map = shot.whole, let referenceMap = reference.whole,
            let referenceCenter = reference.center
        else { return "field=no map" }
        let whole = FieldOfView.correlation(map, referenceMap)
        let center = FieldOfView.correlation(map, referenceCenter)
        let field = FieldOfView.match(whole: whole, center: center)
        return "whole=\(score(whole)) center=\(score(center)) field=\(field.rawValue)"
    }

    private static func score(_ value: Double?) -> String {
        value.map { String(format: "%.3f", $0) } ?? "-"
    }
}

private struct ZoomRawShot {
    var summary: String
    var time: Double
    var whole: [Double]?
    var center: [Double]?
}

private final class ZoomRawCatcher: NSObject, AVCapturePhotoCaptureDelegate {
    private let finished = DispatchSemaphore(value: 0)
    private let dng: URL?
    private(set) var shot: ZoomRawShot?
    private(set) var failure: String?

    init(dng: URL?) {
        self.dng = dng
    }

    func wait() -> Bool {
        finished.wait(timeout: .now() + 10) == .success
    }

    func photoOutput(
        _ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto,
        error: Error?
    ) {
        if let error {
            failure = "photo failed: \(error.localizedDescription)"
            return
        }
        guard let buffer = photo.pixelBuffer else {
            failure = "photo has no pixelBuffer (isRawPhoto=\(photo.isRawPhoto))"
            return
        }
        let exif = photo.metadata["{Exif}"] as? [String: Any] ?? [:]
        let dimensions = photo.resolvedSettings.rawPhotoDimensions
        let summary = "got \(CVPixelBufferGetWidth(buffer))x\(CVPixelBufferGetHeight(buffer)) "
            + "\(PixelFormats.fourCC(CVPixelBufferGetPixelFormatType(buffer))) "
            + "resolved=\(dimensions.width)x\(dimensions.height) "
            + "35mm=\(exif["FocalLenIn35mmFilm"] ?? "-") digitalZoom=\(exif["DigitalZoomRatio"] ?? "-")"
        shot = ZoomRawShot(
            summary: summary, time: CMTimeGetSeconds(photo.timestamp),
            whole: FieldOfView.map(buffer), center: FieldOfView.map(buffer, fraction: 0.5))
        if let dng, let data = photo.fileDataRepresentation() {
            do {
                try data.write(to: dng)
            } catch {
                Log.shared.error("48mm probe DNG failed: \(error.localizedDescription)")
            }
        }
    }

    func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings, error: Error?
    ) {
        finished.signal()
    }
}
