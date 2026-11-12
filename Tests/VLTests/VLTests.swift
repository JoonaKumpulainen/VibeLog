import AVFoundation
import CoreGraphics
import CoreVideo
import Metal
import VideoToolbox
import XCTest
import VLCore
@testable import VLProcessing
@testable import VLRecording
import simd

final class FrameStatsTests: XCTestCase {
    func testSteadyStream() {
        let stats = FrameStats()
        for index in 0..<101 { stats.recordFrame(pts: Double(index) * 0.1) }
        let snapshot = stats.snapshot()
        XCTAssertEqual(snapshot.frames, 101)
        XCTAssertEqual(snapshot.sustainedFPS, 10, accuracy: 0.001)
        XCTAssertEqual(snapshot.rollingFPS, 10, accuracy: 0.001)
        XCTAssertEqual(snapshot.gapMedianMs, 100, accuracy: 0.001)
        XCTAssertEqual(snapshot.estimatedMissed, 0)
    }

    func testGapEstimatesMissedFrames() {
        let stats = FrameStats()
        for pts in [0.0, 0.1, 0.2, 0.3, 0.6, 0.7] { stats.recordFrame(pts: pts) }
        let snapshot = stats.snapshot()
        XCTAssertEqual(snapshot.gapMaxMs, 300, accuracy: 0.001)
        XCTAssertEqual(snapshot.estimatedMissed, 2)
    }

    func testEmptyAndSingleFrame() {
        let stats = FrameStats()
        XCTAssertEqual(stats.snapshot().sustainedFPS, 0)
        stats.recordFrame(pts: 1)
        XCTAssertEqual(stats.snapshot().frames, 1)
        XCTAssertEqual(stats.snapshot().sustainedFPS, 0)
    }
}

final class PixelFormatTests: XCTestCase {
    func testFourCC() {
        XCTAssertEqual(PixelFormats.fourCC(kCVPixelFormatType_14Bayer_RGGB), "rgg4")
        XCTAssertEqual(PixelFormats.osType("rgg4"), kCVPixelFormatType_14Bayer_RGGB)
        XCTAssertEqual(PixelFormats.fourCC(32), "0x00000020")
    }

    func testCFAOffsets() {
        let grbg = CFAPattern(pixelFormat: kCVPixelFormatType_14Bayer_GRBG)
        XCTAssertEqual(grbg, .grbg)
        XCTAssertEqual(grbg?.redOffset.x, 1)
        XCTAssertEqual(grbg?.redOffset.y, 0)
        XCTAssertEqual(grbg?.blueOffset.x, 0)
        XCTAssertEqual(grbg?.blueOffset.y, 1)
        XCTAssertEqual(CFAPattern(dngPattern: [2, 1, 1, 0]), .bggr)
        XCTAssertNil(CFAPattern(pixelFormat: kCVPixelFormatType_32BGRA))
    }
}

final class DNGMetadataTests: XCTestCase {
    /// Little-endian TIFF with raw tags in a SubIFD, the layout real DNGs use.
    private func makeTIFF() -> Data {
        var data = Data()
        func put16(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        func put32(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }

        // Header, then IFD0 at 8 with Make and SubIFDs.
        data.append(contentsOf: [0x49, 0x49])
        put16(42)
        put32(8)
        put16(2)
        put16(271); put16(2); put32(6); put32(100)
        put16(330); put16(4); put32(1); put32(38)
        put32(0)
        // SubIFD at 38 with CFA, black, white and a signed-rational matrix.
        XCTAssertEqual(data.count, 38)
        put16(4)
        put16(33422); put16(1); put32(4); data.append(contentsOf: [0, 1, 1, 2])
        put16(50714); put16(3); put32(1); put16(528); put16(0)
        put16(50717); put16(4); put32(1); put32(16383)
        put16(50721); put16(10); put32(2); put32(120)
        put32(0)
        // Padding to the external values.
        XCTAssertEqual(data.count, 92)
        data.append(contentsOf: [UInt8](repeating: 0, count: 8))
        data.append(contentsOf: Array("Apple\0".utf8))
        data.append(contentsOf: [UInt8](repeating: 0, count: 14))
        XCTAssertEqual(data.count, 120)
        put32(UInt32(bitPattern: -3)); put32(2)
        put32(1); put32(4)
        return data
    }

    func testReadsTagsFromSubIFD() throws {
        let metadata = try DNGMetadata(dng: makeTIFF())
        XCTAssertEqual(metadata.make, "Apple")
        XCTAssertEqual(metadata.cfaPattern, "RGGB")
        XCTAssertEqual(metadata.blackLevel, [528])
        XCTAssertEqual(metadata.whiteLevel, [16383])
        XCTAssertEqual(metadata.colorMatrix1, [-1.5, 0.25])
    }

    func testRejectsGarbage() {
        XCTAssertThrowsError(try DNGMetadata(dng: Data([1, 2, 3, 4, 5, 6, 7, 8])))
    }

    func testRejectsTruncatedOffset() {
        let data = Data([0x49, 0x49, 42, 0, 0xFF, 0xFF, 0, 0])
        XCTAssertThrowsError(try DNGMetadata(dng: data))
    }
}

final class RawLevelsTests: XCTestCase {
    func testReadsBufferLevelsFromPhotoMetadata() {
        let metadata: [String: Any] = ["{DNG}": ["BlackLevel": 2112, "WhiteLevel": 16383]]
        XCTAssertEqual(RawLevels(photoMetadata: metadata), RawLevels(black: [2112], white: 16383))
    }

    func testReadsPerChannelBlackLevels() {
        let levels: [String: Any] = ["BlackLevel": [2112, 2110, 2111, 2113], "WhiteLevel": 16383]
        let metadata: [String: Any] = ["{DNG}": levels]
        XCTAssertEqual(RawLevels(photoMetadata: metadata)?.black, [2112, 2110, 2111, 2113])
    }

    func testMissingLevels() {
        XCTAssertNil(RawLevels(photoMetadata: [:]))
        XCTAssertNil(RawLevels(photoMetadata: ["{DNG}": ["WhiteLevel": 16383]]))
    }
}

final class FrameSamplerTests: XCTestCase {
    private func sample(_ values: [UInt16], width: Int) -> FrameSample? {
        values.withUnsafeBytes {
            FrameSampler.sample(
                base: $0.baseAddress!, width: width, height: values.count / width,
                bytesPerRow: width * 2, step: 1)
        }
    }

    func testRangeAndMean() {
        let result = sample([2112, 3000, 16383, 4000], width: 2)
        XCTAssertEqual(result?.min, 2112)
        XCTAssertEqual(result?.max, 16383)
        XCTAssertEqual(result?.mean ?? 0, 6373.75, accuracy: 0.001)
    }

    func testHashSeparatesFrames() {
        XCTAssertEqual(sample([1, 2, 3, 4], width: 2)?.hash, sample([1, 2, 3, 4], width: 2)?.hash)
        XCTAssertNotEqual(sample([1, 2, 3, 4], width: 2)?.hash, sample([1, 2, 3, 5], width: 2)?.hash)
    }

    func testRejectsEightBitLayout() {
        let values: [UInt16] = [0, 0]
        let result = values.withUnsafeBytes {
            FrameSampler.sample(base: $0.baseAddress!, width: 4, height: 1, bytesPerRow: 4)
        }
        XCTAssertNil(result)
    }
}

final class FieldOfViewTests: XCTestCase {
    private let width = 640
    private let height = 480

    /// A frame of one fixed scene, magnified about its center by `zoom`.
    private func frame(zoom: Double) -> [UInt16] {
        var values: [UInt16] = []
        for y in 0..<height {
            let v = 0.5 + (Double(y) / Double(height) - 0.5) / zoom
            for x in 0..<width {
                let u = 0.5 + (Double(x) / Double(width) - 0.5) / zoom
                values.append(UInt16(8000 + 3000 * sin(u * 12) + 2000 * cos(v * 9) + 1500 * u * v))
            }
        }
        return values
    }

    private func map(_ values: [UInt16], fraction: Double = 1) -> [Double]? {
        values.withUnsafeBytes {
            FieldOfView.map(
                base: $0.baseAddress!, width: width, height: height, bytesPerRow: width * 2,
                fraction: fraction)
        }
    }

    private func match(_ shot: [UInt16], reference: [UInt16]) throws -> FieldOfView.Match {
        let image = try XCTUnwrap(map(shot))
        return FieldOfView.match(
            whole: FieldOfView.correlation(image, try XCTUnwrap(map(reference))),
            center: FieldOfView.correlation(image, try XCTUnwrap(map(reference, fraction: 0.5))))
    }

    func testTrueCropMatchesTheCenter() throws {
        XCTAssertEqual(try match(frame(zoom: 2), reference: frame(zoom: 1)), .cropped)
    }

    func testIgnoredZoomMatchesTheWholeFrame() throws {
        XCTAssertEqual(try match(frame(zoom: 1), reference: frame(zoom: 1)), .same)
    }

    func testFlatSceneProvesNothing() throws {
        let flat = [UInt16](repeating: 5000, count: width * height)
        XCTAssertEqual(try match(flat, reference: flat), .unclear)
        XCTAssertNil(FieldOfView.correlation(try XCTUnwrap(map(flat)), try XCTUnwrap(map(flat))))
    }

    func testRejectsEightBitLayout() {
        let values: [UInt16] = [0, 0]
        let result = values.withUnsafeBytes {
            FieldOfView.map(base: $0.baseAddress!, width: 640, height: 480, bytesPerRow: 640)
        }
        XCTAssertNil(result)
    }
}

final class CaptureTimingTests: XCTestCase {
    func testIgnoresEventsOutsideATake() {
        let log = CaptureTimingLog()
        log.record(.request, time: 1)
        XCTAssertTrue(log.finish().isEmpty)
        log.begin()
        log.record(.request, time: 2)
        XCTAssertEqual(log.finish().map(\.time), [2])
        log.record(.request, time: 3)
        XCTAssertTrue(log.finish().isEmpty)
    }

    func testCSVCountsFromTheFirstEvent() {
        let log = CaptureTimingLog()
        log.begin()
        log.record(.request, time: 10, request: 7, inFlight: 2)
        log.record(.frame, time: 10.5, request: 7, sensorTime: 10.25)
        XCTAssertEqual(
            CaptureTimingLog.csv(log.finish()),
            "seconds,event,request,sensor_seconds,in_flight\n"
                + "0.000000,request,7,,2\n0.500000,frame,7,0.250000,\n")
    }

    /// The ultra wide's pattern: two frames out of every three on a 33 ms grid.
    func testSummaryShowsSkippedFrames() {
        let log = CaptureTimingLog()
        log.begin()
        let slots = [0, 1, 3, 4, 6, 7]
        for (index, slot) in slots.enumerated() {
            let time = Double(slot) / 30
            log.record(.request, time: time, request: Int64(index + 1), inFlight: 0)
            log.record(.frame, time: time + 0.1, request: Int64(index + 1), sensorTime: time)
        }
        log.record(.notReady, time: 1)
        log.record(.heldNotReady, time: 1.01)
        log.record(.ready, time: 1.04)
        let summary = CaptureTimingLog.summary(log.finish())
        XCTAssertTrue(summary.contains("6 requests, 6 frames"), summary)
        XCTAssertTrue(summary.contains("request to frame 100.0 ms median"), summary)
        XCTAssertTrue(summary.contains("not ready 1 times for 40.0 ms median"), summary)
        XCTAssertTrue(summary.contains("held 1 not ready"), summary)
        XCTAssertTrue(summary.contains("frame gaps 35 ms x3, 65 ms x2"), summary)
    }
}

final class LogCurveTests: XCTestCase {
    func testMiddleGrayMatchesPublishedValues() {
        XCTAssertEqual(LogCurve.appleLog.encode(0.18), 0.4882724585, accuracy: 1e-8)
        XCTAssertEqual(LogCurve.sLog3.encode(0.18), 420.0 / 1023, accuracy: 1e-9)
        XCTAssertEqual(LogCurve.logC3.encode(0.18), 0.3910068, accuracy: 1e-6)
        // colour-science's examples for each.
        XCTAssertEqual(LogCurve.sLog2.encode(0.18), 0.3395325, accuracy: 1e-6)
        XCTAssertEqual(LogCurve.logC4.encode(0.18), 0.2783958, accuracy: 1e-6)
        XCTAssertEqual(LogCurve.canonLog3.encode(0.18), 0.3433894, accuracy: 1e-6)
    }

    func testPublishedCodeValues() {
        XCTAssertEqual(LogCurve.sLog3.encode(0) * 1023, 95, accuracy: 1e-6)
        XCTAssertEqual(LogCurve.sLog3.encode(0.9) * 1023, 598, accuracy: 1)
        XCTAssertEqual(LogCurve.logC3.encode(0), 0.092809, accuracy: 1e-9)
        XCTAssertEqual(LogCurve.sLog2.encode(0) * 1023, 90, accuracy: 0.5)
        XCTAssertEqual(LogCurve.sLog2.encode(0.9) * 1023, 582, accuracy: 0.5)
        XCTAssertEqual(LogCurve.logC4.encode(0), 95.0 / 1023, accuracy: 1e-9)
        XCTAssertEqual(LogCurve.canonLog3.encode(0), 0.12512219, accuracy: 1e-9)
    }

    func testEveryCurveRisesThroughItsShadows() {
        for curve in LogCurve.allCases {
            let samples = stride(from: -0.02, through: 0.05, by: 0.001).map(curve.encode)
            XCTAssertTrue(zip(samples, samples.dropFirst()).allSatisfy { $0 <= $1 }, "\(curve)")
        }
    }

    func testRoundTrips() {
        for curve in LogCurve.allCases {
            for x in [0.0, 0.002, 0.009, 0.0115, 0.05, 0.18, 0.9, 4, 16] {
                XCTAssertEqual(curve.decode(curve.encode(x)), x, accuracy: 1e-5, "\(curve) at \(x)")
            }
        }
    }

    func testCurvesAreContinuousAtTheirKnees() {
        for curve in LogCurve.allCases {
            for knee in [0.01, 0.01125, 0.010591, 0, 0.0126, -0.0126, -0.018057] {
                XCTAssertEqual(curve.encode(knee - 1e-7), curve.encode(knee + 1e-7), accuracy: 1e-4, "\(curve)")
            }
        }
    }
}

final class ColorScienceTests: XCTestCase {
    /// ColorMatrix1 and 2 and the as-shot neutral from an iPhone 14 Pro main camera DNG.
    private func calibration() throws -> CameraCalibration {
        var fields: [String: Any] = [:]
        fields["colorMatrix1"] = [
            1.2901775845553018, -0.6245414020276934, -0.2525035441251675,
            -0.4718195198832923, 1.5372142776714335, -0.04470928015706254,
            -0.04709417744715199, 0.1507237405961337, 0.6165214779212976,
        ]
        fields["colorMatrix2"] = [
            0.9558454148856476, -0.36769840105618307, -0.1344799995394915,
            -0.43038934493785647, 1.3233913177339902, 0.08365981284843245,
            -0.09998676923658495, 0.2129978090332576, 0.45237019636188414,
        ]
        fields["calibrationIlluminant1"] = [17.0]
        fields["calibrationIlluminant2"] = [21.0]
        let data = try JSONSerialization.data(withJSONObject: fields)
        let metadata = try JSONDecoder().decode(DNGMetadata.self, from: data)
        return try XCTUnwrap(CameraCalibration(metadata))
    }

    func testNeutralMapsToWhite() throws {
        let matrix = try calibration().balancedToRec2020(neutral: SIMD3(0.3949474, 1, 0.5822317))
        let white = matrix * SIMD3(repeating: 1)
        XCTAssertEqual(white.x, 1, accuracy: 1e-3)
        XCTAssertEqual(white.y, 1, accuracy: 1e-3)
        XCTAssertEqual(white.z, 1, accuracy: 1e-3)
    }

    func testNeutralMapsToWhiteAcrossLighting() throws {
        let camera = try calibration()
        for neutral in [SIMD3(0.75, 1, 0.3), SIMD3(0.5, 1, 0.5), SIMD3(0.36, 1, 0.68)] {
            let white = camera.balancedToRec2020(neutral: neutral) * SIMD3<Double>(repeating: 1)
            XCTAssertEqual(simd_length(white - SIMD3(repeating: 1)), 0, accuracy: 1e-3)
        }
    }

    func testBradfordKeepsMatchingWhites() {
        let matrix = ColorMath.bradford(from: ColorMath.d65, to: ColorMath.d65)
        XCTAssertEqual(simd_length(matrix * ColorMath.d65 - ColorMath.d65), 0, accuracy: 1e-9)
    }

    func testD65IsWhiteInBothSpaces() {
        let rec2020 = ColorMath.xyzToRec2020 * ColorMath.d65
        XCTAssertEqual(simd_length(rec2020 - SIMD3(repeating: 1)), 0, accuracy: 1e-3)
        let rec709 = ColorMath.rec2020ToRec709 * SIMD3(repeating: 1)
        XCTAssertEqual(simd_length(rec709 - SIMD3(repeating: 1)), 0, accuracy: 1e-3)
    }
}

final class MonitorTests: XCTestCase {
    func testMiddleGrayStaysNeutralAndInPlace() {
        for curve in LogCurve.allCases {
            let gray = curve.encode(0.18)
            let output = MonitorTransform.display(log: SIMD3(repeating: gray), curve: curve)
            XCTAssertEqual(output.x, pow(0.18, 1 / 2.4), accuracy: 1e-3)
            XCTAssertEqual(output.x, output.y, accuracy: 1e-3)
            XCTAssertEqual(output.y, output.z, accuracy: 1e-3)
        }
    }

    func testHighlightsRollOffBelowClipping() {
        let curve = LogCurve.appleLog
        let bright = MonitorTransform.display(log: SIMD3(repeating: curve.encode(2)), curve: curve)
        let peak = MonitorTransform.display(log: SIMD3(repeating: curve.encode(8)), curve: curve)
        XCTAssertLessThan(bright.x, 0.98)
        XCTAssertEqual(peak.x, 1, accuracy: 1e-6)
    }

}

final class PipelineGPUTests: XCTestCase {
    /// Runs a flat gray scene through the shader. After white balance every sample is
    /// `level`, so any debayer must return it and the output must equal the Swift curve.
    private func run(
        _ pipeline: ProcessingPipeline, level: Float, cfa: CFAPattern, gains: [Float]
    ) throws -> SIMD3<Double> {
        let width = 16
        let height = 16
        let black: Float = 2112
        let clip: Float = 14271
        func value(_ x: Int, _ y: Int) -> UInt16 {
            var gain = gains[1]
            if UInt32(x & 1) == cfa.redOffset.x, UInt32(y & 1) == cfa.redOffset.y { gain = gains[0] }
            if UInt32(x & 1) == cfa.blueOffset.x, UInt32(y & 1) == cfa.blueOffset.y { gain = gains[2] }
            return UInt16((level / gain * (clip - black) + black).rounded())
        }
        var samples = [UInt16]()
        for y in 0..<height { for x in 0..<width { samples.append(value(x, y)) } }

        let inputDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r16Uint, width: width, height: height, mipmapped: false)
        inputDescriptor.usage = .shaderRead
        let input = try XCTUnwrap(pipeline.device.makeTexture(descriptor: inputDescriptor))
        samples.withUnsafeBytes {
            input.replace(
                region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                withBytes: $0.baseAddress!, bytesPerRow: width * 2)
        }
        let output = try XCTUnwrap(pipeline.device.makeTexture(
            descriptor: ProcessingPipeline.outputDescriptor(width: width, height: height)))
        let queue = try XCTUnwrap(pipeline.device.makeCommandQueue())
        let commands = try XCTUnwrap(queue.makeCommandBuffer())
        XCTAssertTrue(pipeline.encode(into: commands, input: input, output: output, cfa: cfa, gains: gains))
        let readback = try XCTUnwrap(pipeline.device.makeBuffer(length: width * height * 8, options: .storageModeShared))
        let blit = try XCTUnwrap(commands.makeBlitCommandEncoder())
        blit.copy(
            from: output, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
            sourceSize: MTLSize(width: width, height: height, depth: 1), to: readback,
            destinationOffset: 0, destinationBytesPerRow: width * 8, destinationBytesPerImage: readback.length)
        blit.endEncoding()
        commands.commit()
        commands.waitUntilCompleted()
        XCTAssertEqual(commands.status, .completed)

        let pixels = readback.contents().bindMemory(to: UInt16.self, capacity: width * height * 4)
        let offset = (8 * width + 8) * 4
        return SIMD3(Double(pixels[offset]), Double(pixels[offset + 1]), Double(pixels[offset + 2])) / 65535
    }

    private func makePipeline() throws -> ProcessingPipeline {
        guard let pipeline = ProcessingPipeline() else {
            throw XCTSkip("No Metal device with this pipeline on this runner")
        }
        pipeline.setCalibration(nil, levels: RawLevels(black: [2112], white: 16383))
        return pipeline
    }

