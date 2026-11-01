import CoreVideo
import Metal
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

final class LogCurveTests: XCTestCase {
    func testMiddleGrayMatchesPublishedValues() {
        XCTAssertEqual(LogCurve.appleLog.encode(0.18), 0.4882724585, accuracy: 1e-8)
        XCTAssertEqual(LogCurve.sLog3.encode(0.18), 420.0 / 1023, accuracy: 1e-9)
        XCTAssertEqual(LogCurve.logC3.encode(0.18), 0.3910068, accuracy: 1e-6)
    }

    func testPublishedCodeValues() {
        XCTAssertEqual(LogCurve.sLog3.encode(0) * 1023, 95, accuracy: 1e-6)
        XCTAssertEqual(LogCurve.sLog3.encode(0.9) * 1023, 598, accuracy: 1)
        XCTAssertEqual(LogCurve.logC3.encode(0), 0.092809, accuracy: 1e-9)
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
            for knee in [0.01, 0.01125, 0.010591] {
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

    func testLUTSize() {
        XCTAssertEqual(MonitorTransform.lut(curve: .sLog3, size: 5).count, 5 * 5 * 5 * 4)
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

    func testShaderMatchesSwiftCurves() throws {
        let pipeline = try makePipeline()
        var settings = ProcessingSettings()
        settings.exposureStops = 0
        for curve in LogCurve.allCases {
            for demosaic in DemosaicMethod.allCases {
                settings.curve = curve
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
