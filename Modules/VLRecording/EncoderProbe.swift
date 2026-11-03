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
            // The two 16-bit trials also report whether the file kept more than 10 bits.
            let presets = EncoderPreset.all + [
                EncoderPreset.all.first { $0.id == "prores4444" }?.twelveBit, EncoderPreset.hevc444From16Bit,
            ].compactMap { $0 }
            for size in EncoderSize.all {
                for preset in presets {
                    progress("\(preset.label) \(size.label)")
                    let line = "\(preset.label) \(preset.bitDepth)-bit input, \(size.label), \(measure(preset, size))"
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
        let packed = preset.pixelFormat == kCVPixelFormatType_4444AYpCbCr16
        let depth = packed && result.failure == nil ? ", \(keptDepth(url))" : ""
        return String(
            format: "%.1f, %.0f, %@%@", Double(result.framesWritten) / elapsed,
            result.megabytes / (Double(frameCount) / 30),
            result.failure.map { "failed: \($0)" } ?? "ok \(result.framesWritten) frames", depth)
    }

    /// Reads the first frame back as 16-bit and looks for luma steps finer than 10 bits, which
    /// `fill` writes into packed buffers. A file that kept only 10 bits has none.
    private static func keptDepth(_ url: URL) -> String {
        let done = DispatchSemaphore(value: 0)
        var answer = "depth unread"
        Task {
            defer { done.signal() }
            do {
                let asset = AVURLAsset(url: url)
                guard let track = try await asset.loadTracks(withMediaType: .video).first else {
                    answer = "depth: no track"
                    return
                }
                let reader = try AVAssetReader(asset: asset)
                let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_4444AYpCbCr16,
                ])
                reader.add(output)
                guard reader.startReading(), let sample = output.copyNextSampleBuffer(),
                    let image = CMSampleBufferGetImageBuffer(sample)
                else {
                    answer = "depth: unreadable"
                    return
                }
                CVPixelBufferLockBaseAddress(image, .readOnly)
                defer { CVPixelBufferUnlockBaseAddress(image, .readOnly) }
                guard let base = CVPixelBufferGetBaseAddress(image) else { return }
                let stride = CVPixelBufferGetBytesPerRow(image)
                var fine = 0
                var total = 0
                for y in Swift.stride(from: 0, to: CVPixelBufferGetHeight(image), by: 64) {
                    let row = (base + y * stride).assumingMemoryBound(to: UInt16.self)
                    for x in Swift.stride(from: 0, to: CVPixelBufferGetWidth(image), by: 7) {
                        total += 1
                        if (row[x * 4 + 1] >> 4) & 3 != 0 { fine += 1 }
                    }
                }
                let share = total > 0 ? 100 * fine / total : 0
                answer = share > 10 ? "kept 12 bits (\(share)% finer than 10-bit)" : "kept 10 bits (\(share)%)"
            } catch {
                answer = "depth: \(error.localizedDescription)"
            }
        }
        _ = done.wait(timeout: .now() + 60)
        return answer
    }

    /// Writes a moving gradient with light noise, in-range for 10-bit video.
    private static func fill(_ buffer: CVPixelBuffer, seed: Int) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        var noise = UInt32(truncatingIfNeeded: seed &* 2_654_435_761 &+ 1)
        // Packed AYCbCr has no planes, and its alpha stays opaque as it does in a take.
        let packed = CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_4444AYpCbCr16
        let planes: [(UnsafeMutableRawPointer?, Int, Int)] = packed
            ? [(CVPixelBufferGetBaseAddress(buffer), CVPixelBufferGetBytesPerRow(buffer), CVPixelBufferGetHeight(buffer))]
            : (0..<CVPixelBufferGetPlaneCount(buffer)).map {
                (CVPixelBufferGetBaseAddressOfPlane(buffer, $0), CVPixelBufferGetBytesPerRowOfPlane(buffer, $0),
                 CVPixelBufferGetHeightOfPlane(buffer, $0))
            }
        for (base, stride, rows) in planes {
            guard let base else { continue }
            let columns = stride / 2
            for y in 0..<rows {
                let row = (base + y * stride).assumingMemoryBound(to: UInt16.self)
                for x in 0..<columns {
                    if packed && x % 4 == 0 {
                        row[x] = .max
                        continue
                    }
                    noise = noise &* 1_664_525 &+ 1_013_904_223
                    let wave = (x &* 3 &+ y &* 5 &+ seed &* 40) & 511
                    if packed {
                        // 12-bit codes, so `keptDepth` can tell what the file kept.
                        row[x] = UInt16((256 + wave) * 4 + Int((noise >> 26) & 63)) << 4
                    } else {
                        row[x] = UInt16(256 + wave + Int((noise >> 28) & 15)) << 6
                    }
                }
            }
        }
    }
}