    /// The viewfinder decodes each curve on the GPU, which must match `MonitorTransform.display`.
    func testViewfinderMatchesTheMonitorTransform() throws {
        let pipeline = try makePipeline()
        let device = pipeline.device
        let samples: [SIMD3<Double>] = [
            SIMD3(repeating: 0.18), SIMD3(repeating: 0.003), SIMD3(repeating: 2), SIMD3(0.036, 0.072, 0.45),
            SIMD3(0.4, 0.1, 0.05), SIMD3(0.05, 0.3, 0.08), SIMD3(repeating: 0.02), SIMD3(repeating: 6),
        ]
        func texture(_ usage: MTLTextureUsage) throws -> MTLTexture {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .rgba16Unorm, width: samples.count, height: 1, mipmapped: false)
            descriptor.usage = usage
            return try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        }
        let queue = try XCTUnwrap(device.makeCommandQueue())
        for curve in LogCurve.allCases {
            let gamut = curve.nativeGamut
            let logs = samples.map { SIMD3(curve.encode($0.x), curve.encode($0.y), curve.encode($0.z)) }
            let pixels = logs.flatMap { log in
                [log.x, log.y, log.z, 1].map { UInt16((min(max($0, 0), 1) * 65535).rounded()) }
            }
            let image = try texture(.shaderRead)
            pixels.withUnsafeBytes {
                image.replace(
                    region: MTLRegionMake2D(0, 0, samples.count, 1), mipmapLevel: 0, withBytes: $0.baseAddress!,
                    bytesPerRow: samples.count * 8)
            }
            let output = try texture(.shaderWrite)
            let commands = try XCTUnwrap(queue.makeCommandBuffer())
            XCTAssertTrue(pipeline.encodeMonitorTransform(
                into: commands, image: image, output: output, curve: curve, gamut: gamut))
            commands.commit()
            commands.waitUntilCompleted()
            XCTAssertEqual(commands.status, .completed)
            var result = [UInt16](repeating: 0, count: samples.count * 4)
            output.getBytes(
                &result, bytesPerRow: samples.count * 8, from: MTLRegionMake2D(0, 0, samples.count, 1), mipmapLevel: 0)
            for (index, log) in logs.enumerated() {
                let quantized = SIMD3(
                    Double(pixels[index * 4]), Double(pixels[index * 4 + 1]), Double(pixels[index * 4 + 2])) / 65535
                let expected = MonitorTransform.display(log: quantized, curve: curve, gamut: gamut)
                let got = SIMD3(Double(result[index * 4]), Double(result[index * 4 + 1]), Double(result[index * 4 + 2])) / 65535
                // Within one 8-bit step: the GPU works in 32-bit floats.
                let worst = max(abs(got.x - expected.x), abs(got.y - expected.y), abs(got.z - expected.z))
                XCTAssertLessThan(worst, 1.0 / 255, "\(curve) at \(log)")
            }
        }
    }

    func testShaderMatchesSwiftCurves() throws {
        let pipeline = try makePipeline()
        var settings = ProcessingSettings()
        settings.exposureStops = 0
        for curve in LogCurve.allCases {
            for demosaic in DemosaicMethod.allCases {
                // Only the curve under test, in Rec.2020 where it can be.
                settings.restore(curve: curve, gamut: .rec2020)
                settings.demosaic = demosaic
                pipeline.update(settings)
                let result = try run(pipeline, level: 0.18, cfa: .bggr, gains: [2.5, 1, 1.7])
                let expected = curve.encode(0.18)
                XCTAssertEqual(result.x, expected, accuracy: 0.002, "\(curve) \(demosaic)")
                XCTAssertEqual(result.y, expected, accuracy: 0.002, "\(curve) \(demosaic)")
                XCTAssertEqual(result.z, expected, accuracy: 0.002, "\(curve) \(demosaic)")
            }
        }
    }

    func testEveryBayerOrderAndExposure() throws {
        let pipeline = try makePipeline()
        var settings = ProcessingSettings()
        settings.exposureStops = 1
        pipeline.update(settings)
        for cfa in [CFAPattern.rggb, .bggr, .grbg, .gbrg] {
            let result = try run(pipeline, level: 0.09, cfa: cfa, gains: [2, 1, 1.5])
            XCTAssertEqual(result.x, LogCurve.appleLog.encode(0.18), accuracy: 0.002, "\(cfa)")
            XCTAssertEqual(result.z, LogCurve.appleLog.encode(0.18), accuracy: 0.002, "\(cfa)")
        }
    }

    /// A flat gray log image must become Y = 64 + 876 * level with neutral chroma, MSB-aligned.
    func testYCbCrConversionOfGray() throws {
        let pipeline = try makePipeline()
        let device = pipeline.device
        func texture(_ format: MTLPixelFormat, _ width: Int, _ height: Int, _ usage: MTLTextureUsage) throws -> MTLTexture {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: format, width: width, height: height, mipmapped: false)
            descriptor.usage = usage
            return try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        }
        let image = try texture(.rgba16Unorm, 8, 8, .shaderRead)
        let level = UInt16(0.5 * 65535)
        let pixels = [UInt16](repeating: level, count: 8 * 8 * 4)
        pixels.withUnsafeBytes {
            image.replace(region: MTLRegionMake2D(0, 0, 8, 8), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: 64)
        }
        let luma = try texture(.r16Unorm, 8, 8, .shaderWrite)
        let chroma = try texture(.rg16Unorm, 4, 4, .shaderWrite)
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let commands = try XCTUnwrap(queue.makeCommandBuffer())
        XCTAssertTrue(pipeline.encodeYCbCr(into: commands, image: image, luma: luma, chroma: chroma))
        commands.commit()
        commands.waitUntilCompleted()
        XCTAssertEqual(commands.status, .completed)

        var lumaValue: UInt16 = 0
        luma.getBytes(&lumaValue, bytesPerRow: 16, from: MTLRegionMake2D(4, 4, 1, 1), mipmapLevel: 0)
        var chromaValue: [UInt16] = [0, 0]
        chroma.getBytes(&chromaValue, bytesPerRow: 8, from: MTLRegionMake2D(2, 2, 1, 1), mipmapLevel: 0)
        XCTAssertEqual(lumaValue >> 6, 502)
        XCTAssertEqual(lumaValue & 63, 0)
        XCTAssertEqual(chromaValue[0] >> 6, 512)
        XCTAssertEqual(chromaValue[1] >> 6, 512)
    }

    /// Packed output keeps the fraction of a 10-bit code: 400.25 is 12-bit 1601, where 10 bits would round it.
    func testPackedConversionKeepsTwelveBits() throws {
        let pipeline = try makePipeline()
        let device = pipeline.device
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Unorm, width: 8, height: 8, mipmapped: false)
        descriptor.usage = .shaderRead
        let image = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        let level = UInt16((336.25 / 876 * 65535).rounded())
        let pixels = [UInt16](repeating: level, count: 8 * 8 * 4)
        pixels.withUnsafeBytes {
            image.replace(region: MTLRegionMake2D(0, 0, 8, 8), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: 64)
        }
        descriptor.usage = .shaderWrite
        let packed = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let commands = try XCTUnwrap(queue.makeCommandBuffer())
        XCTAssertTrue(pipeline.encodePacked(into: commands, image: image, packed: packed))
        commands.commit()
        commands.waitUntilCompleted()
        XCTAssertEqual(commands.status, .completed)

        var value: [UInt16] = [0, 0, 0, 0]
        packed.getBytes(&value, bytesPerRow: 64, from: MTLRegionMake2D(4, 4, 1, 1), mipmapLevel: 0)
        XCTAssertEqual(value[0], .max)
        XCTAssertEqual(value[1] >> 4, 1601)
        XCTAssertEqual(value[2] >> 4, 2048)
        XCTAssertEqual(value[3] >> 4, 2048)
    }

    /// Baked, middle gray in S-Log3 becomes the Rec.709 view's gray, in Rec.709's matrix.
    func testBakedLookWritesTheRec709View() throws {
        let pipeline = try makePipeline()
        let device = pipeline.device
        func texture(_ format: MTLPixelFormat, _ width: Int, _ height: Int, _ usage: MTLTextureUsage) throws -> MTLTexture {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: format, width: width, height: height, mipmapped: false)
            descriptor.usage = usage
            return try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        }
        let gray = LogCurve.sLog3.encode(0.18)
        let image = try texture(.rgba16Unorm, 8, 8, .shaderRead)
        let pixels = [UInt16](repeating: UInt16((gray * 65535).rounded()), count: 8 * 8 * 4)
        pixels.withUnsafeBytes {
            image.replace(region: MTLRegionMake2D(0, 0, 8, 8), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: 64)
        }
        var settings = ProcessingSettings()
        settings.curve = .sLog3
        settings.bakeLook = true
        let look = LookParams(settings: settings, lut: nil)
        XCTAssertEqual(look.mode, 1)
        XCTAssertEqual(look.luma, LookParams.rec709Luma)

        let luma = try texture(.r16Unorm, 8, 8, .shaderWrite)
        let chroma = try texture(.rg16Unorm, 4, 8, .shaderWrite)
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let commands = try XCTUnwrap(queue.makeCommandBuffer())
        XCTAssertTrue(pipeline.encodeYCbCr(into: commands, image: image, luma: luma, chroma: chroma, look: look))
        commands.commit()
        commands.waitUntilCompleted()
        XCTAssertEqual(commands.status, .completed)
        var lumaValue: UInt16 = 0
        luma.getBytes(&lumaValue, bytesPerRow: 16, from: MTLRegionMake2D(4, 4, 1, 1), mipmapLevel: 0)
        var chromaValue: [UInt16] = [0, 0]
        chroma.getBytes(&chromaValue, bytesPerRow: 16, from: MTLRegionMake2D(2, 4, 1, 1), mipmapLevel: 0)
        let display = MonitorTransform.display(log: SIMD3(repeating: gray), curve: .sLog3, gamut: settings.gamut).y
        XCTAssertEqual(Double(lumaValue >> 6), (64 + 876 * display).rounded(), accuracy: 1)
        XCTAssertEqual(Double(chromaValue[0] >> 6), 512, accuracy: 1)
        XCTAssertEqual(Double(chromaValue[1] >> 6), 512, accuracy: 1)
    }

    func testFileTagSetsTheMatrix() {
        var settings = ProcessingSettings()
        XCTAssertEqual(LookParams(settings: settings, lut: nil).luma, LookParams.rec2020Luma)
        XCTAssertEqual(LookParams(settings: settings, lut: nil).mode, 0)
        settings.rec709Matrix = true
        XCTAssertEqual(LookParams(settings: settings, lut: nil).luma, LookParams.rec709Luma)
        XCTAssertEqual(LookParams(settings: settings, lut: nil).mode, 0)
    }

    /// Noisy Bayer data through both pipelines must give the same planes to within rounding.
    private func comparePipelines(
        lumaHeight: Int, chromaWidth: Int, chromaHeight: Int, demosaic: DemosaicMethod, curve: LogCurve
    ) throws {
        let pipeline = try makePipeline()
        var settings = ProcessingSettings()
        settings.demosaic = demosaic
        settings.curve = curve
        pipeline.update(settings)
        let device = pipeline.device
        let size = 32

        var noise: UInt32 = 12345
        var samples = [UInt16]()
        for _ in 0..<(size * size) {
            noise = noise &* 1_664_525 &+ 1_013_904_223
            samples.append(UInt16(2112 + (noise >> 16) % 12160))
        }
        let inputDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r16Uint, width: size, height: size, mipmapped: false)
        inputDescriptor.usage = .shaderRead
        let input = try XCTUnwrap(device.makeTexture(descriptor: inputDescriptor))
        samples.withUnsafeBytes {
            input.replace(region: MTLRegionMake2D(0, 0, size, size), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: size * 2)
        }
        func plane(_ format: MTLPixelFormat, _ width: Int, _ height: Int) throws -> MTLTexture {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: format, width: width, height: height, mipmapped: false)
            descriptor.usage = .shaderWrite
            return try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        }
        let fullLuma = try plane(.r16Unorm, size, lumaHeight)
        let fullChroma = try plane(.rg16Unorm, chromaWidth, chromaHeight)
        let directLuma = try plane(.r16Unorm, size, lumaHeight)
        let directChroma = try plane(.rg16Unorm, chromaWidth, chromaHeight)
        let fullPacked = try plane(.rgba16Unorm, size, lumaHeight)
        let directPacked = try plane(.rgba16Unorm, size, lumaHeight)
        let image = try XCTUnwrap(device.makeTexture(
            descriptor: ProcessingPipeline.outputDescriptor(width: size, height: size)))

        let queue = try XCTUnwrap(device.makeCommandQueue())
        let commands = try XCTUnwrap(queue.makeCommandBuffer())
        let gains: [Float] = [2.5, 1, 1.7]
        XCTAssertTrue(pipeline.encode(into: commands, input: input, output: image, cfa: .bggr, gains: gains))
        XCTAssertTrue(pipeline.encodeYCbCr(into: commands, image: image, luma: fullLuma, chroma: fullChroma))
        XCTAssertTrue(pipeline.encodeDirect(
            into: commands, input: input, luma: directLuma, chroma: directChroma, cfa: .bggr, gains: gains))
        XCTAssertTrue(pipeline.encodePacked(into: commands, image: image, packed: fullPacked))
        XCTAssertTrue(pipeline.encodeDirectPacked(
            into: commands, input: input, packed: directPacked, cfa: .bggr, gains: gains))
        commands.commit()
        commands.waitUntilCompleted()
        XCTAssertEqual(commands.status, .completed)

        func values(_ texture: MTLTexture, channels: Int) -> [UInt16] {
            var data = [UInt16](repeating: 0, count: texture.width * texture.height * channels)
            texture.getBytes(
                &data, bytesPerRow: texture.width * channels * 2,
                from: MTLRegionMake2D(0, 0, texture.width, texture.height), mipmapLevel: 0)
            return data
        }
        func worstDifference(_ first: [UInt16], _ second: [UInt16]) -> Int {
            zip(first, second).map { abs(Int($0 >> 6) - Int($1 >> 6)) }.max() ?? 0
        }
        let label = "\(demosaic) \(curve) \(lumaHeight) \(chromaWidth)x\(chromaHeight)"
        XCTAssertLessThanOrEqual(worstDifference(values(fullLuma, channels: 1), values(directLuma, channels: 1)), 1, label)
        XCTAssertLessThanOrEqual(worstDifference(values(fullChroma, channels: 2), values(directChroma, channels: 2)), 1, label)

        // Packed 4:4:4: both paths agree, alpha is opaque, and luma matches the 10-bit plane.
        let full = values(fullPacked, channels: 4)
        let direct = values(directPacked, channels: 4)
        XCTAssertLessThanOrEqual(worstDifference(full, direct), 1, label)
        XCTAssertTrue(stride(from: 0, to: full.count, by: 4).allSatisfy { full[$0] == .max && direct[$0] == .max }, label)
        let packedLuma = stride(from: 1, to: full.count, by: 4).map { full[$0] }
        XCTAssertLessThanOrEqual(worstDifference(packedLuma, values(fullLuma, channels: 1)), 1, label)
    }

    func testEfficientPipelineMatchesAt422() throws {
        for curve in LogCurve.allCases {
            for demosaic in DemosaicMethod.allCases {
                try comparePipelines(lumaHeight: 32, chromaWidth: 16, chromaHeight: 32, demosaic: demosaic, curve: curve)
            }
        }
    }

    func testEfficientPipelineMatchesAt420And444() throws {
        try comparePipelines(lumaHeight: 32, chromaWidth: 16, chromaHeight: 16, demosaic: .malvar, curve: .appleLog)
        try comparePipelines(lumaHeight: 32, chromaWidth: 32, chromaHeight: 32, demosaic: .malvar, curve: .appleLog)
    }

    func testEfficientPipelineMatchesCenterCrop() throws {
        try comparePipelines(lumaHeight: 16, chromaWidth: 16, chromaHeight: 16, demosaic: .malvar, curve: .appleLog)
    }

    /// A flat scene must read the same on the small monitor path as on the full path.
    func testMonitorPathMatchesFlatScene() throws {
        let pipeline = try makePipeline()
        var settings = ProcessingSettings()
        settings.exposureStops = 0
        pipeline.update(settings)
        let device = pipeline.device
        let gains: [Float] = [2.5, 1, 1.7]
        let cfa = CFAPattern.bggr
        var samples = [UInt16]()
        for y in 0..<16 {
            for x in 0..<16 {
                var gain = gains[1]
                if UInt32(x & 1) == cfa.redOffset.x, UInt32(y & 1) == cfa.redOffset.y { gain = gains[0] }
                if UInt32(x & 1) == cfa.blueOffset.x, UInt32(y & 1) == cfa.blueOffset.y { gain = gains[2] }
                samples.append(UInt16((0.18 / gain * 12159 + 2112).rounded()))
            }
        }
        let inputDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r16Uint, width: 16, height: 16, mipmapped: false)
        inputDescriptor.usage = .shaderRead
        let input = try XCTUnwrap(device.makeTexture(descriptor: inputDescriptor))
        samples.withUnsafeBytes {
            input.replace(region: MTLRegionMake2D(0, 0, 16, 16), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: 32)
        }
        let output = try XCTUnwrap(device.makeTexture(
            descriptor: ProcessingPipeline.outputDescriptor(width: 8, height: 8)))
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let commands = try XCTUnwrap(queue.makeCommandBuffer())
        XCTAssertTrue(pipeline.encodeMonitor(into: commands, input: input, output: output, cfa: cfa, gains: gains))
        let readback = try XCTUnwrap(device.makeBuffer(length: 8 * 8 * 8, options: .storageModeShared))
        let blit = try XCTUnwrap(commands.makeBlitCommandEncoder())
        blit.copy(
            from: output, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
            sourceSize: MTLSize(width: 8, height: 8, depth: 1), to: readback, destinationOffset: 0,
            destinationBytesPerRow: 64, destinationBytesPerImage: readback.length)
        blit.endEncoding()
        commands.commit()
        commands.waitUntilCompleted()
        let pixels = readback.contents().bindMemory(to: UInt16.self, capacity: 8 * 8 * 4)
        let offset = (4 * 8 + 4) * 4
        let expected = LogCurve.appleLog.encode(0.18)
        for channel in 0..<3 {
            XCTAssertEqual(Double(pixels[offset + channel]) / 65535, expected, accuracy: 0.002)
        }
    }

    /// A vertical ramp, cropped to half its height, must start a quarter of the way down.
    func testYCbCrCropsToCenter() throws {
        let pipeline = try makePipeline()
        let device = pipeline.device
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Unorm, width: 16, height: 16, mipmapped: false)
        descriptor.usage = .shaderRead
        let image = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        var pixels = [UInt16]()
        for y in 0..<16 {
            let value = UInt16(Double(y) / 15 * 65535)
            for _ in 0..<16 { pixels += [value, value, value, 65535] }
        }
        pixels.withUnsafeBytes {
            image.replace(region: MTLRegionMake2D(0, 0, 16, 16), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: 128)
        }
        func target(_ format: MTLPixelFormat, _ width: Int, _ height: Int) throws -> MTLTexture {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: format, width: width, height: height, mipmapped: false)
            descriptor.usage = .shaderWrite
            return try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        }
        let luma = try target(.r16Unorm, 16, 8)
        let chroma = try target(.rg16Unorm, 8, 4)
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let commands = try XCTUnwrap(queue.makeCommandBuffer())
        XCTAssertTrue(pipeline.encodeYCbCr(into: commands, image: image, luma: luma, chroma: chroma))
        commands.commit()
        commands.waitUntilCompleted()
        XCTAssertEqual(commands.status, .completed)

        func level(row: Int) -> Double {
            var value: UInt16 = 0
            luma.getBytes(&value, bytesPerRow: 32, from: MTLRegionMake2D(4, row, 1, 1), mipmapLevel: 0)
            return (Double(value >> 6) - 64) / 876
        }
        XCTAssertEqual(level(row: 0), 4.0 / 15, accuracy: 0.03)
        XCTAssertEqual(level(row: 7), 11.0 / 15, accuracy: 0.03)
    }

    func testClippedSamplesStayNeutral() throws {
        let pipeline = try makePipeline()
        var settings = ProcessingSettings()
        settings.exposureStops = 0
        pipeline.update(settings)
        let result = try run(pipeline, level: 1.4, cfa: .bggr, gains: [2, 1, 1.5])
        XCTAssertEqual(result.x, result.y, accuracy: 1e-3)
        XCTAssertEqual(result.y, result.z, accuracy: 1e-3)
    }
}

final class CubeLUTTests: XCTestCase {
    private let identity = """
        # comment
        TITLE "Test"
        LUT_3D_SIZE 2
        DOMAIN_MIN 0.0 0.0 0.0
        DOMAIN_MAX 1.0 1.0 2.0

        0 0 0
        1 0 0
        0 1 0
        1 1 0
        0 0 1
        1 0 1
        0 1 1
        1.5 1 -0.5
        """

    func testParsesHeaderAndSamples() throws {
        let lut = try CubeLUT(text: identity)
        XCTAssertEqual(lut.size, 2)
        XCTAssertEqual(lut.domainMax.z, 2)
        XCTAssertEqual(lut.samples[1], SIMD3(1, 0, 0))
        XCTAssertEqual(lut.samples.count, 8)
    }

    func testTextureSamplesClamp() throws {
        let samples = try CubeLUT(text: identity).textureSamples
        XCTAssertEqual(samples.count, 32)
        XCTAssertEqual(Array(samples[28..<32]), [65535, 65535, 0, 65535])
    }

    func testRejectsBadFiles() {
        XCTAssertThrowsError(try CubeLUT(text: "LUT_1D_SIZE 4\n")) {
            XCTAssertEqual($0 as? CubeLUT.ParseError, .oneDimensional)
        }
        XCTAssertThrowsError(try CubeLUT(text: "0 0 0\n")) {
            XCTAssertEqual($0 as? CubeLUT.ParseError, .missingSize)
        }
        XCTAssertThrowsError(try CubeLUT(text: "LUT_3D_SIZE 2\n0 0 0\n")) {
            XCTAssertEqual($0 as? CubeLUT.ParseError, .wrongSampleCount(expected: 8, found: 1))
        }
        XCTAssertThrowsError(try CubeLUT(text: "LUT_3D_SIZE 500\n")) {
            XCTAssertEqual($0 as? CubeLUT.ParseError, .unsupportedSize(500))
        }
        XCTAssertThrowsError(try CubeLUT(text: "LUT_3D_SIZE 2\nnot a number here\n"))
    }
}

