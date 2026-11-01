import AVFoundation
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
                    add("--- per-format output capabilities")
                    probeOutputs(device: device, add: add)
                }
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

            var accepted: [String] = []
            for candidate in PixelFormats.forcedVideoCandidates + bayer {
                let name = PixelFormats.fourCC(candidate)
                let failure = VLTryCatch {
                    video.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: candidate]
                }
                if failure == nil, !accepted.contains(name) {
                    accepted.append(name)
                }
            }
            _ = VLTryCatch { video.videoSettings = [:] }

            add("[\(index)] \(key) bayer=\(names(bayer)) proRAW=\(names(proRAW)) "
                + "video=\(names(video.availableVideoPixelFormatTypes)) forcedVideoOK=\(accepted) "
                + "maxBracket=\(photo.maxBracketedCapturePhotoCount) "
                + "ZSL=\(photo.isZeroShutterLagSupported) "
                + "responsive=\(photo.isResponsiveCaptureSupported) "
                + "fastPrio=\(photo.isFastCapturePrioritizationSupported) "
                + "maxPhoto=\(format.photoSizes.map(\.label).last ?? "-") "
                + "colorSpaces=\(format.supportedColorSpaces.map(\.rawValue)) "
                + "highestPhotoQuality=\(format.isHighestPhotoQualitySupported)")
        }
        Log.shared.info("\(device.localizedName): Bayer photo types \(seenBayer.sorted())")
    }

    private static func names(_ types: [OSType]) -> String {
        "[" + types.map(PixelFormats.fourCC).joined(separator: " ") + "]"
    }
}
