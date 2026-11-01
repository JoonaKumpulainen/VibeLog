import CoreVideo
import XCTest
import VLCore
import VLRecording

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