final class MonitorBandsTests: XCTestCase {
    func testBandsAreOrderedAroundMiddleGray() {
        for curve in LogCurve.allCases {
            let bands = MonitorBands(curve: curve, exposureStops: 2)
            let gray = Float(curve.encode(0.18))
            XCTAssertLessThan(bands.blueBelow, bands.greenFrom)
            XCTAssertLessThan(bands.greenFrom, gray)
            XCTAssertLessThan(gray, bands.greenTo)
            XCTAssertLessThan(bands.greenTo, bands.pinkFrom)
            XCTAssertLessThan(bands.pinkFrom, bands.pinkTo)
            XCTAssertLessThan(bands.pinkTo, bands.yellowFrom)
            XCTAssertLessThan(bands.yellowFrom, bands.clip)
        }
    }

    func testClipFollowsExposure() {
        let curve = LogCurve.appleLog
        let low = MonitorBands(curve: curve, exposureStops: -0.5).clip
        let high = MonitorBands(curve: curve, exposureStops: 0.5).clip
        XCTAssertEqual(low, Float(curve.encode(0.98 * pow(2, -0.5))), accuracy: 1e-5)
        XCTAssertGreaterThan(high, low)
    }
}

final class VideoEncoderTests: XCTestCase {
    func testWidescreenSizes() {
        XCTAssertEqual(EncoderSize(width: 4032, height: 3024).widescreen, EncoderSize(width: 4032, height: 2268))
        XCTAssertEqual(EncoderSize(width: 1920, height: 1440).widescreen, EncoderSize(width: 1920, height: 1080))
        XCTAssertTrue(EncoderSize.all.allSatisfy { $0.widescreen.height % 2 == 0 })
    }

    func testPresetsAreUniqueWithKnownFormats() throws {
        XCTAssertEqual(Set(EncoderPreset.all.map(\.id)).count, EncoderPreset.all.count)
        let formats: Set<OSType> = [
            kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
            kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange,
            kCVPixelFormatType_444YpCbCr10BiPlanarVideoRange,
            kCVPixelFormatType_4444AYpCbCr16,
        ]
        XCTAssertTrue(EncoderPreset.all.allSatisfy { formats.contains($0.pixelFormat) })
        XCTAssertTrue(EncoderPreset.all.allSatisfy { $0.bitDepth == 10 })
        let prores4444 = try XCTUnwrap(EncoderPreset.all.first { $0.id == "prores4444" })
        XCTAssertEqual(prores4444.twelveBit.bitDepth, 12)
        XCTAssertEqual(prores4444.twelveBit.id, prores4444.id)
        for preset in EncoderPreset.all where preset.id != "prores4444" {
            XCTAssertEqual(preset.twelveBit, preset)
        }
    }

    private func support(_ fps: [String: [String: Double]], codecs: Set<String>? = nil, measured: Bool = true) -> EncoderSupport {
        EncoderSupport(
            device: "test", system: "test", codecs: codecs ?? Set(EncoderSupport.presets.map(\.id)), fps: fps, measured: measured)
    }

    private func preset(_ id: String) throws -> EncoderPreset {
        try XCTUnwrap(EncoderSupport.presets.first { $0.id == id })
    }

    /// A phone without ProRes, such as the iPhone 12, moves to HEVC of the same chroma.
    func testPhoneWithoutProResMovesToHEVC() throws {
        let hevcOnly = support(
            ["hevc420": ["4032x3024": 40], "hevc422": ["4032x3024": 31], "hevc444": ["2880x2160": 33]],
            codecs: ["hevc420", "hevc422", "hevc444"])
        XCTAssertFalse(hevcOnly.hasProRes)
        XCTAssertFalse(hevcOnly.supportsTwelveBit)
        XCTAssertFalse(hevcOnly.supports(try preset("prores422hq")))
        XCTAssertEqual(hevcOnly.replacement(for: try preset("prores422hq")).id, "hevc422")
        XCTAssertEqual(hevcOnly.replacement(for: try preset("prores4444")).id, "hevc444")
        XCTAssertEqual(hevcOnly.bestSize(for: try preset("hevc444"))?.label, "2880x2160")
    }

    /// A chroma the encoder refused falls to the next with the most detail, and to HEVC 4:2:0 when
    /// nothing is known to work.
    func testReplacementWhenChromaIsMissing() throws {
        let only420 = support(["hevc420": ["4032x3024": 30]], codecs: ["hevc420", "hevc422", "hevc444"])
        XCTAssertFalse(only420.supports(try preset("hevc422")))
        XCTAssertEqual(only420.replacement(for: try preset("hevc444")).id, "hevc420")
        let nothing = support([:], codecs: [])
        XCTAssertEqual(nothing.replacement(for: try preset("prores422hq")).id, "hevc420")
    }

    /// Before the trials, the codec list alone decides, and no size is suggested.
    func testUnmeasuredSupportTrustsTheCodecList() throws {
        let listed = support([:], codecs: ["hevc420", "prores422hq"], measured: false)
        XCTAssertTrue(listed.supports(try preset("prores422hq")))
        XCTAssertFalse(listed.supports(try preset("prores4444")))
        XCTAssertNil(listed.bestSize(for: try preset("prores422hq")))
    }

    /// The largest size that keeps 30 fps, or the fastest when none does.
    func testBestSizeKeepsRealTime() throws {
        let slow = support(["hevc444": ["4032x3024": 21, "2880x2160": 29, "1920x1440": 28]])
        XCTAssertEqual(slow.bestSize(for: try preset("hevc444"))?.label, "2880x2160")
        let fast = support(["prores422hq": ["4032x3024": 90]])
        XCTAssertEqual(fast.bestSize(for: try preset("prores422hq"))?.label, "4032x3024")
        XCTAssertFalse(fast.supportsTwelveBit)
    }

    /// The iPhone 16's own trial results, from its log of 2026-11-10: ProRes is far below real
    /// time at full size, so the default moves to HEVC of the same chroma at the largest size
    /// with room to spare, instead of a small ProRes picture.
    func testSlowProResPhoneDefaultsToLargerHEVC() throws {
        let sixteen = support([
            "hevc420": ["4032x3024": 28.0, "2880x2160": 51.2],
            "hevc422": ["4032x3024": 26.6, "2880x2160": 48.5],
            "hevc444": ["4032x3024": 26.4, "2880x2160": 45.3],
            "prores422": ["4032x3024": 17.0, "2880x2160": 33.4],
            "prores422hq": ["4032x3024": 14.9, "2880x2160": 27.6, "1920x1440": 58.0],
            "prores4444": ["4032x3024": 9.4, "2880x2160": 20.7, "1920x1440": 42.6],
            "prores422lt": ["4032x3024": 24.2, "2880x2160": 42.6],
        ])
        let best = try XCTUnwrap(sixteen.bestDefault(for: try preset("prores422hq")))
        XCTAssertEqual(best.preset.id, "hevc422")
        XCTAssertEqual(best.size.label, "2880x2160")
        let fourFour = try XCTUnwrap(sixteen.bestDefault(for: try preset("prores4444")))
        XCTAssertEqual(fourFour.preset.id, "hevc444")
        XCTAssertEqual(fourFour.size.label, "2880x2160")
    }

    /// A phone with a fast ProRes encoder, like the 14 Pro, keeps ProRes at full size whatever
    /// its other codecs measured, so another phone's fallback never reaches it.
    func testFastProResPhoneKeepsItsDefault() throws {
        let pro = support([
            "hevc420": ["4032x3024": 31], "hevc422": ["4032x3024": 29, "2880x2160": 55],
            "prores422hq": ["4032x3024": 130], "prores4444": ["4032x3024": 132],
        ])
        let best = try XCTUnwrap(pro.bestDefault(for: try preset("prores422hq")))
        XCTAssertEqual(best.preset.id, "prores422hq")
        XCTAssertEqual(best.size.label, "4032x3024")
        // Full size at a bare 30 fps still beats a smaller picture with room to spare.
        let bare = support(
            ["hevc420": ["4032x3024": 31], "hevc422": ["4032x3024": 24, "2880x2160": 55]],
            codecs: ["hevc420", "hevc422"])
        let hevc = try XCTUnwrap(bare.bestDefault(for: try preset("hevc422")))
        XCTAssertEqual(hevc.preset.id, "hevc420")
        XCTAssertEqual(hevc.size.label, "4032x3024")
        XCTAssertNil(support([:], measured: false).bestDefault(for: try preset("prores422hq")))
    }

    /// One stall is retried in place, as on every phone so far. Two with no frame between them,
    /// or four in a short while, give up so the session can be rebuilt another way.
    func testStallCounterGivesUpOnlyWhenRequestsHang() {
        var counter = StallCounter()
        XCTAssertEqual(counter.stalled(at: 0), .retry)
        counter.frameArrived()
        XCTAssertEqual(counter.stalled(at: 100), .retry)
        XCTAssertEqual(counter.stalled(at: 102), .giveUp)

        var trickle = StallCounter()
        for time in [0.0, 3, 6] {
            XCTAssertEqual(trickle.stalled(at: time), .retry)
            trickle.frameArrived()
        }
        XCTAssertEqual(trickle.stalled(at: 9), .giveUp)

        var rare = StallCounter()
        for time in [0.0, 30, 60, 90, 120] {
            XCTAssertEqual(rare.stalled(at: time), .retry)
            rare.frameArrived()
        }
    }

    /// Every phone starts on the standard setup, and the ladder only ever adds a workaround.
    func testCaptureLadderStartsStandardAndEnds() {
        XCTAssertEqual(CaptureSetup.ladder.first, .standard)
        XCTAssertEqual(Set(CaptureSetup.ladder.map(\.label)).count, CaptureSetup.ladder.count)
        var phone = CaptureSupport(device: "test", system: "test")
        XCTAssertEqual(phone.setup, .standard)
        XCTAssertFalse(phone.setup.keepsPreview)
        XCTAssertTrue(phone.setup.fastCapture)
        var steps = 0
        while let next = phone.next {
            phone = next
            steps += 1
        }
        XCTAssertEqual(steps, CaptureSetup.ladder.count - 1)
        XCTAssertTrue(phone.setup.sequential)
        XCTAssertEqual(CaptureSupport(device: "test", system: "test", step: 99).setup, CaptureSetup.ladder.last)
    }

    /// A saved step only applies to the phone model and iOS version it was found on.
    func testCaptureSupportIsKeptPerPhone() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("capture_\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        XCTAssertEqual(CaptureSupport.saved(from: file).step, 0)
        var mine = CaptureSupport.current()
        mine.step = 1
        mine.save(to: file)
        XCTAssertEqual(CaptureSupport.saved(from: file), mine)
        CaptureSupport(device: "another phone", system: mine.system, step: 2).save(to: file)
        XCTAssertEqual(CaptureSupport.saved(from: file).step, 0)
        CaptureSupport(device: mine.device, system: "another iOS", step: 2).save(to: file)
        XCTAssertEqual(CaptureSupport.saved(from: file).step, 0)
        CaptureSupport.forget(at: file)
        XCTAssertEqual(CaptureSupport.saved(from: file).step, 0)
    }

    /// Record is refused while no frame arrives, which needs the time since the last one.
    func testFrameStatsKnowsWhenFramesStop() {
        let stats = FrameStats()
        XCTAssertNil(stats.secondsSinceFrame())
        let start = Date()
        stats.recordFrame(pts: 1, arrival: start)
        XCTAssertEqual(try XCTUnwrap(stats.secondsSinceFrame(now: start.addingTimeInterval(2.5))), 2.5, accuracy: 0.001)
        stats.reset()
        XCTAssertNil(stats.secondsSinceFrame())
    }

    /// The codec list runs on the simulator, where HEVC should be listed.
    func testCodecListFindsHEVC() throws {
        XCTAssertEqual(EncoderSupport.codecType(.proRes422HQ), kCMVideoCodecType_AppleProRes422HQ)
        XCTAssertEqual(EncoderSupport.codecType(.hevc), kCMVideoCodecType_HEVC)
        let listed = EncoderSupport.codecList()
        XCTAssertFalse(listed.measured)
        guard listed.codecs.contains("hevc420") else { throw XCTSkip("This simulator lists no HEVC encoder") }
        XCTAssertTrue(listed.supports(try preset("hevc420")))
    }

    /// A gradient finer than 10 bits must come back from a ProRes 4444 file with its in-between steps.
    func testProRes4444FileKeepsTwelveBits() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mov")
        let preset = try XCTUnwrap(EncoderPreset.all.first { $0.id == "prores4444" }).twelveBit
        let encoder: VideoEncoder
        do {
            encoder = try VideoEncoder(config: .init(
                url: url, preset: preset, size: EncoderSize(width: 256, height: 64), audio: false, realTime: false))
        } catch {
            throw XCTSkip("\(preset.label) is not available here: \(error)")
        }
        for index in 0..<4 {
            let buffer = try XCTUnwrap(encoder.nextPixelBuffer())
            XCTAssertEqual(CVPixelBufferGetPixelFormatType(buffer), kCVPixelFormatType_4444AYpCbCr16)
            CVPixelBufferLockBaseAddress(buffer, [])
            let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(buffer))
            let stride = CVPixelBufferGetBytesPerRow(buffer)
            for y in 0..<64 {
                let row = (base + y * stride).assumingMemoryBound(to: UInt16.self)
                for x in 0..<256 {
                    // Luma climbs one 12-bit step per column, a quarter of a 10-bit code.
                    row[x * 4] = .max
                    row[x * 4 + 1] = UInt16(1600 + x) << 4
                    row[x * 4 + 2] = 2048 << 4
                    row[x * 4 + 3] = 2048 << 4
                }
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            encoder.append(buffer, at: CMTime(value: Int64(index), timescale: 30))
        }
        let result = await withCheckedContinuation { continuation in
            encoder.finish { continuation.resume(returning: $0) }
        }
        if result.failure != nil { throw XCTSkip("Encoder failed here: \(result.failure ?? "")") }

        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_4444AYpCbCr16,
        ])
        reader.add(output)
        XCTAssertTrue(reader.startReading())
        let sample = try XCTUnwrap(output.copyNextSampleBuffer())
        let decoded = try XCTUnwrap(CMSampleBufferGetImageBuffer(sample))
        CVPixelBufferLockBaseAddress(decoded, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(decoded, .readOnly) }
        let row = try XCTUnwrap(CVPixelBufferGetBaseAddress(decoded))
            .advanced(by: 32 * CVPixelBufferGetBytesPerRow(decoded)).assumingMemoryBound(to: UInt16.self)
        let lumaSteps = Set((16..<240).map { Int(row[$0 * 4 + 1]) >> 4 })
        // 224 columns span 56 10-bit codes. Many more distinct levels means 12 bits survived.
        XCTAssertGreaterThan(lumaSteps.count, 150, "\(lumaSteps.count) distinct luma levels")
    }

    func testWriterAcceptsBothAudioFormats() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mov")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        XCTAssertTrue(writer.canApply(outputSettings: VideoEncoder.audioSettings(pcm: false), forMediaType: .audio))
        XCTAssertTrue(writer.canApply(outputSettings: VideoEncoder.audioSettings(pcm: true), forMediaType: .audio))
        for pcm in [false, true] {
            let stereo = VideoEncoder.audioSettings(pcm: pcm, channels: 2)
            XCTAssertEqual(stereo[AVNumberOfChannelsKey] as? Int, 2)
            XCTAssertTrue(writer.canApply(outputSettings: stereo, forMediaType: .audio), "pcm \(pcm)")
        }
        XCTAssertEqual(VideoEncoder.audioSettings(pcm: false, channels: 2)[AVEncoderBitRateKey] as? Int, 256_000)
    }

    /// Settings the writer accepts can still fail at the first sample, as 384 kbps stereo AAC did on
    /// the phone, so this encodes real stereo audio in both formats.
    func testWritesStereoAudio() async throws {
        for pcm in [false, true] {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mov")
            let preset = try XCTUnwrap(EncoderPreset.all.first { $0.id == "hevc420" })
            let encoder: VideoEncoder
            do {
                encoder = try VideoEncoder(config: .init(
                    url: url, preset: preset, size: EncoderSize(width: 640, height: 480), audio: true, pcmAudio: pcm,
                    audioChannels: 2, realTime: false))
            } catch {
                throw XCTSkip("\(preset.label) is not available here: \(error)")
            }
            var format = AudioStreamBasicDescription(
                mSampleRate: 48000, mFormatID: kAudioFormatLinearPCM,
                mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked, mBytesPerPacket: 4,
                mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: 2, mBitsPerChannel: 16, mReserved: 0)
            var description: CMAudioFormatDescription?
            XCTAssertEqual(CMAudioFormatDescriptionCreate(
                allocator: nil, asbd: &format, layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil,
                extensions: nil, formatDescriptionOut: &description), noErr)
            let frames = 1024
            for index in 0..<10 {
                if index % 3 == 0 {
                    let buffer = try XCTUnwrap(encoder.nextPixelBuffer())
                    encoder.append(buffer, at: CMTime(value: Int64(index / 3), timescale: 30))
                }
                // A tone on the left, silence on the right.
                var samples = [Int16](repeating: 0, count: frames * 2)
                for frame in 0..<frames { samples[frame * 2] = Int16(8000 * sin(Double(index * frames + frame) * 0.05)) }
                var block: CMBlockBuffer?
                let bytes = samples.count * 2
                XCTAssertEqual(CMBlockBufferCreateWithMemoryBlock(
                    allocator: nil, memoryBlock: nil, blockLength: bytes, blockAllocator: nil, customBlockSource: nil,
                    offsetToData: 0, dataLength: bytes, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block), noErr)
                samples.withUnsafeBytes { _ = CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block!, offsetIntoDestination: 0, dataLength: bytes) }
                var sample: CMSampleBuffer?
                XCTAssertEqual(CMAudioSampleBufferCreateReadyWithPacketDescriptions(
                    allocator: nil, dataBuffer: block!, formatDescription: description!, sampleCount: frames,
                    presentationTimeStamp: CMTime(value: Int64(index * frames), timescale: 48000),
                    packetDescriptions: nil, sampleBufferOut: &sample), noErr)
                encoder.appendAudio(try XCTUnwrap(sample))
                // Real-time-style audio input drops samples while the writer is busy, so give it room.
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            let result = await withCheckedContinuation { continuation in encoder.finish { continuation.resume(returning: $0) } }
            XCTAssertNil(result.failure, "pcm \(pcm): \(result.failure ?? "")")
            XCTAssertGreaterThan(result.audioSamplesWritten, 0, "pcm \(pcm)")
            let tracks = try await AVURLAsset(url: url).loadTracks(withMediaType: .audio)
            let audioTrack = try XCTUnwrap(tracks.first)
            let descriptions = try await audioTrack.load(.formatDescriptions)
            let channels = descriptions.first.flatMap { CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee.mChannelsPerFrame }
            XCTAssertEqual(channels, 2, "pcm \(pcm)")
        }
    }

    func testMetersReadEachChannel() {
        let interleaved: [Int16] = [100, -2000, 300, 50]
        let stereo = interleaved.withUnsafeBytes {
            AudioLevels.channelPeaks($0, bits: 16, float: false, channels: 2, interleaved: true)
        }
        XCTAssertEqual(stereo?.left ?? 0, 300 / 32768, accuracy: 1e-6)
        XCTAssertEqual(stereo?.right ?? 0, 2000 / 32768, accuracy: 1e-6)

        let blocks: [Float] = [0.1, -0.4, 0.2, 0.05]
        let split = blocks.withUnsafeBytes {
            AudioLevels.channelPeaks($0, bits: 32, float: true, channels: 2, interleaved: false)
        }
        XCTAssertEqual(split?.left ?? 0, 0.4, accuracy: 1e-6)
        XCTAssertEqual(split?.right ?? 0, 0.2, accuracy: 1e-6)

        let mono: [Int16] = [-16384, 8]
        let single = mono.withUnsafeBytes {
            AudioLevels.channelPeaks($0, bits: 16, float: false, channels: 1, interleaved: true)
        }
        XCTAssertEqual(single?.left, single?.right)
        XCTAssertEqual(single?.left ?? 0, 0.5, accuracy: 1e-6)
        XCTAssertNil([UInt8](repeating: 0, count: 6).withUnsafeBytes {
            AudioLevels.channelPeaks($0, bits: 24, float: false, channels: 2, interleaved: true)
        })
    }

    func testExpectedFrameRateFollowsTheTake() throws {
        let preset = try XCTUnwrap(EncoderPreset.all.first { $0.id == "hevc420" })
        let settings = preset.outputSettings(width: 1920, height: 1440, frameRate: 24)
        let compression = try XCTUnwrap(settings[AVVideoCompressionPropertiesKey] as? [String: Any])
        XCTAssertEqual(compression[AVVideoExpectedSourceFrameRateKey] as? Double, 24)
    }

    func testWritesAPlayableFile() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mov")
        let preset = EncoderPreset.all[0]
        let encoder: VideoEncoder
        do {
            encoder = try VideoEncoder(config: .init(
                url: url, preset: preset, size: EncoderSize(width: 640, height: 480), audio: false,
                realTime: false))
        } catch {
            throw XCTSkip("\(preset.label) is not available here: \(error)")
        }
        for index in 0..<10 {
            let buffer = try XCTUnwrap(encoder.nextPixelBuffer())
            encoder.append(buffer, at: CMTime(value: Int64(index), timescale: 30))
        }
        let result = await withCheckedContinuation { continuation in
            encoder.finish { continuation.resume(returning: $0) }
        }
        if result.failure != nil { throw XCTSkip("Encoder failed here: \(result.failure ?? "")") }
        XCTAssertEqual(result.framesWritten, 10)
        XCTAssertEqual(result.fps, 30, accuracy: 0.01)
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        XCTAssertEqual(tracks.count, 1)
    }

    /// A flat S-Log3 gray take, exported with the Rec.709 view, reads back as that view's gray.
    func testExportBakesTheLook() async throws {
        let folder = FileManager.default.temporaryDirectory
        let source = folder.appendingPathComponent(UUID().uuidString + ".mov")
        let output = folder.appendingPathComponent(UUID().uuidString + ".mov")
        let preset = try XCTUnwrap(EncoderPreset.all.first { $0.id == "hevc420" })
        let size = EncoderSize(width: 640, height: 480)
        let gray = LogCurve.sLog3.encode(0.18)
        let writer: VideoEncoder
        do {
            writer = try VideoEncoder(config: .init(url: source, preset: preset, size: size, audio: false, realTime: false))
        } catch {
            throw XCTSkip("\(preset.label) is not available here: \(error)")
        }
        for index in 0..<6 {
            let buffer = try XCTUnwrap(writer.nextPixelBuffer())
            CVPixelBufferLockBaseAddress(buffer, [])
            for (plane, value) in [(0, 64 + 876 * gray), (1, 512.0)] {
                let base = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(buffer, plane))
                let count = CVPixelBufferGetBytesPerRowOfPlane(buffer, plane) * CVPixelBufferGetHeightOfPlane(buffer, plane) / 2
                let samples = base.assumingMemoryBound(to: UInt16.self)
                for sample in 0..<count { samples[sample] = UInt16(value.rounded()) << 6 }
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            writer.append(buffer, at: CMTime(value: Int64(index), timescale: 30))
        }
        let written = await withCheckedContinuation { continuation in writer.finish { continuation.resume(returning: $0) } }
        if written.failure != nil { throw XCTSkip("Encoder failed here: \(written.failure ?? "")") }

        let look = LookExporter.Look(
            curve: .sLog3, gamut: .sGamut3Cine, lut: nil, lutExpectsRec709: false, sourceRec709: false)
        let exporter = try XCTUnwrap(LookExporter(look: look))
        let sink = try VideoEncoder(config: .init(
            url: output, preset: preset, size: size, audio: false, realTime: false, fileTag: .rec709))
        do {
            try await exporter.export(from: source, into: sink, seconds: 0.2, progress: { _ in }, cancelled: { false })
        } catch LookExporter.Failure.cannotRead(let reason) {
            throw XCTSkip("The simulator can't read the take back: \(reason)")
        }
        let exported = await withCheckedContinuation { continuation in sink.finish { continuation.resume(returning: $0) } }
        XCTAssertNil(exported.failure)
        XCTAssertEqual(exported.framesWritten, 6)

        let asset = AVURLAsset(url: output)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let reader = try AVAssetReader(asset: asset)
        let trackOutput = AVAssetReaderTrackOutput(track: try XCTUnwrap(tracks.first), outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
        ])
        reader.add(trackOutput)
        XCTAssertTrue(reader.startReading())
        let frame = try XCTUnwrap(trackOutput.copyNextSampleBuffer().flatMap(CMSampleBufferGetImageBuffer))
        CVPixelBufferLockBaseAddress(frame, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(frame, .readOnly) }
        let row = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(frame, 0))
            .advanced(by: 240 * CVPixelBufferGetBytesPerRowOfPlane(frame, 0)).assumingMemoryBound(to: UInt16.self)
        let display = MonitorTransform.display(log: SIMD3(repeating: gray), curve: .sLog3, gamut: .sGamut3Cine).y
        XCTAssertEqual(Double(row[320] >> 6), 64 + 876 * display, accuracy: 3)

        // Playback draws the same look as the export.
        let playing = AVURLAsset(url: source)
        let generator = AVAssetImageGenerator(asset: playing)
        generator.videoComposition = try await LookPlayback.composition(for: playing, exporter: exporter)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let image: CGImage
        do {
            image = try await generator.image(at: CMTime(value: 1, timescale: 30)).image
        } catch {
            throw XCTSkip("The simulator can't play the take back: \(error)")
        }
        XCTAssertEqual(image.width, 640)
        let space = try XCTUnwrap(image.colorSpace)
        var pixel = [UInt8](repeating: 0, count: 4)
        let context = try XCTUnwrap(CGContext(
            data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: space,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.draw(image, in: CGRect(x: -320, y: -240, width: image.width, height: image.height))
        XCTAssertEqual(Double(pixel[0]), 255 * display, accuracy: 3)
        XCTAssertEqual(Double(pixel[1]), 255 * display, accuracy: 3)
    }

    /// A take stored a quarter turn from upright plays upright: the stored frame's dark left half
    /// is on top, as the screen shows a portrait take.
    func testPlaybackTurnsByTheTakesRotation() async throws {
        let source = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mov")
        let preset = try XCTUnwrap(EncoderPreset.all.first { $0.id == "hevc420" })
        let writer: VideoEncoder
        do {
            writer = try VideoEncoder(config: .init(
                url: source, preset: preset, size: EncoderSize(width: 640, height: 480), audio: false,
                realTime: false, rotationDegrees: 90))
        } catch {
            throw XCTSkip("\(preset.label) is not available here: \(error)")
        }
        let dark = LogCurve.sLog3.encode(0.01)
        let bright = LogCurve.sLog3.encode(0.9)
        for index in 0..<6 {
            let buffer = try XCTUnwrap(writer.nextPixelBuffer())
            CVPixelBufferLockBaseAddress(buffer, [])
            let luma = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(buffer, 0)).assumingMemoryBound(to: UInt16.self)
            let lumaRow = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0) / 2
            for row in 0..<480 {
                for column in 0..<640 {
                    let code = 64 + 876 * (column < 320 ? dark : bright)
                    luma[row * lumaRow + column] = UInt16(code.rounded()) << 6
                }
            }
            let chroma = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(buffer, 1)).assumingMemoryBound(to: UInt16.self)
            let chromaCount = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1) * CVPixelBufferGetHeightOfPlane(buffer, 1) / 2
            for sample in 0..<chromaCount { chroma[sample] = 512 << 6 }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            writer.append(buffer, at: CMTime(value: Int64(index), timescale: 30))
        }
        let written = await withCheckedContinuation { continuation in writer.finish { continuation.resume(returning: $0) } }
        if written.failure != nil { throw XCTSkip("Encoder failed here: \(written.failure ?? "")") }

        let look = LookExporter.Look(
            curve: .sLog3, gamut: .sGamut3Cine, lut: nil, lutExpectsRec709: false, sourceRec709: false)
        let exporter = try XCTUnwrap(LookExporter(look: look))
        let asset = AVURLAsset(url: source)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.videoComposition = try await LookPlayback.composition(for: asset, exporter: exporter)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let image: CGImage
        do {
            image = try await generator.image(at: CMTime(value: 1, timescale: 30)).image
        } catch {
            throw XCTSkip("The simulator can't play the take back: \(error)")
        }
        XCTAssertEqual(image.width, 480)
        XCTAssertEqual(image.height, 640)
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let context = try XCTUnwrap(CGContext(
            data: &pixels, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
            space: try XCTUnwrap(image.colorSpace), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        // The context's first row is the image's top.
        let top = pixels[(160 * image.width + 240) * 4]
        let bottom = pixels[(480 * image.width + 240) * 4]
        XCTAssertLessThan(Int(top) + 60, Int(bottom), "top \(top), bottom \(bottom)")
    }

    /// Editors read the rate from the track, which must keep whole ticks per frame.
    func testFileReadsAtItsFrameRate() async throws {
        for fps in [24.0, 25, 24000.0 / 1001] {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mov")
            let preset = EncoderPreset.all[0]
            let encoder: VideoEncoder
            do {
                encoder = try VideoEncoder(config: .init(
                    url: url, preset: preset, size: EncoderSize(width: 640, height: 480), frameRate: fps,
                    audio: false, realTime: false))
            } catch {
                throw XCTSkip("\(preset.label) is not available here: \(error)")
            }
            // Capture times on the nanosecond clock, as the pipeline gives them.
            for index in 0..<10 {
                let buffer = try XCTUnwrap(encoder.nextPixelBuffer())
                encoder.append(buffer, at: CMTime(seconds: 1000 + Double(index) / fps, preferredTimescale: 1_000_000_000))
            }
            let result = await withCheckedContinuation { continuation in
                encoder.finish { continuation.resume(returning: $0) }
            }
            if result.failure != nil { throw XCTSkip("Encoder failed here: \(result.failure ?? "")") }
            let tracks = try await AVURLAsset(url: url).loadTracks(withMediaType: .video)
            let track = try XCTUnwrap(tracks.first)
            let (scale, rate) = try await track.load(.naturalTimeScale, .nominalFrameRate)
            XCTAssertEqual(scale, FrameRates.mediaTimeScale(fps))
            XCTAssertEqual(Double(rate), fps, accuracy: 0.005)
        }
    }
}

