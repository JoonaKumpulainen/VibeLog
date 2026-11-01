import AVFoundation
import VLCore
import VideoToolbox

/// Measures what each codec, pixel format and size can do on this device, using synthetic
/// frames and no camera. It reports how fast each one encodes when nothing else is running.
public enum EncoderProbe {
    private static let frameCount = 45

    public static func run(progress: @escaping (String) -> Void, completion: @escaping (URL) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            var report = ["VibeLog encoder test \(Storage.timestamp())", "device=\(SystemStatus.deviceModel)", ""]
            report += encoderList()
            report.append("")
            report.append("preset, size, encoded fps, MB/s at 30 fps, result")
            for size in EncoderSize.all {
                for preset in EncoderPreset.all {
                    progress("\(preset.label) \(size.label)")
                    let line = "\(preset.label), \(size.label), \(measure(preset, size))"
                    report.append(line)
                    Log.shared.info("Encoder test: \(line)")
                }
            }
            let url = Storage.probes.appendingPathComponent("encoders_\(Storage.timestamp()).txt")
            try? report.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
            DispatchQueue.main.async { completion(url) }
        }
    }

    /// Lists the encoders and HEVC or ProRes profiles VideoToolbox reports.
    private static func encoderList() -> [String] {
        var lines: [String] = []
        var list: CFArray?
        if VTCopyVideoEncoderList(nil, &list) == noErr, let encoders = list as? [[String: Any]] {
            for encoder in encoders {
                let codec = (encoder[kVTVideoEncoderList_CodecType as String] as? NSNumber)?.uint32Value ?? 0
                lines.append("encoder \(PixelFormats.fourCC(codec)) \(encoder[kVTVideoEncoderList_EncoderID as String] ?? "?") \(encoder)"
                    .replacingOccurrences(of: "\n", with: " "))
            }
        } else {
            lines.append("VTCopyVideoEncoderList failed")
        }
        for codec in [kCMVideoCodecType_HEVC, kCMVideoCodecType_AppleProRes422HQ, kCMVideoCodecType_AppleProRes4444] {
            var properties: CFDictionary?
            var encoderID: CFString?
            let status = VTCopySupportedPropertyDictionaryForEncoder(
                width: 4032, height: 3024, codecType: codec, encoderSpecification: nil,
                encoderIDOut: &encoderID, supportedPropertiesOut: &properties)
            let values = properties as? [String: Any]
            let profile = values?[kVTCompressionPropertyKey_ProfileLevel as String] ?? "none"
            lines.append("properties \(PixelFormats.fourCC(codec)) status \(status) encoder \(encoderID as String? ?? "?") profiles \(profile)"
                .replacingOccurrences(of: "\n", with: " "))
        }
        return lines
    }

    private static func measure(_ preset: EncoderPreset, _ size: EncoderSize) -> String {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("encoder_test.mov")
        defer { try? FileManager.default.removeItem(at: url) }
        let encoder: VideoEncoder
        do {
            encoder = try VideoEncoder(config: .init(
                url: url, preset: preset, size: size, audio: false, realTime: false))
        } catch {
            return "0, 0, rejected: \(error)"
        }

        var frames: [CVPixelBuffer] = []
        for index in 0..<3 {
            guard let buffer = encoder.nextPixelBuffer() else { return "0, 0, no pixel buffer" }
            fill(buffer, seed: index)
            frames.append(buffer)
        }

        let start = Date()
        for index in 0..<frameCount {
            encoder.append(frames[index % frames.count], at: CMTime(value: Int64(index), timescale: 30))
        }
        let done = DispatchSemaphore(value: 0)
        var result: VideoEncoder.Result?
        encoder.finish { finished in
            result = finished
            done.signal()
        }
        guard done.wait(timeout: .now() + 120) == .success, let result else {
            return "0, 0, timed out"
        }
        let elapsed = Date().timeIntervalSince(start)
        return String(
            format: "%.1f, %.0f, %@", Double(result.framesWritten) / elapsed,
            result.megabytes / (Double(frameCount) / 30),
            result.failure.map { "failed: \($0)" } ?? "ok \(result.framesWritten) frames")
    }

    /// Writes a moving gradient with light noise, in-range for 10-bit video.
    private static func fill(_ buffer: CVPixelBuffer, seed: Int) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        var noise = UInt32(truncatingIfNeeded: seed &* 2_654_435_761 &+ 1)
        for plane in 0..<CVPixelBufferGetPlaneCount(buffer) {
            guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, plane) else { continue }
            let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, plane)
            let rows = CVPixelBufferGetHeightOfPlane(buffer, plane)
            let columns = stride / 2
            for y in 0..<rows {
                let row = (base + y * stride).assumingMemoryBound(to: UInt16.self)
                for x in 0..<columns {
                    noise = noise &* 1_664_525 &+ 1_013_904_223
                    let wave = (x &* 3 &+ y &* 5 &+ seed &* 40) & 511
                    let value = 256 + wave + Int((noise >> 28) & 15)
                    row[x] = UInt16(value) << 6
                }
            }
        }
    }
}