final class RawRecorderTests: XCTestCase {
    private func makeBuffer(fill: UInt8) -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any]]
        XCTAssertEqual(
            CVPixelBufferCreate(nil, 64, 32, kCVPixelFormatType_OneComponent16, attributes as CFDictionary, &buffer),
            kCVReturnSuccess)
        CVPixelBufferLockBaseAddress(buffer!, [])
        memset(CVPixelBufferGetBaseAddress(buffer!), Int32(fill), CVPixelBufferGetDataSize(buffer!))
        CVPixelBufferUnlockBaseAddress(buffer!, [])
        return buffer!
    }

    private func frame(_ index: Int) -> RawFrame {
        RawFrame(
            buffer: makeBuffer(fill: UInt8(index)), pts: Double(index) / 10, exposureSeconds: 0.01,
            iso: 100, whiteBalanceGains: [2, 1, 1.5])
    }

    private func record(frames: Int, write: Bool) throws -> (URL, [String: Any]) {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let recorder = try RawRecorder(config: .init(
            directory: folder, writeFrames: write, memoryBudget: 1 << 24,
            context: ClipContext(method: "test", lens: "test", format: "test", requestedSeconds: 1)))
        for index in 0..<frames { recorder.append(frame(index)) }
        let done = expectation(description: "finished")
        recorder.finish { _ in done.fulfill() }
        wait(for: [done], timeout: 10)
        let json = try Data(contentsOf: folder.appendingPathComponent("clip.json"))
        let sidecar = try XCTUnwrap(JSONSerialization.jsonObject(with: json) as? [String: Any])
        return (folder, sidecar)
    }

    func testWritesFramesAndSidecar() throws {
        let (folder, sidecar) = try record(frames: 5, write: true)
        let layout = try XCTUnwrap(sidecar["layout"] as? [String: Any])
        let frameSize = try XCTUnwrap(layout["bytesPerFrame"] as? Int)
        let raw = try Data(contentsOf: folder.appendingPathComponent("frames.raw"))
        XCTAssertEqual(raw.count, frameSize * 5)
        XCTAssertEqual(raw[frameSize * 3], 3)
        let frames = try XCTUnwrap(sidecar["frames"] as? [[String: Any]])
        XCTAssertEqual(frames.count, 5)
        XCTAssertEqual(frames[2]["fileOffset"] as? Int, frameSize * 2)
    }

    func testSidecarUsesBufferLevelsNotDNGLevels() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let recorder = try RawRecorder(config: .init(
            directory: folder, writeFrames: false, memoryBudget: 1 << 24,
            context: ClipContext(method: "test", lens: "test", format: "test", requestedSeconds: 1)))
        recorder.beginReference()
        recorder.finishReference(dng: nil, metadata: ["{DNG}": ["BlackLevel": 2112, "WhiteLevel": 16383]])
        recorder.append(frame(0))
        let done = expectation(description: "finished")
        recorder.finish { _ in done.fulfill() }
        wait(for: [done], timeout: 10)
        let json = try Data(contentsOf: folder.appendingPathComponent("clip.json"))
        let sidecar = try XCTUnwrap(JSONSerialization.jsonObject(with: json) as? [String: Any])
        XCTAssertEqual(sidecar["blackLevel"] as? [Double], [2112])
        XCTAssertEqual(sidecar["whiteLevel"] as? [Double], [16383])
    }

    func testDroppedFramesKeepTimingWithoutFileOffsets() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let size = FrameLayout(buffer: makeBuffer(fill: 0)).bytesPerFrame
        let recorder = try RawRecorder(config: .init(
            directory: folder, writeFrames: true, memoryBudget: size * 2,
            context: ClipContext(method: "test", lens: "test", format: "test", requestedSeconds: 1)))
        recorder.suspendWriterForTesting()
        let results = (0..<4).map { recorder.append(frame($0)) }
        recorder.resumeWriterForTesting()
        XCTAssertEqual(results, [true, true, false, false])
        let done = expectation(description: "finished")
        var snapshot: FrameStats.Snapshot?
        recorder.finish { result in
            snapshot = result.stats
            done.fulfill()
        }
        wait(for: [done], timeout: 10)
        XCTAssertEqual(snapshot?.frames, 4)
        XCTAssertEqual(snapshot?.writerDrops, 2)
        XCTAssertEqual(snapshot?.sustainedFPS ?? 0, 10, accuracy: 0.001)
        let json = try Data(contentsOf: folder.appendingPathComponent("clip.json"))
        let sidecar = try XCTUnwrap(JSONSerialization.jsonObject(with: json) as? [String: Any])
        let frames = try XCTUnwrap(sidecar["frames"] as? [[String: Any]])
        XCTAssertEqual(frames.map { $0["fileOffset"] as? Int }, [0, size, nil, nil])
        let raw = try Data(contentsOf: folder.appendingPathComponent("frames.raw"))
        XCTAssertEqual(raw.count, size * 2)
    }

    func testMeasureOnlyModeWritesNoFrames() throws {
        let (folder, sidecar) = try record(frames: 3, write: false)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("frames.raw").path))
        XCTAssertEqual((sidecar["frames"] as? [[String: Any]])?.count, 3)
    }

    func testPoolRejectsLayoutChange() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let recorder = try RawRecorder(config: .init(
            directory: folder, writeFrames: false, memoryBudget: 1 << 24,
            context: ClipContext(method: "test", lens: "test", format: "test", requestedSeconds: 1)))
        XCTAssertTrue(recorder.append(frame(0)))
        var other: CVPixelBuffer?
        CVPixelBufferCreate(nil, 32, 32, kCVPixelFormatType_OneComponent16, nil, &other)
        let changed = RawFrame(buffer: other!, pts: 1, exposureSeconds: 0, iso: 0, whiteBalanceGains: [])
        XCTAssertFalse(recorder.append(changed))
        let done = expectation(description: "finished")
        recorder.finish { _ in done.fulfill() }
        wait(for: [done], timeout: 10)
    }
}

final class ExposureScalesTests: XCTestCase {
    func testShutterFloorFollowsFrameRate() {
        XCTAssertEqual(ExposureScales.shutterStops(fps: 24, mains: 50).first?.value, 24)
        XCTAssertEqual(ExposureScales.shutterStops(fps: 25, mains: 50).first?.value, 25)
        XCTAssertEqual(ExposureScales.shutterStops(fps: 30, mains: 50).first?.value, 30)
    }

    func testDecimalRatesAreExactAndNamedLikeCameras() {
        XCTAssertEqual(FrameRates.all.map(FrameRates.label), ["24", "25", "30"])
        XCTAssertEqual(FrameRates.label(24000.0 / 1001), "23.98")
        XCTAssertTrue(FrameRates.frameTime(24000.0 / 1001) == (1001, 24000))
        XCTAssertTrue(FrameRates.frameTime(30000.0 / 1001) == (1001, 30000))
        XCTAssertTrue(FrameRates.frameTime(25) == (1, 25))
        for fps in FrameRates.all {
            let time = FrameRates.frameTime(fps)
            XCTAssertEqual(Int64(FrameRates.mediaTimeScale(fps)) * time.value % Int64(time.timescale), 0)
        }
    }

    func testDecimalRatesKeepShutterLabelsUnique() {
        for fps in FrameRates.all {
            let stops = ExposureScales.shutterStops(fps: fps, mains: 60)
            XCTAssertEqual(stops.first?.value, fps)
            XCTAssertEqual(Set(stops.map(\.label)).count, stops.count)
            XCTAssertTrue(stops.allSatisfy { !$0.label.isEmpty })
        }
        let ntsc = ExposureScales.shutterStops(fps: 30000.0 / 1001, mains: 60)
        XCTAssertEqual(ntsc.first?.label, "1/30")
        XCTAssertTrue(ntsc.contains { $0.value == 60 && $0.isMajor })
    }

    func testShutterFollowsSlowerFrameRates() {
        let cinema = ExposureScales.shutterStops(fps: 24, mains: 50).map(\.value)
        XCTAssertEqual(cinema.first, 24)
        XCTAssertTrue(cinema.contains(48))
        let pal = ExposureScales.shutterStops(fps: 25, mains: 50).map(\.value)
        XCTAssertEqual(pal.first, 25)
        XCTAssertTrue(pal.contains(50))
    }

    func testShutterHasNoStopBelowFrameRateAndHasHalfAngle() {
        let values = ExposureScales.shutterStops(fps: 30, mains: 50).map(\.value)
        XCTAssertTrue(values.allSatisfy { $0 >= 30 })
        XCTAssertTrue(values.contains(60))
        XCTAssertEqual(values, values.sorted())
    }

    func testFlickerSafeStopsFollowMains() {
        let europe = ExposureScales.shutterStops(fps: 30, mains: 50).filter(\.isMajor).map(\.value)
        let america = ExposureScales.shutterStops(fps: 30, mains: 60).filter(\.isMajor).map(\.value)
        XCTAssertEqual(europe, [50, 100])
        XCTAssertEqual(america, [60, 120])
    }

    func testIsoStopsStayInsideLensRange() {
        let stops = ExposureScales.isoStops(range: 57...12768)
        XCTAssertEqual(stops.first?.label, "BASE")
        XCTAssertEqual(stops.first?.value, 57)
        XCTAssertEqual(stops.last?.value, 12768)
        XCTAssertEqual(ExposureScales.isoStops(range: 21...2688).first?.value, 21)
    }

    func testPositionInterpolatesAndClamps() {
        let stops = ExposureScales.whiteBalanceStops()
        XCTAssertEqual(ExposureScales.position(of: 2500, in: stops), 0)
        XCTAssertEqual(ExposureScales.position(of: 1000, in: stops), 0)
        XCTAssertEqual(ExposureScales.position(of: 9000, in: stops), Double(stops.count - 1))
        XCTAssertEqual(ExposureScales.position(of: 3000, in: stops), 1.5, accuracy: 0.001)
    }

    func testFineStopsReachBothEnds() {
        let stops = ExposureScales.fineStops(geometric: 30...8000, perStop: 6)
        XCTAssertEqual(stops.first?.value, 30)
        XCTAssertEqual(stops.last?.value ?? 0, 8000, accuracy: 100)
    }
}

final class TakeAccountingTests: XCTestCase {
    func testDuplicateFramesGoNoFurther() {
        let stats = FrameStats()
        XCTAssertTrue(stats.recordFrame(pts: 1))
        XCTAssertFalse(stats.recordFrame(pts: 1))
        XCTAssertFalse(stats.recordFrame(pts: 1.00000001))
        XCTAssertTrue(stats.recordFrame(pts: 1.033))
        let snapshot = stats.snapshot()
        XCTAssertEqual(snapshot.frames, 2)
        XCTAssertEqual(snapshot.duplicates, 2)
    }

    func testExpectedRateCountsFramesLostEvenly() {
        let stats = FrameStats()
        stats.setExpectedRate(30)
        // Every third frame is lost, so the median gap alone looks steady.
        for index in 0..<201 { stats.recordFrame(pts: Double(index) * 0.05) }
        XCTAssertEqual(stats.snapshot().estimatedMissed, 100)
    }

    func testViewfinderYieldsWhileBehindAndHolds() {
        var pacer = MonitorPacer()
        XCTAssertTrue(pacer.decide(behind: false, hot: false).draw)
        var draws = 0
        var yields = 0
        for index in 0..<MonitorPacer.holdFrames {
            let pace = pacer.decide(behind: index == 0, hot: false)
            draws += pace.draw ? 1 : 0
            yields += pace.yielded ? 1 : 0
        }
        XCTAssertGreaterThan(draws, 0, "The picture must keep moving")
        XCTAssertLessThan(draws, yields)
        XCTAssertTrue(pacer.decide(behind: false, hot: false).draw)
    }

    func testHotPacingNeedsNoBacklog() {
        var pacer = MonitorPacer()
        let draws = (0..<30).filter { _ in pacer.decide(behind: false, hot: true).draw }
        XCTAssertEqual(draws.count, 10)
    }

    func testShutterPriorityMovesISOTowardTheMeter() {
        let range: ClosedRange<Float> = 50...3200
        XCTAssertNil(ShutterPriority.nextISO(current: 400, offset: 0.1, range: range))
        XCTAssertLessThan(try XCTUnwrap(ShutterPriority.nextISO(current: 400, offset: 1, range: range)), 400)
        XCTAssertGreaterThan(try XCTUnwrap(ShutterPriority.nextISO(current: 400, offset: -1, range: range)), 400)
        XCTAssertEqual(ShutterPriority.nextISO(current: 3000, offset: -4, range: range), 3200)
        XCTAssertNil(ShutterPriority.nextISO(current: 3200, offset: -4, range: range))
    }

    func testFileTagsOnlyChangeTheTags() throws {
        let preset = try XCTUnwrap(EncoderPreset.all.first { $0.id == "prores422hq" })
        let hlg = preset.outputSettings(width: 8, height: 8, tag: .hlg)
        let properties = try XCTUnwrap(hlg[AVVideoColorPropertiesKey] as? [String: String])
        XCTAssertEqual(properties[AVVideoTransferFunctionKey], AVVideoTransferFunction_ITU_R_2100_HLG)
        let plain = preset.outputSettings(width: 8, height: 8)
        let nominal = try XCTUnwrap(plain[AVVideoColorPropertiesKey] as? [String: String])
        XCTAssertEqual(nominal[AVVideoColorPrimariesKey], AVVideoColorPrimaries_ITU_R_2020)
    }

    func testPeakingThresholds() {
        XCTAssertEqual(PeakingSensitivity.low.threshold, 0.15)
        XCTAssertLessThan(PeakingSensitivity.high.threshold, PeakingSensitivity.low.threshold)
    }

    func testOlderSidecarsHaveNoNewCounts() throws {
        let json = #"{"file":"a.mov","preset":"p","width":1,"height":1,"framesWritten":1,"framesDropped":0,"droppedNoBuffer":0,"droppedNotReady":0,"audioSamplesWritten":0,"seconds":1,"fps":1,"megabytes":1,"megabytesPerSecond":1,"metadata":{}}"#
        let result = try JSONDecoder().decode(VideoEncoder.Result.self, from: Data(json.utf8))
        XCTAssertNil(result.droppedAtGPU)
        XCTAssertNil(result.duplicates)
    }
}

final class TestLinkTests: XCTestCase {
    func testServerAddresses() {
        XCTAssertEqual(TestLinkAddress.base("192.168.1.20")?.absoluteString, "http://192.168.1.20:8765")
        XCTAssertEqual(TestLinkAddress.base(" 192.168.1.20:9000 ")?.absoluteString, "http://192.168.1.20:9000")
        XCTAssertEqual(TestLinkAddress.base("http://box.local:8765/x")?.absoluteString, "http://box.local:8765")
        XCTAssertNil(TestLinkAddress.base(""))
        XCTAssertNil(TestLinkAddress.base("ftp://box"))
        // Over the internet, only a tunnel's https address, on its own port; on the network, never one.
        XCTAssertEqual(
            TestLinkAddress.base("https://abc-123.ngrok-free.app/", overInternet: true)?.absoluteString,
            "https://abc-123.ngrok-free.app")
        XCTAssertEqual(
            TestLinkAddress.base("HTTPS://box.example:8443", overInternet: true)?.absoluteString, "https://box.example:8443")
        XCTAssertNil(TestLinkAddress.base("https://abc-123.ngrok-free.app"))
        XCTAssertNil(TestLinkAddress.base("192.168.1.20", overInternet: true))
        XCTAssertNil(TestLinkAddress.base("http://box.local:8765", overInternet: true))
    }

    func testFileNamesStayInTheirFolder() {
        XCTAssertEqual(TestLinkAddress.safeName("video.mov"), "video.mov")
        XCTAssertEqual(TestLinkAddress.safeName("../../secret"), "secret")
        XCTAssertNil(TestLinkAddress.safeName(".."))
        XCTAssertNil(TestLinkAddress.safeName(""))
    }

    func testPreviewIsASmallJPEG() throws {
        let still = ProcessedStill(
            pixels: Data(count: 64 * 48 * 8), width: 64, height: 48, settings: ProcessingSettings(),
            exposureSeconds: 0.01, iso: 100, whiteBalanceGains: [1, 1, 1])
        let data = try XCTUnwrap(StillExporter.preview(still, width: 16))
        XCTAssertEqual(Array(data.prefix(2)), [0xFF, 0xD8])
    }

    func testPoints() {
        let point = TestLinkAddress.point("0.25, 0.5")
        XCTAssertEqual(point?.x, 0.25)
        XCTAssertEqual(point?.y, 0.5)
        XCTAssertNil(TestLinkAddress.point("0.5"))
        XCTAssertNil(TestLinkAddress.point("0.5,2"))
    }

    func testCommandsDecodeWithoutOptionalFields() throws {
        let command = try JSONDecoder().decode(TestCommand.self, from: Data(#"{"id":3,"action":"status"}"#.utf8))
        XCTAssertEqual(command, TestCommand(id: 3, action: "status"))
    }
}

final class AppConfigTests: XCTestCase {
    func testRoundTrip() throws {
        var config = AppConfig()
        config.codec = "prores4444"
        config.toolbar = ["grid"]
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try config.save(to: url)
        XCTAssertEqual(try AppConfig.load(from: url), config)
    }

    func testMissingAndMistypedKeysKeepDefaults() throws {
        let json = #"{"codec": "hevc420", "mainsHz": "sixty"}"#
        let config = try JSONDecoder().decode(AppConfig.self, from: Data(json.utf8))
        XCTAssertEqual(config.codec, "hevc420")
        XCTAssertEqual(config.mainsHz, 50)
        XCTAssertEqual(config.telemetry, true)
    }

    func testFrameRateAndPresetsRoundTrip() throws {
        var config = AppConfig()
        config.frameRate = 24
        config.presets = [night]
        let data = try JSONEncoder().encode(config)
        XCTAssertEqual(try JSONDecoder().decode(AppConfig.self, from: data), config)
    }

    func testOlderFilesKeepThirtyFramesAndNoPresets() throws {
        let config = try JSONDecoder().decode(AppConfig.self, from: Data("{}".utf8))
        XCTAssertEqual(config.frameRate, 30)
        XCTAssertTrue(config.presets.isEmpty)
        XCTAssertEqual(config.defaultPreset, "")
        XCTAssertEqual(config.peakingSensitivity, "low")
        XCTAssertTrue(config.fixedFrameTime)
        XCTAssertEqual(config.testServer, "")
        XCTAssertFalse(config.distortionCorrection)
        XCTAssertTrue(config.efficientWhenHot)
        XCTAssertFalse(config.bilinearWhenHot)
        XCTAssertEqual(config.idlePauseMinutes, 2)
        XCTAssertEqual(config.fileTag, "rec2020")
        XCTAssertTrue(config.stereoAudio)
        XCTAssertFalse(config.twelveBitProRes)
    }

    private var night: FormatPreset {
        var settings = AppConfig()
        settings.codec = "prores4444"
        settings.frameRate = 25
        settings.nativeGamut = true
        settings.gamut = "S-Gamut3"
        settings.curveGamuts = ["S-Log3": "S-Gamut3"]
        settings.curveLUTs = [AppConfig.lutKey(curve: "S-Log3", gamut: "S-Gamut3"): "Night.cube"]
        settings.twelveBitProRes = true
        settings.mainsHz = 60
        settings.pcmAudio = true
        settings.activeTools = ["grid"]
        settings.overlay = 2
        settings.testServer = "should not stay"
        return FormatPreset(name: "Night", settings: settings)
    }

    func testPresetsKeepEverySettingExceptTheLink() {
        XCTAssertEqual(night.settings.testServer, "")
        var config = AppConfig()
        config.testServer = "box:8765"
        config.testToken = "123"
        config.presets = [night]
        config.defaultPreset = "Night"
        config.use(night)
        XCTAssertEqual(config.mainsHz, 60)
        XCTAssertTrue(config.pcmAudio)
        XCTAssertEqual(config.activeTools, ["grid"])
        XCTAssertEqual(config.overlay, 2)
        XCTAssertEqual(config.gamut, "S-Gamut3")
        XCTAssertEqual(config.curveGamuts, ["S-Log3": "S-Gamut3"])
        XCTAssertEqual(config.curveLUTs.values.first, "Night.cube")
        XCTAssertTrue(config.twelveBitProRes)
        XCTAssertEqual(config.testServer, "box:8765")
        XCTAssertEqual(config.testToken, "123")
        XCTAssertEqual(config.presets, [night])
        XCTAssertEqual(config.defaultPreset, "Night")
    }

    func testStartupPresetNeedsADefaultThatExists() {
        var config = AppConfig()
        config.presets = [night]
        XCTAssertNil(config.startupPreset)
        config.defaultPreset = "Night"
        XCTAssertEqual(config.startupPreset, night)
        config.defaultPreset = "Deleted"
        XCTAssertNil(config.startupPreset)
    }

    func testOlderPresetsKeepTheirChoices() throws {
        let json = #"{"name":"Old","codec":"prores4444","size":"2880x2160","widescreen":true,"frameRate":25,"logCurve":"S-Log3","pipeline":"efficient","debayer":"Bilinear","exposureOffset":0.3}"#
        let preset = try JSONDecoder().decode(FormatPreset.self, from: Data(json.utf8))
        XCTAssertEqual(preset.name, "Old")
        XCTAssertEqual(preset.settings.codec, "prores4444")
        XCTAssertEqual(preset.settings.frameRate, 25)
        XCTAssertTrue(preset.settings.widescreen)
        XCTAssertEqual(preset.settings.mainsHz, AppConfig().mainsHz)
    }
}

final class AppleLog2Tests: XCTestCase {
    func testItSharesAppleLogsCurve() {
        for value in [0.0, 0.01, 0.18, 0.9, 4] {
            XCTAssertEqual(LogCurve.appleLog2.encode(value), LogCurve.appleLog.encode(value))
        }
        XCTAssertEqual(LogCurve.appleLog2.decode(0.5), LogCurve.appleLog.decode(0.5))
    }

    func testItAlwaysRecordsAppleWideGamut() {
        var settings = ProcessingSettings()
        settings.pairsGamut = false
        settings.curve = .appleLog2
        XCTAssertEqual(settings.gamut, .appleWideGamut)
        settings.restore(curve: .appleLog2, gamut: .rec2020)
        XCTAssertEqual(settings.gamut, .appleWideGamut)
    }

    func testChoosingRec2020ReturnsToAppleLog() {
        var settings = ProcessingSettings()
        settings.gamut = .appleWideGamut
        XCTAssertEqual(settings.curve, .appleLog2)
        settings.gamut = .rec2020
        XCTAssertEqual(settings.curve, .appleLog)
        XCTAssertEqual(settings.gamut, .rec2020)
        // Unpaired too: Apple Log 2 can't leave its gamut, so it becomes the pair's curve.
        settings.curve = .appleLog2
        settings.pairsGamut = false
        settings.gamut = .rec2020
        XCTAssertEqual(settings.curve, .appleLog)
    }
}

final class GamutTests: XCTestCase {
    private func xyz(_ x: Double, _ y: Double) -> SIMD3<Double> {
        SIMD3(x / y, 1, (1 - x - y) / y)
    }

    func testPrimariesLandOnTheirOwnAxis() {
        let cases: [(Gamut, Double, Double)] = [
            (.sGamut3, 0.730, 0.280), (.arriWideGamut3, 0.6840, 0.3130), (.appleWideGamut, 0.725, 0.301),
            (.sGamut, 0.730, 0.280), (.arriWideGamut4, 0.7347, 0.2653), (.cinemaGamut, 0.74, 0.27),
            (.sGamut3Cine, 0.766, 0.275),
        ]
        for (gamut, x, y) in cases {
            let red = gamut.fromRec2020 * ColorMath.xyzToRec2020 * xyz(x, y)
            XCTAssertEqual(red.y / red.x, 0, accuracy: 0.001)
            XCTAssertEqual(red.z / red.x, 0, accuracy: 0.001)
        }
    }

    func testWhiteStaysWhite() {
        for gamut in Gamut.allCases {
            let white = gamut.fromRec2020 * SIMD3<Double>(repeating: 1)
            XCTAssertEqual(white.x, 1, accuracy: 0.002)
            XCTAssertEqual(white.y, 1, accuracy: 0.002)
            XCTAssertEqual(white.z, 1, accuracy: 0.002)
        }
    }

    func testSLog3RecordsSGamut3CineByDefault() {
        var settings = ProcessingSettings()
        settings.curve = .sLog3
        XCTAssertEqual(settings.gamut, .sGamut3Cine)
        // S-Gamut3 stays available, and keeps S-Log3.
        settings.gamut = .sGamut3
        XCTAssertEqual(settings.curve, .sLog3)
        XCTAssertEqual(settings.gamut, .sGamut3)
    }

    func testPairingMakesEitherChoiceSetTheOther() {
        var settings = ProcessingSettings()
        XCTAssertTrue(settings.pairsGamut)
        for curve in LogCurve.allCases {
            settings.curve = curve
            XCTAssertEqual(settings.gamut, curve.nativeGamut, "\(curve)")
        }
        for gamut in Gamut.allCases {
            settings.gamut = gamut
            XCTAssertEqual(settings.curve, gamut.standardCurve, "\(gamut)")
            XCTAssertEqual(settings.gamut, gamut, "\(gamut)")
        }
        settings.gamut = .rec2020
        XCTAssertEqual(settings.curve, .appleLog)
    }

    func testUnpairedChoicesChangeAlone() {
        var settings = ProcessingSettings()
        settings.curve = .logC4
        settings.pairsGamut = false
        XCTAssertEqual(settings.gamut, .arriWideGamut4)
        settings.gamut = .rec2020
        XCTAssertEqual(settings.curve, .logC4)
        settings.curve = .sLog3
        XCTAssertEqual(settings.gamut, .rec2020)
        settings.gamut = .arriWideGamut3
        XCTAssertEqual(settings.curve, .sLog3)
    }

    func testEditedPairsAreFollowedAndSaved() {
        var settings = ProcessingSettings()
        settings.curve = .sLog3
        settings.pairing.setGamut(.sGamut3, for: .sLog3)
        // Editing the current curve's row moves the gamut with it.
        XCTAssertEqual(settings.gamut, .sGamut3)
        settings.pairing.setCurve(.canonLog3, for: .rec2020)
        settings.gamut = .rec2020
        XCTAssertEqual(settings.curve, .canonLog3)

        let saved = GamutPairing(gamutLabels: settings.pairing.gamutLabels, curveLabels: settings.pairing.curveLabels)
        XCTAssertEqual(saved, settings.pairing)
        XCTAssertEqual(saved.gamut(for: .sLog3), .sGamut3)
        XCTAssertEqual(saved.curve(for: .rec2020), .canonLog3)
        XCTAssertEqual(saved.gamut(for: .logC3), .arriWideGamut3)
        // Only changes are stored, so the standard table saves nothing.
        XCTAssertTrue(GamutPairing.standard.gamutLabels.isEmpty)
    }

    func testPairsThatDontFitAreRefused() {
        var pairing = GamutPairing.standard
        pairing.setGamut(.appleWideGamut, for: .sLog3)
        XCTAssertEqual(pairing.gamut(for: .sLog3), .sGamut3Cine)
        pairing.setCurve(.appleLog2, for: .rec2020)
        XCTAssertEqual(pairing.curve(for: .rec2020), .appleLog)
        let read = GamutPairing(gamutLabels: ["S-Log3": "Apple Wide Gamut", "Gone": "Rec.2020"], curveLabels: [:])
        XCTAssertEqual(read, .standard)
    }

    func testEveryStandardPairFits() {
        for curve in LogCurve.allCases {
            XCTAssertTrue(GamutPairing.gamuts(for: curve).contains(curve.nativeGamut), "\(curve)")
        }
        for gamut in Gamut.allCases {
            XCTAssertTrue(GamutPairing.curves(for: gamut).contains(gamut.standardCurve), "\(gamut)")
        }
    }

    func testMonitorKeepsGrayInEveryGamut() {
        let curve = LogCurve.sLog3
        let log = SIMD3<Double>(repeating: curve.encode(0.18))
        let plain = MonitorTransform.display(log: log, curve: curve)
        let native = MonitorTransform.display(log: log, curve: curve, gamut: .sGamut3)
        XCTAssertEqual(native.x, plain.x, accuracy: 0.01)
        XCTAssertEqual(native.y, plain.y, accuracy: 0.01)
        XCTAssertEqual(native.z, plain.z, accuracy: 0.01)
    }
}

final class TakeReadingsTests: XCTestCase {
    func testFrozenTakesNameTheirValues() {
        var readings = TakeReadings()
        for _ in 0..<3 { readings.add(seconds: 1.0 / 50, iso: 937, temperature: 5612, tint: 3) }
        XCTAssertEqual(readings.shutter(.frozen), "1/50 s, frozen at start")
        XCTAssertEqual(readings.isoText(.frozen), "ISO 937, frozen at start")
        XCTAssertEqual(readings.whiteBalance(.frozen), "5612 K, tint +3, frozen at start")
        XCTAssertEqual(readings.shutter(.manual), "1/50 s, manual")
    }

    func testAutoTakesGiveTheirRange() {
        var readings = TakeReadings()
        readings.add(seconds: 1.0 / 50, iso: 800, temperature: 5200, tint: 0)
        readings.add(seconds: 1.0 / 120, iso: 1250, temperature: 5800, tint: 2)
        XCTAssertEqual(readings.shutter(.auto), "auto, 1/50 to 1/120 s")
        XCTAssertEqual(readings.isoText(.auto), "auto, ISO 800 to 1250")
        XCTAssertEqual(readings.whiteBalance(.auto), "auto, 5200 to 5800 K")
    }

    func testNoReadingsStillSayTheMode() {
        XCTAssertEqual(TakeReadings().shutter(.auto), "auto")
        XCTAssertEqual(TakeReadings().isoText(.frozen), "frozen at start")
    }
}

final class GyroLogTests: XCTestCase {
    func testHeaderMatchesTheFormat() {
        let lines = GyroLog.header(
            videoName: "video_1.mov", startedAt: Date(timeIntervalSince1970: 1000), version: "0.1.0"
        ).split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        XCTAssertEqual(Array(lines.prefix(4)), ["GYROFLOW IMU LOG", "version,1.3", "id,vibelog", "orientation,yXZ"])
        XCTAssertTrue(lines.contains("timestamp,1000"))
        XCTAssertTrue(lines.contains("videofilename,video_1.mov"))
        XCTAssertTrue(lines.contains("tscale,0.000001"))
        XCTAssertEqual(lines.suffix(2), ["t,gx,gy,gz,ax,ay,az", ""])
    }

    func testLineScalesFromTheFirstFrame() {
        let sample = MotionSample(
            seconds: 100.25, rotation: SIMD3(0.5, -0.25, 0), acceleration: SIMD3(0, 0.1, 1))
        XCTAssertEqual(GyroLog.line(sample, firstFrame: 100), "250000,50000,-25000,0,0,1000,10000\n")
    }
}

final class TakeLibraryTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: folder)
    }

    private func makeTake(_ name: String, sidecar: Bool) throws -> URL {
        let url = folder.appendingPathComponent(name)
        try Data(count: 10).write(to: url)
        guard sidecar else { return url }
        let result = VideoEncoder.Result(
            file: name, preset: "ProRes 422 HQ", width: 4032, height: 3024, framesWritten: 240,
            framesDropped: 2, droppedNoBuffer: 2, droppedNotReady: 0, audioSamplesWritten: 10,
            seconds: 10, fps: 24, megabytes: 1600, megabytesPerSecond: 160, failure: nil,
            metadata: ["frameRate": "24"])
        try JSONEncoder().encode(result).write(to: TakeLibrary.sidecar(for: url))
        return url
    }

    func testListsNewestFirstWithSidecars() throws {
        _ = try makeTake("video_20260101_100000.mov", sidecar: false)
        _ = try makeTake("video_20260102_100000.mov", sidecar: true)
        let takes = TakeLibrary.takes(in: folder)
        XCTAssertEqual(takes.map(\.url.lastPathComponent), ["video_20260102_100000.mov", "video_20260101_100000.mov"])
        XCTAssertEqual(takes[0].info?.metadata["frameRate"], "24")
        XCTAssertEqual(takes[0].bytes, 10)
        XCTAssertNil(takes[1].info)
    }

    func testDeleteRemovesTheSidecarToo() throws {
        let url = try makeTake("video_20260102_100000.mov", sidecar: true)
        try TakeLibrary.delete(TakeLibrary.take(at: url))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), [])
    }

    func testGyroLogSharesAndDeletesWithItsTake() throws {
        let url = try makeTake("video_20260102_100000.mov", sidecar: true)
        let gyro = TakeLibrary.gyroLog(for: url)
        XCTAssertEqual(gyro.lastPathComponent, "video_20260102_100000.gcsv")
        try Data(count: 4).write(to: gyro)
        let take = TakeLibrary.take(at: url)
        XCTAssertEqual(take.files, [url, gyro])
        try TakeLibrary.delete(take)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), [])
    }

    func testDeleteLeavesOtherTakesAlone() throws {
        let first = try makeTake("video_20260101_100000.mov", sidecar: true)
        let second = try makeTake("video_20260102_100000.mov", sidecar: true)
        try TakeLibrary.delete(TakeLibrary.take(at: first))
        XCTAssertEqual(TakeLibrary.takes(in: folder).map(\.url.lastPathComponent), [second.lastPathComponent])
        XCTAssertTrue(FileManager.default.fileExists(atPath: TakeLibrary.sidecar(for: second).path))
    }
}


/// The ACES ports against OpenColorIO's own output for the same colours, in ACESReference.
final class ACESTests: XCTestCase {
    private func worst(_ look: BuiltInLook, _ expected: [SIMD3<Double>]) -> (error: Double, index: Int, got: SIMD3<Double>) {
        var worst = (error: 0.0, index: 0, got: SIMD3<Double>())
        for (index, sample) in ACESReference.samples.enumerated() {
            let got = look.display(linearRec2020: sample)
            let difference = got - expected[index]
            let error = max(abs(difference.x), abs(difference.y), abs(difference.z))
            if error > worst.error || error.isNaN { worst = (error.isNaN ? .infinity : error, index, got) }
        }
        return worst
    }

    func testACES20MatchesOpenColorIO() {
        let result = worst(.aces20, ACESReference.aces20)
        XCTAssertLessThan(
            result.error, 0.002,
            "sample \(result.index) \(ACESReference.samples[result.index]): got \(result.got), "
                + "OpenColorIO \(ACESReference.aces20[result.index])")
    }

    /// OpenColorIO's ACES 1.3 Rec.709 view leaves out-of-gamut colours above 1, where the Academy's
    /// ODT clamps to the display, as this port does, so the reference is clamped the same way. The
    /// rest differs by about 0.0002, at black.
    func testACES13MatchesOpenColorIO() {
        let clamped = ACESReference.aces13.map { simd_clamp($0, SIMD3(repeating: 0), SIMD3(repeating: 1)) }
        let result = worst(.aces13, clamped)
        XCTAssertLessThan(
            result.error, 0.001,
            "sample \(result.index) \(ACESReference.samples[result.index]): got \(result.got), "
                + "OpenColorIO \(clamped[result.index])")
    }

    func testMiddleGrayLandsWhereACESPutsIt() {
        let gray = SIMD3<Double>(repeating: 0.18)
        XCTAssertEqual(BuiltInLook.aces20.display(linearRec2020: gray).y, 0.38312, accuracy: 0.001)
        XCTAssertEqual(BuiltInLook.aces13.display(linearRec2020: gray).y, 0.38953, accuracy: 0.001)
    }

    /// Each grid point of the built LUT is the transform of that log value, decoded.
    func testLookLUTDecodesTheCurve() {
        let size = 9
        let lut = BuiltInLook.aces20.lut(curve: .sLog3, gamut: .sGamut3Cine, size: size)
        XCTAssertEqual(lut.samples.count, size * size * size)
        let toRec2020 = BuiltInLook.acesInput(.sGamut3Cine)
        for (r, g, b) in [(0, 0, 0), (4, 4, 4), (8, 2, 5), (3, 7, 1)] {
            let log = SIMD3(Double(r), Double(g), Double(b)) / Double(size - 1)
            let linear = toRec2020 * SIMD3(LogCurve.sLog3.decode(log.x), LogCurve.sLog3.decode(log.y), LogCurve.sLog3.decode(log.z))
            let expected = BuiltInLook.aces20.display(linearRec2020: linear)
            let got = lut.samples[(b * size + g) * size + r]
            XCTAssertEqual(Double(got.x), expected.x, accuracy: 1e-5)
            XCTAssertEqual(Double(got.y), expected.y, accuracy: 1e-5)
            XCTAssertEqual(Double(got.z), expected.z, accuracy: 1e-5)
        }
    }

    /// Log codes through VibeLog's ACES 2.0 look match OpenColorIO's own camera inputs to the same
    /// view, from tools/check_camera_inputs.py's config, now that the look takes the vendors'
    /// matrices to ACES. OCIO's values above 1 are clamped, as the port clamps to the display.
    func testACESLookMatchesOCIOCameraInputs() {
        let codes: [SIMD3<Double>] = [SIMD3(0.5, 0.5, 0.5), SIMD3(0.62, 0.41, 0.3), SIMD3(0.35, 0.55, 0.62), SIMD3(0.7, 0.3, 0.6)]
        let references: [(LogCurve, Gamut, [[Double]])] = [
            (.sLog3, .sGamut3, [[0.550278, 0.550277, 0.550278], [1.000006, 0.312072, 0.244938], [0.0, 0.628108, 0.752428], [1.000006, 0.338382, 0.669042]]),
            (.sLog3, .sGamut3Cine, [[0.550278, 0.550277, 0.550278], [0.981475, 0.279395, 0.126602], [0.023624, 0.622618, 0.785113], [1.000006, 0.294677, 0.684274]]),
            (.logC3, .arriWideGamut3, [[0.593558, 0.593558, 0.593558], [1.000006, 0.452447, 0.289412], [0.0, 0.639387, 0.83678], [1.000006, 0.381372, 0.713242]]),
            (.logC4, .arriWideGamut4, [[0.842817, 0.842817, 0.842817], [1.000006, 0.635085, 0.602157], [0.567462, 0.888606, 1.000006], [1.000006, 0.723834, 0.830347]]),
            (.canonLog3, .cinemaGamut, [[0.61842, 0.61842, 0.61842], [0.998049, 0.436189, 0.28252], [0.0, 0.671739, 0.794417], [1.000006, 0.302923, 0.745904]]),
        ]
        for (curve, gamut, outputs) in references {
            let input = BuiltInLook.acesInput(gamut)
            for (code, reference) in zip(codes, outputs) {
                let linear = input * SIMD3(curve.decode(code.x), curve.decode(code.y), curve.decode(code.z))
                let got = BuiltInLook.aces20.display(linearRec2020: linear)
                for channel in 0..<3 {
                    XCTAssertEqual(got[channel], min(reference[channel], 1), accuracy: 0.003, "\(curve.label) \(gamut.label) \(code)")
                }
            }
        }
    }

    func testBuiltInLooksCantClashWithFiles() {
        for look in BuiltInLook.allCases {
            XCTAssertFalse(look.name.lowercased().hasSuffix(".cube"))
            XCTAssertEqual(BuiltInLook.named(look.name), look)
        }
        XCTAssertNil(BuiltInLook.named("ACES 2.0.cube"))
    }
}

/// The grade under the built-in looks: neutral changes nothing, and each slider does what it says.
final class LookGradeTests: XCTestCase {
    private let gray = SIMD3<Double>(repeating: 0.18)

    func testNeutralGradeLeavesTheLookAsItIs() {
        let plain = BuiltInLook.aces20.lut(curve: .appleLog, gamut: .rec2020, size: 9)
        let graded = BuiltInLook.aces20.lut(curve: .appleLog, gamut: .rec2020, grade: LookGrade(), size: 9)
        XCTAssertEqual(plain.samples, graded.samples)
        XCTAssertTrue(LookGrade().isNeutral)
        XCTAssertEqual(LookGrade().label, "none")
    }

    func testExposureMovesMiddleGrayByStops() {
        var grade = LookGrade()
        grade.exposure = 1
        let out = GradeTransform(grade).apply(gray)
        XCTAssertEqual(out.x, 0.36, accuracy: 1e-9)
        XCTAssertEqual(out.z, 0.36, accuracy: 1e-9)
        // Through the tone curve, a stop up is brighter but rolls off below double.
        let before = BuiltInLook.aces20.display(linearRec2020: gray).y
        let after = BuiltInLook.aces20.display(linearRec2020: out).y
        XCTAssertGreaterThan(after, before)
        XCTAssertLessThan(after, before * 2)
    }

    func testContrastPivotsAtMiddleGray() {
        var grade = LookGrade()
        grade.contrast = 0.5
        let transform = GradeTransform(grade)
        XCTAssertEqual(transform.apply(gray).y, 0.18, accuracy: 1e-9)
        XCTAssertGreaterThan(transform.apply(gray * 2).y, 0.36)
        XCTAssertLessThan(transform.apply(gray / 2).y, 0.09)
        // Neutrals stay neutral.
        let bright = transform.apply(gray * 4)
        XCTAssertEqual(bright.x, bright.z, accuracy: 1e-9)
    }

    func testNoSaturationGivesNeutralOutput() {
        var grade = LookGrade()
        grade.saturation = 0
        let lut = BuiltInLook.aces20.lut(curve: .sLog3, gamut: .sGamut3Cine, grade: grade, size: 9)
        for sample in lut.samples {
            XCTAssertEqual(sample.x, sample.y, accuracy: 2e-3)
            XCTAssertEqual(sample.y, sample.z, accuracy: 2e-3)
        }
    }

    func testWarmerAndMagentaMoveGray() {
        var warm = LookGrade()
        warm.temperature = 0.5
        let warmed = GradeTransform(warm).apply(gray)
        XCTAssertGreaterThan(warmed.x, warmed.z)
        var magenta = LookGrade()
        magenta.tint = 0.5
        let tinted = GradeTransform(magenta).apply(gray)
        XCTAssertLessThan(tinted.y, tinted.x)
        XCTAssertLessThan(tinted.y, tinted.z)
    }

    /// A colour by Oklab lightness, chroma and hue in degrees.
    private func colour(_ lightness: Double, _ chroma: Double, _ hue: Double) -> SIMD3<Double> {
        let angle = hue * .pi / 180
        return GradeTransform.rec2020(oklab: SIMD3(lightness, chroma * cos(angle), chroma * sin(angle)))
    }

    private func hueAndChroma(_ rgb: SIMD3<Double>) -> (hue: Double, chroma: Double) {
        let lab = GradeTransform.oklab(rgb)
        var hue = atan2(lab.z, lab.y) * 180 / .pi
        if hue < 0 { hue += 360 }
        return (hue, (lab.y * lab.y + lab.z * lab.z).squareRoot())
    }

    func testColourBandsLeaveGraysAlone() {
        var grade = LookGrade()
        grade.bands[ColorBand.red.rawValue].saturation = 1
        grade.bands[ColorBand.skin.rawValue].hue = 1
        let out = GradeTransform(grade).apply(gray)
        XCTAssertEqual(out.x, 0.18, accuracy: 1e-6)
        XCTAssertEqual(out.z, 0.18, accuracy: 1e-6)
    }

    func testRedHueTurnsRedOnly() {
        var grade = LookGrade()
        grade.bands[ColorBand.red.rawValue].hue = 0.5
        let transform = GradeTransform(grade)
        let red = hueAndChroma(transform.apply(colour(0.6, 0.15, 29)))
        XCTAssertEqual(red.hue, 44, accuracy: 0.5)
        XCTAssertEqual(red.chroma, 0.15, accuracy: 1e-4)
        let blue = colour(0.5, 0.15, 264)
        let untouched = transform.apply(blue)
        XCTAssertEqual(untouched.x, blue.x, accuracy: 1e-9)
        XCTAssertEqual(untouched.z, blue.z, accuracy: 1e-9)
    }

    func testRedLuminanceIsAStop() {
        var grade = LookGrade()
        grade.bands[ColorBand.red.rawValue].luminance = 1
        let red = colour(0.6, 0.15, 29)
        let out = GradeTransform(grade).apply(red)
        XCTAssertEqual(out.x, red.x * 2, accuracy: 1e-6)
        XCTAssertEqual(out.y, red.y * 2, accuracy: 1e-6)
    }

    /// Skin is moderate chroma, so draining it leaves a vivid colour of the same hue alone.
    func testSkinSparesVividColours() {
        var grade = LookGrade()
        grade.bands[ColorBand.skin.rawValue].saturation = -1
        let transform = GradeTransform(grade)
        XCTAssertLessThan(hueAndChroma(transform.apply(colour(0.65, 0.06, 50))).chroma, 1e-3)
        XCTAssertEqual(hueAndChroma(transform.apply(colour(0.65, 0.2, 50))).chroma, 0.2, accuracy: 1e-4)
    }

    /// A grade saved before colour bands existed reads back with every colour neutral.
    /// How far the 65-point ACES 2.0 LUT on log strays from the exact transform between its grid
    /// points, for each curve in its own gamut. It prints the figures. CI run 87 measured a median
    /// near 0.0002 for every curve, p99 0.024 to 0.044 and a max of 0.06 to 0.10, the large ones
    /// where ACES 2.0's gamut compression bends sharply between grid points, so it guards those
    /// levels rather than a bound the LUT can't meet.
    func testACESLUTInterpolationError() {
        var state: UInt64 = 0x9E3779B97F4A7C15
        func next() -> Double {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Double(state >> 11) / Double(1 << 53)
        }
        // Every curve at the viewfinder's 65 points, and three at the export's 129.
        let cases = LogCurve.allCases.map { ($0, 65) } + [LogCurve.appleLog, .sLog3, .canonLog3].map { ($0, 129) }
        for (curve, size) in cases {
            let gamut = curve.nativeGamut
            let cube = BuiltInLook.aces20.lut(curve: curve, gamut: gamut, size: size)
            let toRec2020 = BuiltInLook.acesInput(gamut)
            var worst = 0.0
            var worstShadow = 0.0
            var errors: [Double] = []
            for index in 0..<600 {
                // A third in deep shadows near the curve's black, where the curve bends hardest.
                let low = index % 3 == 0 ? 0.0 : 0.05
                let high = index % 3 == 0 ? 0.25 : 0.95
                let code = SIMD3((0..<3).map { _ in low + next() * (high - low) })
                let exact = BuiltInLook.aces20.display(
                    linearRec2020: toRec2020 * SIMD3(curve.decode(code.x), curve.decode(code.y), curve.decode(code.z)))
                let looked = cube.sample(SIMD3<Float>(Float(code.x), Float(code.y), Float(code.z)))
                let error = simd_reduce_max(simd_abs(SIMD3(Double(looked.x), Double(looked.y), Double(looked.z)) - exact))
                errors.append(error)
                worst = max(worst, error)
                if index % 3 == 0 { worstShadow = max(worstShadow, error) }
            }
            errors.sort()
            print(String(
                format: "LUT error %@ at %ld points: max %.4f, p99 %.4f, median %.5f, deep shadows max %.4f",
                curve.label, size, worst, errors[errors.count * 99 / 100], errors[errors.count / 2], worstShadow))
            XCTAssertLessThan(errors[errors.count / 2], 0.001, curve.label)
            XCTAssertLessThan(errors[errors.count * 99 / 100], 0.06, curve.label)
            XCTAssertLessThan(worst, 0.15, curve.label)
        }
    }

    /// The export preview stopped on 2026-11-07 when a graded LUT held a point that wasn't a
    /// number. This sends a 17-point grid of every curve through each look under each slider at
    /// its ends and prints how many points come out that way, as `NaN sweep` lines, to find the
    /// cause. Whatever it finds, a built LUT must hold only numbers.
    func testGradesGiveNumbers() {
        func grade(_ change: (inout LookGrade) -> Void) -> LookGrade {
            var grade = LookGrade()
            change(&grade)
            return grade
        }
        let grades: [(String, LookGrade)] = [
            ("exposure -2", grade { $0.exposure = -2 }), ("exposure +2", grade { $0.exposure = 2 }),
            ("contrast -1", grade { $0.contrast = -1 }), ("contrast +1", grade { $0.contrast = 1 }),
            ("temperature -1", grade { $0.temperature = -1 }), ("temperature +1", grade { $0.temperature = 1 }),
            ("tint -1", grade { $0.tint = -1 }), ("tint +1", grade { $0.tint = 1 }),
            ("saturation 0", grade { $0.saturation = 0 }), ("saturation 2", grade { $0.saturation = 2 }),
            ("red hue +1 sat +1 lum +1", grade {
                $0.bands[ColorBand.red.rawValue].hue = 1
                $0.bands[ColorBand.red.rawValue].saturation = 1
                $0.bands[ColorBand.red.rawValue].luminance = 1
            }),
            ("skin sat -1 lum -1", grade {
                $0.bands[ColorBand.skin.rawValue].saturation = -1
                $0.bands[ColorBand.skin.rawValue].luminance = -1
            }),
            ("shadows wheel full, lum -1", grade {
                $0.wheels[ToneRange.shadows.rawValue].x = 1
                $0.wheels[ToneRange.shadows.rawValue].luminance = -1
            }),
            ("highlights wheel full, lum +1", grade {
                $0.wheels[ToneRange.highlights.rawValue].y = -1
                $0.wheels[ToneRange.highlights.rawValue].luminance = 1
            }),
            ("everything at once", grade {
                $0.exposure = 2
                $0.contrast = 1
                $0.temperature = 1
                $0.tint = 1
                $0.saturation = 2
            }),
        ]
        let size = 17
        let looks: [(String, (SIMD3<Double>) -> SIMD3<Double>)] = [
            ("ACES 2.0", { BuiltInLook.aces20.display(linearRec2020: $0) }),
            ("ACES 1.3", { BuiltInLook.aces13.display(linearRec2020: $0) }),
            ("Monitor", MonitorTransform.display(linearRec2020:)),
        ]
        for curve in LogCurve.allCases {
            let gamut = curve.nativeGamut
            let toRec2020 = BuiltInLook.acesInput(gamut)
            let decoded = (0..<size).map { curve.decode(Double($0) / Double(size - 1)) }
            for (gradeName, chosen) in grades {
                let transform = GradeTransform(chosen)
                for (lookName, display) in looks {
                    var gradeBroken = 0
                    var lookBroken = 0
                    for blue in decoded {
                        for green in decoded {
                            for red in decoded {
                                let graded = transform.apply(toRec2020 * SIMD3(red, green, blue))
                                if !(graded.x.isFinite && graded.y.isFinite && graded.z.isFinite) {
                                    gradeBroken += 1
                                    continue
                                }
                                let out = display(graded)
                                if !(out.x.isFinite && out.y.isFinite && out.z.isFinite) { lookBroken += 1 }
                            }
                        }
                    }
                    if gradeBroken + lookBroken > 0 {
                        print("NaN sweep \(curve.label), \(gradeName), \(lookName): \(gradeBroken) from the grade, \(lookBroken) from the look")
                    }
                }
            }
            let lut = BuiltInLook.aces20.lut(curve: curve, gamut: gamut, grade: grades.last!.1, size: size)
            XCTAssertTrue(lut.samples.allSatisfy { $0.x.isFinite && $0.y.isFinite && $0.z.isFinite }, curve.label)
        }
    }

    /// The one grade the phone found that makes a NaN, exposure +2 with contrast +57 on Apple Log 2
    /// in Apple Wide Gamut, through ACES 2.0 at 65 points. Each such point is traced stage by stage
    /// through the transform and printed as `NaN trace` lines, which CI shows, so the stage that
    /// first stops giving a number can be fixed. The built LUT must still hold only numbers.
    func testTraceTheNaNGrade() {
        var grade = LookGrade()
        grade.exposure = 2
        grade.contrast = 0.57
        let size = 65
        let curve = LogCurve.appleLog2
        let gamut = Gamut.appleWideGamut
        let toRec2020 = BuiltInLook.acesInput(gamut)
        let transform = GradeTransform(grade)
        let decoded = (0..<size).map { curve.decode(Double($0) / Double(size - 1)) }
        let m = BuiltInLook.rec2020ToAP0
        var found = 0
        for blue in 0..<size {
            for green in 0..<size {
                for red in 0..<size {
                    let graded = transform.apply(toRec2020 * SIMD3(decoded[red], decoded[green], decoded[blue]))
                    let out = BuiltInLook.aces20.display(linearRec2020: graded)
                    guard !(out.x.isFinite && out.y.isFinite && out.z.isFinite) else { continue }
                    found += 1
                    guard found <= 3 else { continue }
                    print("NaN trace point \(found) at grid (\(red), \(green), \(blue)), graded \(graded)")
                    let ap0 = (m[0] * graded.x + m[1] * graded.y + m[2] * graded.z,
                               m[3] * graded.x + m[4] * graded.y + m[5] * graded.z,
                               m[6] * graded.x + m[7] * graded.y + m[8] * graded.z)
                    for (stage, value) in ACES2Renderer.shared.traceStages(ap0: ap0) {
                        print("NaN trace   \(stage): \(value)")
                    }
                }
            }
        }
        print("NaN trace found \(found) points")
        // CI run 90 traced it to gamut compression at J exactly 100, now held at zero.
        XCTAssertEqual(found, 0)
        let lut = BuiltInLook.aces20.lut(curve: curve, gamut: gamut, grade: grade, size: size)
        XCTAssertTrue(lut.samples.allSatisfy { $0.x.isFinite && $0.y.isFinite && $0.z.isFinite })
    }

    func testOlderGradeReadsWithoutBands() throws {
        let grade = try JSONDecoder().decode(LookGrade.self, from: Data(#"{"exposure":0.5}"#.utf8))
        XCTAssertEqual(grade.exposure, 0.5)
        XCTAssertEqual(grade.bands.count, ColorBand.allCases.count)
        XCTAssertTrue(grade.bands.allSatisfy(\.isNeutral))
        XCTAssertEqual(grade.wheels.count, ToneRange.allCases.count)
        XCTAssertTrue(grade.wheels.allSatisfy(\.isNeutral))
    }

    /// The three ranges share every brightness between them, and each owns its own end.
    func testToneWeightsAddUpToOne() {
        for stops in stride(from: -10.0, through: 10.0, by: 0.25) {
            let weights = GradeTransform.toneWeights(luminance: 0.18 * pow(2, stops))
            XCTAssertEqual(weights.sum(), 1, accuracy: 1e-9, "at \(stops) stops")
        }
        XCTAssertEqual(GradeTransform.toneWeights(luminance: 0.18).y, 1, accuracy: 1e-9)
        XCTAssertEqual(GradeTransform.toneWeights(luminance: 0.18 / 64).x, 1, accuracy: 1e-9)
        XCTAssertEqual(GradeTransform.toneWeights(luminance: 0.18 * 64).z, 1, accuracy: 1e-9)
    }

    /// A shadows push tints a dark gray toward its colour and leaves highlights and middle gray
    /// alone; shadow luminance lifts the dark gray a stop.
    func testShadowWheelWorksOnShadowsOnly() {
        var grade = LookGrade()
        grade.wheels[ToneRange.shadows.rawValue].x = 0.7
        grade.wheels[ToneRange.shadows.rawValue].luminance = 1
        let transform = GradeTransform(grade)
        let dark = SIMD3<Double>(repeating: 0.18 / 64)
        let out = transform.apply(dark)
        // Oklab's +a is toward red and magenta, away from green.
        XCTAssertGreaterThan(out.x, out.y)
        XCTAssertEqual(simd_dot(out, GradeTransform.luma) / simd_dot(dark, GradeTransform.luma), 2, accuracy: 0.15)
        let bright = SIMD3<Double>(repeating: 0.18 * 64)
        XCTAssertEqual(simd_length(transform.apply(bright) - bright), 0, accuracy: 1e-9)
        XCTAssertEqual(simd_length(transform.apply(gray) - gray), 0, accuracy: 1e-9)
    }

    /// An identity cube over the unit range, red fastest.
    private func identityCube(_ size: Int) -> CubeLUT {
        var samples: [SIMD3<Float>] = []
        for b in 0..<size { for g in 0..<size { for r in 0..<size {
            samples.append(SIMD3(Float(r), Float(g), Float(b)) / Float(size - 1))
        } } }
        return CubeLUT(size: size, samples: samples)
    }

    func testCubeSamplesBetweenGridPoints() {
        let cube = identityCube(5)
        let point = SIMD3<Float>(0.3, 0.55, 0.9)
        let got = cube.sample(point)
        XCTAssertEqual(got.x, point.x, accuracy: 1e-6)
        XCTAssertEqual(got.y, point.y, accuracy: 1e-6)
        XCTAssertEqual(got.z, point.z, accuracy: 1e-6)
        XCTAssertEqual(cube.sample(SIMD3(repeating: 2)), SIMD3(repeating: 1))
    }

    /// A grade folded in front of an imported LUT: with an identity cube, exposure +1 is exactly
    /// a stop up on the log curve, so the round trip from log to linear and back holds.
    func testGradeFoldsInFrontOfAnImportedLUT() {
        var grade = LookGrade()
        grade.exposure = 1
        let size = 9
        let lut = BuiltInLook.graded(
            identityCube(size), expectsRec709: false, curve: .sLog3, gamut: .sGamut3Cine, grade: grade, size: size)
        for (r, g, b) in [(4, 4, 4), (2, 5, 3), (6, 1, 4)] {
            let log = SIMD3(Double(r), Double(g), Double(b)) / Double(size - 1)
            let got = lut.samples[(b * size + g) * size + r]
            for channel in 0..<3 {
                let up = LogCurve.sLog3.encode(LogCurve.sLog3.decode(log[channel]) * 2)
                XCTAssertEqual(Double(got[channel]), min(up, 1), accuracy: 1e-4)
            }
        }
    }

    /// The Rec.709 view's LUT matches the per-pixel view, since a grade there swaps one for the other.
    func testGradedRec709MatchesTheView() {
        var grade = LookGrade()
        grade.exposure = 0.5
        let size = 9
        let lut = BuiltInLook.rec709LUT(curve: .sLog3, gamut: .sGamut3Cine, grade: grade, size: size)
        let toRec2020 = Gamut.sGamut3Cine.fromRec2020.inverse
        for (r, g, b) in [(4, 4, 4), (8, 2, 5), (3, 7, 1)] {
            let log = SIMD3(Double(r), Double(g), Double(b)) / Double(size - 1)
            let linear = toRec2020 * SIMD3(LogCurve.sLog3.decode(log.x), LogCurve.sLog3.decode(log.y), LogCurve.sLog3.decode(log.z))
            let expected = MonitorTransform.display(linearRec2020: linear * pow(2, 0.5))
            let got = lut.samples[(b * size + g) * size + r]
            XCTAssertEqual(Double(got.x), expected.x, accuracy: 1e-5)
            XCTAssertEqual(Double(got.y), expected.y, accuracy: 1e-5)
        }
    }
}

/// Lens profiles: a pinhole focal length from a field of view, and a profile survives its file.
final class LensProfileTests: XCTestCase {
    /// The 1x's 71.29 degrees across 4032 gave 2812 px, against Apple's calibration of 2818.
    func testFocalLengthFromFieldOfView() {
        XCTAssertEqual(LensProfile.focalLength(fieldOfView: 71.29, width: 4032), 2812, accuracy: 1)
        XCTAssertEqual(LensProfile.focalLength(fieldOfView: 90, width: 2000), 1000, accuracy: 1e-9)
    }

    func testProfileReadsBack() throws {
        let profile = LensProfile(
            model: "Test,1", lens: "back-wide", width: 4032, height: 3024, fx: 2817.99, fy: 2817.99,
            cx: 2018.9, cy: 1517.9, distortionCenterX: 2045.7, distortionCenterY: 1519.6,
            distortionTable: [0, 0.01, 0.021], pixelSize: 0.00244, fieldOfView: 71.29,
            correctedFieldOfView: 71.29, source: "test", measured: "2026-11-07")
        let read = try JSONDecoder().decode(LensProfile.self, from: JSONEncoder().encode(profile))
        XCTAssertEqual(read, profile)
        XCTAssertEqual(profile.fileName, "back-wide-4032x3024.json")
        XCTAssertTrue(profile.isCalibrated)
        XCTAssertEqual(profile.distortionRange ?? 0, 0.021, accuracy: 1e-12)
    }
}

/// Gyroflow lens profiles: the fisheye fit follows Apple's table, and the file has what Gyroflow reads.
final class GyroflowProfileTests: XCTestCase {
    /// A 1x like the iPhone 14 Pro's, with a table rising to +2.09% at the farthest corner.
    private func wide(table: [Double]) -> LensProfile {
        LensProfile(
            model: "Test,1", lens: "back-wide", width: 4032, height: 3024, fx: 2818.19, fy: 2818.19,
            cx: 2007.6, cy: 1530.4, distortionCenterX: 2004.9, distortionCenterY: 1539.1,
            distortionTable: table, fieldOfView: 71.29, source: "test", measured: "2026-11-11T10:00:00Z", captures: 5)
    }

    private let rising = (0..<42).map { 0.0209 * pow(Double($0) / 41, 2) }

    func testTableReadsAsApplesSampleDoes() {
        let table = [0, 0.01, 0.03]
        XCTAssertEqual(GyroflowProfile.distorted(radius: 0, table: table, reach: 100), 0, accuracy: 1e-12)
        XCTAssertEqual(GyroflowProfile.distorted(radius: 50, table: table, reach: 100), 50.5, accuracy: 1e-9)
        XCTAssertEqual(GyroflowProfile.distorted(radius: 75, table: table, reach: 100), 76.5, accuracy: 1e-9)
        XCTAssertEqual(GyroflowProfile.distorted(radius: 100, table: table, reach: 100), 103, accuracy: 1e-9)
    }

    func testFitFollowsTheTableWithinAHundredthOfAPixel() throws {
        let profile = wide(table: rising)
        let fit = try XCTUnwrap(GyroflowProfile.fit(profile))
        XCTAssertEqual(fit.coefficients.count, 4)
        XCTAssertLessThan(fit.rms, 0.01)
        // A straight lens's first coefficient is a third; this one bends a little outward.
        XCTAssertEqual(fit.coefficients[0], 0.359, accuracy: 0.005)
        let reach = hypot(4032 - 2004.9, 1539.1)
        for radius in stride(from: 100.0, through: reach, by: 300) {
            XCTAssertEqual(
                GyroflowProfile.modelled(radius: radius, focal: 2818.19, coefficients: fit.coefficients),
                GyroflowProfile.distorted(radius: radius, table: rising, reach: reach), accuracy: 0.02)
        }
    }

    /// A long lens has small angles, which the solve must still manage.
    func testFitHoldsOnATele() throws {
        var profile = wide(table: (0..<42).map { -0.0085 * pow(Double($0) / 41, 2) })
        profile.lens = "back-tele"
        profile.fx = 9234.62
        profile.fy = 9234.62
        XCTAssertLessThan(try XCTUnwrap(GyroflowProfile.fit(profile)).rms, 0.01)
    }

    func testNoTableGivesNoProfile() {
        XCTAssertNil(GyroflowProfile.fit(wide(table: [])))
        XCTAssertNil(GyroflowProfile.json(for: wide(table: []), widescreen: false))
    }

    func testFileHasWhatGyroflowReads() throws {
        let profile = wide(table: rising)
        let open = try XCTUnwrap(GyroflowProfile.json(for: profile, widescreen: false))
        let document = try XCTUnwrap(JSONSerialization.jsonObject(with: open) as? [String: Any])
        XCTAssertEqual(document["distortion_model"] as? String, "opencv_fisheye")
        XCTAssertEqual(document["calib_dimension"] as? [String: Int], ["w": 4032, "h": 3024])
        XCTAssertEqual(document["camera_model"] as? String, "Test,1")
        XCTAssertEqual(document["date"] as? String, "2026-11-11")
        let lens = try XCTUnwrap(document["fisheye_params"] as? [String: Any])
        let matrix = try XCTUnwrap(lens["camera_matrix"] as? [[Double]])
        XCTAssertEqual(matrix[0], [2818.19, 0, 2007.6])
        XCTAssertEqual(matrix[1], [0, 2818.19, 1530.4])
        XCTAssertEqual(matrix[2], [0, 0, 1])
        XCTAssertEqual((lens["distortion_coeffs"] as? [Double])?.count, 4)
        XCTAssertEqual(GyroflowProfile.fileName(profile, widescreen: false), "gyroflow-back-wide-4032x3024.json")
    }

    /// 16:9 cuts 378 rows from the top and bottom, so the centre sits 378 higher in the crop.
    func testWidescreenMovesTheCentreWithTheCrop() throws {
        let profile = wide(table: rising)
        let data = try XCTUnwrap(GyroflowProfile.json(for: profile, widescreen: true))
        let document = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(document["calib_dimension"] as? [String: Int], ["w": 4032, "h": 2268])
        let lens = try XCTUnwrap(document["fisheye_params"] as? [String: Any])
        let matrix = try XCTUnwrap(lens["camera_matrix"] as? [[Double]])
        XCTAssertEqual(matrix[1][2], 1530.4 - 378, accuracy: 1e-9)
        XCTAssertEqual(GyroflowProfile.fileName(profile, widescreen: true), "gyroflow-back-wide-4032x2268.json")
    }
}

/// Apple's lens shading, as the iPhone 14 Pro's 1x reported it, and log written as another log.
final class VignetteAndConversionTests: XCTestCase {
    func testVignetteReadsFromMetadataAndGainsTwoStops() throws {
        let metadata: [String: Any] = ["{DNG}": ["FixVignetteRadial": [
            3.2396490573883057, -4.15488862991333, 11.245702743530273, -14.199689865112305, 7.030414581298828,
            0.500174776, 0.4983130414,
        ] as [NSNumber]] as [AnyHashable: Any]]
        let vignette = try XCTUnwrap(VignetteRadial(photoMetadata: metadata))
        XCTAssertEqual(vignette.gain(radius: 0), 1, accuracy: 1e-12)
        XCTAssertEqual(vignette.gain(radius: 1), 4.161, accuracy: 0.001)
        XCTAssertEqual(vignette.centreX, 0.5002, accuracy: 1e-4)
        XCTAssertNil(VignetteRadial(photoMetadata: [:]))
    }

    /// The same curve and gamut give back the code, and middle gray lands at the target's own.
    func testLogConversionKeepsGrayAndIdentity() {
        let size = 17
        let same = BuiltInLook.logConversion(curve: .sLog3, gamut: .sGamut3Cine, to: .sLog3, in: .sGamut3Cine, size: size)
        for (r, g, b) in [(8, 8, 8), (4, 9, 12), (12, 6, 3)] {
            let got = same.samples[(b * size + g) * size + r]
            XCTAssertEqual(Double(got.x), Double(r) / Double(size - 1), accuracy: 1e-4)
            XCTAssertEqual(Double(got.y), Double(g) / Double(size - 1), accuracy: 1e-4)
            XCTAssertEqual(Double(got.z), Double(b) / Double(size - 1), accuracy: 1e-4)
        }
        let gray = LogCurve.appleLog2.encode(0.18)
        let converted = BuiltInLook.logConversion(curve: .appleLog2, gamut: .appleWideGamut, to: .sLog3, in: .sGamut3Cine, size: 65)
        let out = converted.sample(SIMD3<Float>(repeating: Float(gray)))
        XCTAssertEqual(Double(out.x), LogCurve.sLog3.encode(0.18), accuracy: 0.002)
        XCTAssertEqual(Double(out.y), LogCurve.sLog3.encode(0.18), accuracy: 0.002)
    }
}

/// Styles: the built-in ones are distinct and each changes the look, and saved ones live beside
/// the presets rather than in them, so applying a preset never loses them.
final class LookStyleTests: XCTestCase {
    func testBuiltInStylesAreDistinct() {
        let names = LookStyle.builtIn.map(\.name)
        XCTAssertEqual(Set(names).count, names.count)
        for style in LookStyle.builtIn {
            XCTAssertFalse(style.grade.isNeutral, style.name)
            XCTAssertNotNil(BuiltInLook.named(style.look), style.name)
        }
    }

    /// Built-in styles sit under both ACES looks, and a saved one only under its own look.
    func testStylesBelongToLooks() {
        let warm = LookStyle.builtIn[0]
        XCTAssertTrue(warm.belongs(to: "ACES 2.0"))
        XCTAssertTrue(warm.belongs(to: "ACES 1.3"))
        XCTAssertFalse(warm.belongs(to: ""))
        XCTAssertFalse(warm.belongs(to: "Film.cube"))
        let mine = LookStyle(name: "Mine", look: "Film.cube", grade: warm.grade)
        XCTAssertFalse(mine.isBuiltIn)
        XCTAssertTrue(mine.belongs(to: "Film.cube"))
        XCTAssertFalse(mine.belongs(to: "ACES 2.0"))
    }

    func testSavedStylesStayOutOfPresets() {
        var config = AppConfig()
        config.styles = [LookStyle(name: "Mine", look: "ACES 2.0", grade: LookStyle.builtIn[0].grade)]
        XCTAssertTrue(config.presetValues.styles.isEmpty)
        var other = AppConfig()
        other.exposureOffset = 0.3
        config.use(FormatPreset(name: "Test", settings: other))
        XCTAssertEqual(config.styles.map(\.name), ["Mine"])
    }

    func testStylesSurviveSaving() throws {
        var config = AppConfig()
        config.styles = [LookStyle.builtIn[5]]
        let data = try JSONEncoder().encode(config)
        let read = try JSONDecoder().decode(AppConfig.self, from: data)
        XCTAssertEqual(read.styles, config.styles)
    }
}

/// The scope's kernel loads, and the SCOPE tool cycles through every kind and back.
final class ScopeTests: XCTestCase {
    func testScopeMeterLoads() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        XCTAssertNotNil(ScopeMeter(device: device))
    }

    func testScopeKindsCycle() {
        var kind = ScopeKind.waveform
        var seen: [ScopeKind] = []
        for _ in ScopeKind.allCases {
            seen.append(kind)
            kind = kind.next
        }
        XCTAssertEqual(kind, .waveform)
        XCTAssertEqual(Set(seen.map(\.rawValue)).count, ScopeKind.allCases.count)
    }

    /// The export screen's scope counts a picture as the kernel does: a gray left half and a red
    /// right half land at their levels, in their columns, and red sits off the vectorscope's middle.
    func testPictureScopeCountsAPicture() throws {
        var made: CVPixelBuffer?
        CVPixelBufferCreate(nil, 320, 240, kCVPixelFormatType_32BGRA, nil, &made)
        let buffer = try XCTUnwrap(made)
        CVPixelBufferLockBaseAddress(buffer, [])
        let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(buffer)).assumingMemoryBound(to: UInt8.self)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        for y in 0..<240 {
            for x in 0..<320 {
                let pixel = base + y * bytesPerRow + x * 4
                let (b, g, r): (UInt8, UInt8, UInt8) = x < 160 ? (128, 128, 128) : (0, 0, 255)
                pixel[0] = b
                pixel[1] = g
                pixel[2] = r
                pixel[3] = 255
            }
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])

        let counts = try XCTUnwrap(PictureScope.count(buffer))
        XCTAssertEqual(counts.columns, 256)
        XCTAssertEqual(counts.rows, 192)
        let levels = ScopeMeter.levels
        let top = Double(levels - 1)
        let gray = Int((128.0 / 255 * top).rounded())
        // Luma of the left column is all at gray, and the right column's red channel is all at the top.
        XCTAssertEqual(counts.wave[(0 * levels + gray) * 256 + 10], 192)
        XCTAssertEqual(counts.wave[(1 * levels + levels - 1) * 256 + 250], 192)
        XCTAssertEqual(counts.histogram.reduce(0, +), UInt32(4 * 256 * 192))
        // Each half fills one bin: gray in the middle, within rounding of the half-way level, and
        // red away from it.
        let full = counts.vector.indices.filter { counts.vector[$0] == 128 * 192 }
        XCTAssertEqual(full.count, 2)
        let nearMiddle = { (bin: Int) in
            abs(Double(bin / levels) - top / 2) <= 1 && abs(Double(bin % levels) - top / 2) <= 1
        }
        XCTAssertEqual(full.filter(nearMiddle).count, 1)
        XCTAssertEqual(counts.vector.reduce(0, +), UInt32(256 * 192))
    }
}

/// The FX kernels: a flat gray has no highlights to glow and nothing for diffusion to soften, so
/// bloom, halation and diffusion leave it as it is, and a vignette darkens only the corners.
final class EffectsTests: XCTestCase {
    private func run(
        _ effects: LookEffects, light: Bool = false, curve: LogCurve = .sLog3, fill: Float? = nil
    ) throws -> (center: Float, corner: Float, beside: Float, expected: Float) {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let kit = try XCTUnwrap(EffectsKit(device: device))
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let size = 64
        // Readable from the CPU, unlike the pipeline's private ones.
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Unorm, width: size, height: size, mipmapped: false)
        descriptor.usage = [.shaderRead, .shaderWrite]
        let image = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        let output = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        let gray = fill ?? Float(curve.encode(0.18))
        let code = UInt16((gray * 65535).rounded())
        var pixels = [UInt16](repeating: code, count: size * size * 4)
        if light {
            // A light, four stops over gray, filling the middle eighth-size texels.
            let bright = UInt16((curve.encode(0.18 * 16) * 65535).rounded())
            for y in 24..<40 { for x in 24..<40 { for c in 0..<3 { pixels[(y * size + x) * 4 + c] = bright } } }
        }
        pixels.withUnsafeBytes { bytes in
            image.replace(region: MTLRegionMake2D(0, 0, size, size), mipmapLevel: 0, withBytes: bytes.baseAddress!, bytesPerRow: size * 8)
        }
        let params = EffectsParams(effects, curve: curve, frame: 1)
        let commands = try XCTUnwrap(queue.makeCommandBuffer())
        let glow = try XCTUnwrap(kit.glow(for: image, params: params, commands: commands))
        XCTAssertTrue(kit.apply(image, into: output, glow: glow, params: params, commands: commands))
        commands.commit()
        commands.waitUntilCompleted()
        var read = [UInt16](repeating: 0, count: size * size * 4)
        read.withUnsafeMutableBytes { bytes in
            output.getBytes(bytes.baseAddress!, bytesPerRow: size * 8, from: MTLRegionMake2D(0, 0, size, size), mipmapLevel: 0)
        }
        func at(_ x: Int, _ y: Int) -> Float { Float(read[(y * size + x) * 4 + 1]) / 65535 }
        return (at(32, 32), at(0, 0), at(46, 32), gray)
    }

    /// A take's kit must give each frame its own glow, so the viewfinder's isn't rewritten by the
    /// frames queued behind it.
    func testPooledGlowsTakeTurns() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Unorm, width: 64, height: 64, mipmapped: false)
        descriptor.usage = [.shaderRead, .shaderWrite]
        let image = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        var effects = LookEffects()
        effects.bloom = 1
        let params = EffectsParams(effects, curve: .sLog3, frame: 1)
        func glows(_ kit: EffectsKit, _ count: Int) throws -> [MTLTexture] {
            let commands = try XCTUnwrap(queue.makeCommandBuffer())
            let made = try (0..<count).map { _ in try XCTUnwrap(kit.glow(for: image, params: params, commands: commands)) }
            commands.commit()
            commands.waitUntilCompleted()
            return made
        }
        let pooled = try glows(try XCTUnwrap(EffectsKit(device: device, poolSize: 4)), 5)
        for first in 0..<4 { for second in (first + 1)..<4 { XCTAssertFalse(pooled[first] === pooled[second]) } }
        XCTAssertTrue(pooled[0] === pooled[4])
        let single = try glows(try XCTUnwrap(EffectsKit(device: device)), 2)
        XCTAssertTrue(single[0] === single[1])
    }

    func testGlowsLeaveFlatGrayAlone() throws {
        var effects = LookEffects()
        effects.bloom = 1
        effects.halation = 1
        effects.diffusion = 1
        let result = try run(effects)
        XCTAssertEqual(result.center, result.expected, accuracy: 2 / 1023)
        XCTAssertEqual(result.corner, result.expected, accuracy: 2 / 1023)
    }

    /// A small light glows onto what's beside it, which was too faint to see before.
    func testBloomSpreadsFromALight() throws {
        var effects = LookEffects()
        effects.bloom = 1
        let result = try run(effects, light: true)
        XCTAssertGreaterThan(
            result.beside, result.expected + 0.004, "beside \(result.beside), gray \(result.expected)")
    }

    func testVignetteDarkensCorners() throws {
        var effects = LookEffects()
        effects.vignette = 0.5
        let result = try run(effects)
        XCTAssertEqual(result.center, result.expected, accuracy: 2 / 1023)
        XCTAssertLessThan(result.corner, result.expected - 0.02)
    }

    /// Shadows below zero light must keep their codes with FX on. Clamping them lifted Apple Log's
    /// code 0 to about 0.15, which turned a dark take's preview flat and grey on the iPhone 16.
    func testEffectsKeepLightBelowZero() throws {
        var effects = LookEffects()
        effects.vignette = 0.01
        for curve in [LogCurve.appleLog, .sLog3, .logC3] {
            let result = try run(effects, curve: curve, fill: 0.02)
            XCTAssertEqual(result.center, 0.02, accuracy: 2 / 1023, "\(curve)")
        }
    }

    func testOlderSettingsReadWithoutEffects() throws {
        let config = try JSONDecoder().decode(AppConfig.self, from: Data("{}".utf8))
        XCTAssertTrue(config.lookEffects.isNeutral)
    }
}

/// HDR: the PQ and HLG curves at known points, ACES 2.0's 1000-nit look landing middle gray and
/// highlights where an HDR grade puts them, and HDR bakes keeping Rec.2020's matrix.
final class HDRTests: XCTestCase {
    func testPQAtKnownPoints() {
        XCTAssertEqual(HDREncoding.pq(SIMD3(repeating: 0)).x, 0, accuracy: 1e-6)
        XCTAssertEqual(HDREncoding.pq(SIMD3(repeating: 100)).x, 0.5081, accuracy: 0.001)
        XCTAssertEqual(HDREncoding.pq(SIMD3(repeating: 1000)).x, 0.7518, accuracy: 0.001)
        XCTAssertEqual(HDREncoding.pq(SIMD3(repeating: 10000)).x, 1, accuracy: 1e-6)
    }

    func testHLGPeakIsOne() {
        let white = HDREncoding.hlg(SIMD3(repeating: 1000))
        XCTAssertEqual(white.x, 1, accuracy: 1e-4)
        XCTAssertEqual(HDREncoding.hlg(SIMD3(repeating: 0)).y, 0, accuracy: 1e-6)
    }

    func testHDRLookPlacesGrayAndHighlights() {
        let size = 9
        let lut = BuiltInLook.hdrLUT(curve: .sLog3, gamut: .sGamut3Cine, target: .pq, size: size)
        // Middle gray sits near 10 to 20 nits in a 1000-nit grade, PQ about 0.32 to 0.40.
        let gray = SIMD3(repeating: LogCurve.sLog3.encode(0.18))
        let index = Int((gray.x * Double(size - 1)).rounded())
        let near = lut.samples[(index * size + index) * size + index]
        XCTAssertGreaterThan(near.y, 0.25)
        XCTAssertLessThan(near.y, 0.5)
        // Never past the 1000-nit peak, and brighter input is never darker.
        let top = lut.samples.last!
        XCTAssertLessThanOrEqual(top.y, Float(HDREncoding.pq(SIMD3(repeating: 1000)).y) + 1e-4)
        var previous: Float = -1
        for step in 0..<size {
            let value = lut.samples[(step * size + step) * size + step].y
            XCTAssertGreaterThanOrEqual(value, previous - 1e-4)
            previous = value
        }
    }

    func testHDRBakeKeepsRec2020Matrix() {
        var settings = ProcessingSettings()
        settings.bakeLook = true
        XCTAssertEqual(LookParams(settings: settings, lut: nil).luma, LookParams.rec709Luma)
        settings.bakeHDR = true
        XCTAssertEqual(LookParams(settings: settings, lut: nil).luma, LookParams.rec2020Luma)
    }

    /// An HDR-tagged HEVC file writes and reads back with its transfer. The phone refused HLG
    /// on the first frame, so a failure here is reported with the encoder's own error.
    func testHDRFilesWrite() async throws {
        let preset = try XCTUnwrap(EncoderPreset.all.first { $0.id == "hevc420" })
        for tag in [FileTag.pq, .hlg] {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mov")
            let encoder: VideoEncoder
            do {
                encoder = try VideoEncoder(config: .init(
                    url: url, preset: preset, size: EncoderSize(width: 640, height: 480), audio: false,
                    realTime: false, fileTag: tag))
            } catch {
                throw XCTSkip("\(tag.label) can't be set up here: \(error)")
            }
            for index in 0..<6 {
                let buffer = try XCTUnwrap(encoder.nextPixelBuffer())
                encoder.append(buffer, at: CMTime(value: Int64(index), timescale: 30))
            }
            let result = await withCheckedContinuation { continuation in encoder.finish { continuation.resume(returning: $0) } }
            if let failure = result.failure { throw XCTSkip("\(tag.label) failed here: \(failure)") }
            XCTAssertEqual(result.framesWritten, 6, tag.label)
            let tracks = try await AVURLAsset(url: url).loadTracks(withMediaType: .video)
            let track = try XCTUnwrap(tracks.first)
            let formats = try await track.load(.formatDescriptions)
            let format = try XCTUnwrap(formats.first)
            let transfer = CMFormatDescriptionGetExtension(format, extensionKey: kCMFormatDescriptionExtension_TransferFunction) as? String
            XCTAssertEqual(
                transfer, tag == .pq ? (kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ as String)
                    : (kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG as String), tag.label)
        }
    }

    func testMasteringDisplayIsTwentyFourBytes() {
        XCTAssertEqual(EncoderPreset.hdr10MasteringDisplay.count, 24)
    }

    /// MaxCLL then MaxFALL, big-endian, and only a PQ HEVC file asks for them.
    func testContentLightLevelBytes() throws {
        XCTAssertEqual([UInt8](EncoderPreset.contentLightLevel(maxCLL: 1000, maxFALL: 400)), [0x03, 0xE8, 0x01, 0x90])
        let hevc = try XCTUnwrap(EncoderPreset.all.first { $0.codec == .hevc })
        let key = kVTCompressionPropertyKey_ContentLightLevelInfo as String
        let pq = hevc.outputSettings(width: 8, height: 8, tag: .pq, contentLight: (1000, 400))
        XCTAssertNotNil((pq[AVVideoCompressionPropertiesKey] as? [String: Any])?[key])
        let hlg = hevc.outputSettings(width: 8, height: 8, tag: .hlg, contentLight: (1000, 400))
        XCTAssertNil((hlg[AVVideoCompressionPropertiesKey] as? [String: Any])?[key])
    }

    /// A second export of a take gets the next number instead of replacing the first.
    func testExportsAreNumbered() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let take = folder.appendingPathComponent("video_1.mov")
        let first = TakeLibrary.exportURL(for: take, in: folder)
        XCTAssertEqual(first.lastPathComponent, "video_1_look.mov")
        FileManager.default.createFile(atPath: first.path, contents: Data())
        let second = TakeLibrary.exportURL(for: take, in: folder)
        XCTAssertEqual(second.lastPathComponent, "video_1_look2.mov")
        XCTAssertTrue(TakeLibrary.isExport(first))
        XCTAssertTrue(TakeLibrary.isExport(second))
        XCTAssertFalse(TakeLibrary.isExport(take))
    }
}

final class SteadyPathTests: XCTestCase {
    /// Readings at 100 Hz for `seconds`, turning as `rate` says at each time.
    private func samples(seconds: Double, rate: (Double) -> SIMD3<Double>) -> [MotionSample] {
        (0..<Int(seconds * 100)).map { index in
            let time = Double(index) / 100
            return MotionSample(seconds: time, rotation: rate(time), acceleration: SIMD3(0, 1, 0))
        }
    }

    func testReadsItsOwnLog() {
        let text = GyroLog.header(videoName: "video.mov", startedAt: Date(timeIntervalSince1970: 0), version: "1")
            + "\n105040,7348,-23930,1081,-383,10024,903\n115015,6905,22079,946,-407,10035,932\n"
        let read = GyroLog.samples(from: text)
        XCTAssertEqual(read.count, 2)
        XCTAssertEqual(read[0].seconds, 0.10504, accuracy: 1e-9)
        XCTAssertEqual(read[0].rotation.x, 0.07348, accuracy: 1e-9)
        XCTAssertEqual(read[0].rotation.y, -0.2393, accuracy: 1e-9)
        XCTAssertEqual(read[1].acceleration.y, 1.0035, accuracy: 1e-9)
    }

    func testASteadyPanIsLeftAlone() throws {
        let path = try XCTUnwrap(SteadyPath(samples: samples(seconds: 10) { _ in SIMD3(0, 0.4, 0) }))
        // Away from the ends, a smoothed straight line is the line itself.
        XCTAssertEqual(simd_length(path.excess(at: 5)), 0, accuracy: 1e-6)
    }

    func testSlowSwayIsUndoneAndFastShakeIsLeftToTheOptics() throws {
        // One degree of sway at 0.7 Hz about x, and of shake at 8 Hz about y and z.
        let amplitude = 1.0 * Double.pi / 180
        func rate(_ hertz: Double, _ time: Double) -> Double {
            amplitude * 2 * Double.pi * hertz * cos(2 * Double.pi * hertz * time)
        }
        var settings = SteadyPath.Settings()
        settings.frameOffset = 0
        let path = try XCTUnwrap(SteadyPath(
            samples: samples(seconds: 12) { SIMD3(rate(0.7, $0), rate(8, $0), rate(8, $0)) }, settings: settings))
        var most = SIMD3<Double>.zero
        for index in 0..<400 {
            let excess = path.excess(at: 4 + Double(index) / 100)
            most = SIMD3(max(most.x, abs(excess.x)), max(most.y, abs(excess.y)), max(most.z, abs(excess.z)))
        }
        // The sway is nearly all there to undo, the optics' two axes keep almost none of the
        // shake, and roll keeps all of it.
        XCTAssertGreaterThan(most.x, amplitude * 0.8)
        XCTAssertLessThan(most.x, amplitude * 1.05)
        XCTAssertLessThan(most.y, amplitude * 0.05)
        XCTAssertGreaterThan(most.z, amplitude * 0.9)
    }

    func testNoTurnLeavesThePictureWhereItIs() throws {
        let path = try XCTUnwrap(SteadyPath(samples: samples(seconds: 5) { _ in .zero }))
        XCTAssertEqual(path.zoom(width: 4032, height: 3024, focal: 2840), 1, accuracy: 1e-9)
        let source = path.matrix(at: 2, width: 4032, height: 3024, focal: 2840, zoom: 1) * SIMD3(1000, 700, 1)
        XCTAssertEqual(source.x / source.z, 1000, accuracy: 1e-6)
        XCTAssertEqual(source.y / source.z, 700, accuracy: 1e-6)
    }

    /// The directions measured on take 220644: a turn about the phone's x moves the picture
    /// right, one about y moves it up, and one about z turns it clockwise.
    func testATurnMovesThePictureTheMeasuredWay() {
        let angle = 0.01
        func source(_ phone: SIMD3<Double>, _ x: Double, _ y: Double) -> SIMD2<Double> {
            let moved = SteadyPath.warp(SteadyPath.pictureTurn(phone), width: 4032, height: 3024, focal: 2840, zoom: 1) * SIMD3(x, y, 1)
            return SIMD2(moved.x / moved.z, moved.y / moved.z)
        }
        // At the middle, the content sits a focal length times the angle away.
        XCTAssertEqual(source(SIMD3(angle, 0, 0), 2016, 1512).x, 2016 + 2840 * tan(angle), accuracy: 0.01)
        XCTAssertEqual(source(SIMD3(angle, 0, 0), 2016, 1512).y, 1512, accuracy: 0.01)
        XCTAssertEqual(source(SIMD3(0, angle, 0), 2016, 1512).y, 1512 - 2840 * tan(angle), accuracy: 0.01)
        // Clockwise: the content right of the middle lies lower in the frame.
        XCTAssertEqual(source(SIMD3(0, 0, angle), 3016, 1512).y, 1512 + 1000 * sin(angle), accuracy: 0.01)
    }

    func testZoomHidesTheEdgesAndStopsAtItsMost() throws {
        // A sway of one degree needs a little room, and a wild one more than is allowed.
        func path(_ degrees: Double) throws -> SteadyPath {
            let amplitude = degrees * Double.pi / 180
            return try XCTUnwrap(SteadyPath(samples: samples(seconds: 12) {
                SIMD3(amplitude * 2 * Double.pi * 0.7 * cos(2 * Double.pi * 0.7 * $0), 0, 0)
            }))
        }
        let gentle = try path(1)
        let zoom = gentle.zoom(width: 4032, height: 3024, focal: 2840)
        XCTAssertGreaterThan(zoom, 1.01)
        XCTAssertLessThan(zoom, 1.12)
        for index in 0..<100 {
            let matrix = gentle.matrix(at: 3 + Double(index) / 30, width: 4032, height: 3024, focal: 2840, zoom: zoom)
            XCTAssertTrue(SteadyPath.fits(matrix, width: 4032, height: 3024))
        }
        let wild = try path(25)
        let most = wild.zoom(width: 4032, height: 3024, focal: 2840)
        XCTAssertEqual(most, wild.settings.maxZoom, accuracy: 1e-9)
        // Turned back less, each frame still keeps its edges out.
        for index in 0..<100 {
            let matrix = wild.matrix(at: 3 + Double(index) / 30, width: 4032, height: 3024, focal: 2840, zoom: most)
            XCTAssertTrue(SteadyPath.fits(matrix, width: 4032, height: 3024))
        }
    }

    func testEasingKeepsEveryMomentInsideWithoutCuttingOff() throws {
        // A sway too wide to hide, as a pan's start and stop are.
        let amplitude = 25 * Double.pi / 180
        var settings = SteadyPath.Settings()
        settings.frameOffset = 0
        let wild = try XCTUnwrap(SteadyPath(samples: samples(seconds: 12) {
            SIMD3(amplitude * 2 * Double.pi * 0.7 * cos(2 * Double.pi * 0.7 * $0), 0, 0)
        }, settings: settings))
        let zoom = wild.zoom(width: 4032, height: 3024, focal: 2840)
        let eased = wild.eased(width: 4032, height: 3024, focal: 2840, zoom: zoom)
        var biggestStep = 0.0
        var last = eased.excess(at: 2)
        for index in 1..<800 {
            let now = eased.excess(at: 2 + Double(index) / 100)
            // It fits as it is, with nothing left for the frame-by-frame limit to cut.
            let warp = SteadyPath.warp(SteadyPath.pictureTurn(now), width: 4032, height: 3024, focal: 2840, zoom: zoom)
            XCTAssertTrue(SteadyPath.fits(warp, width: 4032, height: 3024))
            biggestStep = max(biggestStep, simd_length(now - last))
            last = now
        }
        // And it moves gently: the sway itself turns up to 1.9 degrees in a hundredth of a second.
        XCTAssertLessThan(biggestStep, 0.5 * Double.pi / 180)

        // A path that already fits is left as it is.
        let gentle = try XCTUnwrap(SteadyPath(samples: samples(seconds: 12) {
            SIMD3(0.01 * cos(2 * Double.pi * 0.7 * $0), 0, 0)
        }, settings: settings))
        let gentleZoom = gentle.zoom(width: 4032, height: 3024, focal: 2840)
        let same = gentle.eased(width: 4032, height: 3024, focal: 2840, zoom: gentleZoom)
        XCTAssertEqual(simd_length(same.excess(at: 5) - gentle.excess(at: 5)), 0, accuracy: 1e-12)
    }
}


final class LogSharingTests: XCTestCase {
    private let salt = "0123456789abcdef"

    func testDatesBecomeTheSameCodeEverywhere() {
        let code = LogSanitizer.code(for: "20261112_140255", salt: salt)
        XCTAssertEqual(code.count, 8)
        let log = "I VIDEO RESULT video_20261112_140255.mov: HEVC, then video_20261112_140255_look.mov"
        let clean = LogSanitizer.clean(log, salt: salt)
        XCTAssertFalse(clean.contains("20261112"))
        XCTAssertEqual(clean, "I VIDEO RESULT video_\(code).mov: HEVC, then video_\(code)_look.mov")
        XCTAssertEqual(LogSanitizer.uploadName(for: "videos/video_20261112_140255.mov.json", salt: salt),
                       "video_\(code).mov.json")
        XCTAssertNotEqual(LogSanitizer.code(for: "20261112_140255", salt: "another salt"), code)
    }

    func testAddressesDatesAndNamesAreRemoved() {
        let text = """
        13:48:11.454 W Test link connecting over the internet, to 5991-2001-f00.ngrok-free.app
        Server: http://192.168.1.148:8765/next and 172.20.10.4
        "measured" : "2026-11-12T11:56:15Z",
        timestamp,1794484976
        Built My Secret Grade · Apple Log 2, preset Joona's Night
        version 26.6.2, fov:68.157, 0.0001243470120243728
        """
        let clean = LogSanitizer.clean(text, salt: salt, privateNames: ["My Secret Grade", "Joona's Night", "ab"])
        for gone in ["ngrok", "192.168", "172.20", "2026-11-12", "1794484976", "My Secret", "Joona"] {
            XCTAssertFalse(clean.contains(gone), gone)
        }
        for kept in ["13:48:11.454", "timestamp,0", "Apple Log 2", "26.6.2", "68.157", "0.0001243470120243728", "<name"] {
            XCTAssertTrue(clean.contains(kept), kept)
        }
    }

    func testOnlySmallTextFilesAreCandidates() throws {
        let documents = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: documents) }
        let files = [
            "logs/session_20261112_134734.log", "logs/exports.csv", "videos/video_20261112_140255.mov",
            "videos/video_20261112_140255.mov.json", "videos/video_20261112_140255.gcsv",
            "probes/probe_1.txt", "probes/still.jpg", "lenses/iPhone15,2/back-wide-4032x3024.json",
            "capture_support.json", "VibeLog.config.json",
        ]
        for path in files {
            let url = documents.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("x".utf8).write(to: url)
        }
        let without = LogSharing.candidates(documents: documents, gyro: false).map(\.path)
        XCTAssertEqual(Set(without), [
            "logs/session_20261112_134734.log", "logs/exports.csv", "videos/video_20261112_140255.mov.json",
            "probes/probe_1.txt", "lenses/iPhone15,2/back-wide-4032x3024.json", "capture_support.json",
        ])
        let with = LogSharing.candidates(documents: documents, gyro: true).map(\.path)
        XCTAssertTrue(with.contains("videos/video_20261112_140255.gcsv"))
        XCTAssertEqual(LogSanitizer.uploadName(for: "lenses/iPhone15,2/back-wide-4032x3024.json", salt: salt),
                       "lenses_back-wide-4032x3024.json")
    }

    func testOnlyChangedFilesGoInBoundedBatches() {
        let files = [LogShareFile(path: "a", size: 10), LogShareFile(path: "b", size: 20), LogShareFile(path: "c", size: 15)]
        XCTAssertEqual(LogSharing.changed(files, sent: ["a": 10, "b": 5]).map(\.path), ["b", "c"])
        XCTAssertEqual(LogSharing.batches(files, limit: 30).map { $0.map(\.path) }, [["a", "b"], ["c"]])
    }

    func testSettingsSurviveAMissingField() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(#"{"on": true, "inviteCode": "abc123"}"#.utf8).write(to: url)
        let loaded = LogSharingSettings.load(from: url)
        XCTAssertTrue(loaded.on)
        XCTAssertEqual(loaded.inviteCode, "abc123")
        XCTAssertFalse(loaded.gyro)
        XCTAssertFalse(loaded.mobileData)
        XCTAssertTrue(loaded.server.hasPrefix("https://"))
        XCTAssertEqual(loaded.installID.count, 36)
        var fresh = loaded
        fresh.startAfresh()
        XCTAssertNotEqual(fresh.installID, loaded.installID)
        XCTAssertNotEqual(fresh.salt, loaded.salt)
    }
}

final class EncoderEvidenceTests: XCTestCase {
    private func support(rate: Double) -> EncoderSupport {
        EncoderSupport(device: "iPhone15,2", system: "27.2", codecs: ["hevc422"],
                       fps: ["hevc422": ["4032x3024": rate]], measured: true)
    }

    func testATakeThatHeldOutranksASlowTrial() {
        var s = support(rate: 27.3)
        XCTAssertNotNil(s.warning(for: "hevc422", size: "4032x3024"))
        XCTAssertTrue(s.warning(for: "hevc422", size: "4032x3024")!.contains("quick check"))
        s.record(take: "hevc422", size: "4032x3024", seconds: 3, fps: 30, encoderDrops: 0)
        XCTAssertNotNil(s.warning(for: "hevc422", size: "4032x3024"), "a take under five seconds proves nothing")
        s.record(take: "hevc422", size: "4032x3024", seconds: 10, fps: 29.9, encoderDrops: 0)
        XCTAssertNil(s.warning(for: "hevc422", size: "4032x3024"))
    }

    func testATakeWhoseEncoderRefusedFramesAlwaysWarns() {
        var s = support(rate: 57.5)
        XCTAssertNil(s.warning(for: "hevc422", size: "4032x3024"))
        s.record(take: "hevc422", size: "4032x3024", seconds: 60, fps: 29.1, encoderDrops: 3)
        XCTAssertTrue(s.warning(for: "hevc422", size: "4032x3024")!.contains("earlier take"))
    }

    func testOlderFilesReadAsQuickChecks() throws {
        let old = #"{"device":"iPhone15,2","system":"27.2","codecs":["hevc420"],"fps":{"hevc420":{"4032x3024":27.5}},"measured":true}"#
        let s = try JSONDecoder().decode(EncoderSupport.self, from: Data(old.utf8))
        XCTAssertEqual(s.method, .quick)
        XCTAssertTrue(s.proven.isEmpty)
        var careful = s
        careful.method = .careful
        careful.record(take: "hevc420", size: "4032x3024", seconds: 10, fps: 30, encoderDrops: 0)
        let again = try JSONDecoder().decode(EncoderSupport.self, from: JSONEncoder().encode(careful))
        XCTAssertEqual(again, careful)
    }
}

final class LogSharingScheduleTests: XCTestCase {
    func testLeavingTheAppWaitsUnlessATakeRan() {
        let now = Date()
        let recent = now.addingTimeInterval(-60)
        XCTAssertFalse(LogSharing.due(reason: "left the app", lastUpload: recent, tookSince: false, now: now))
        XCTAssertTrue(LogSharing.due(reason: "left the app", lastUpload: recent, tookSince: true, now: now))
        XCTAssertTrue(LogSharing.due(reason: "left the app", lastUpload: now.addingTimeInterval(-16 * 60), tookSince: false, now: now))
        XCTAssertTrue(LogSharing.due(reason: "launch", lastUpload: recent, tookSince: false, now: now))
        XCTAssertTrue(LogSharing.due(reason: "asked", lastUpload: recent, tookSince: false, now: now))
    }

    func testTheOpenLogWaitsUnlessAskedOrAfterATake() {
        let files = [LogShareFile(path: "logs/session_old.log", size: 5), LogShareFile(path: "logs/session_now.log", size: 9)]
        XCTAssertEqual(LogSharing.choose(files, openLog: "logs/session_now.log", sendOpenLog: false).map(\.path), ["logs/session_old.log"])
        XCTAssertEqual(LogSharing.choose(files, openLog: "logs/session_now.log", sendOpenLog: true).count, 2)
    }

    func testUploadsCompressToRawDeflate() throws {
        let json = Data(String(repeating: "10:00:00.000 I Recording: 30.00 fps now\n", count: 500).utf8)
        let packed = try (json as NSData).compressed(using: .zlib) as Data
        XCTAssertLessThan(packed.count, json.count / 10)
        XCTAssertEqual(try (packed as NSData).decompressed(using: .zlib) as Data, json)
    }
}
