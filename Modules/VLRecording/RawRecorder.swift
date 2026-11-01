import CoreVideo
import Darwin
import Foundation
import VLCore

/// Copies frames into a bounded memory pool and appends them to frames.raw on a writer
/// queue. When the pool is full, frames are dropped and counted rather than stalling
/// capture. Phase 3's encoder will sit beside this in VLRecording.
public final class RawRecorder {
    public struct Config {
        public var directory: URL
        public var writeFrames: Bool
        public var memoryBudget: Int
        public var context: ClipContext

        public init(directory: URL, writeFrames: Bool, memoryBudget: Int, context: ClipContext) {
            self.directory = directory
            self.writeFrames = writeFrames
            self.memoryBudget = memoryBudget
            self.context = context
        }
    }

    private let config: Config
    private let stats = FrameStats()
    private let lock = NSLock()
    private let writer = DispatchQueue(label: "vibelog.writer", qos: .userInitiated)
    private let references = DispatchGroup()

    private var layout: FrameLayout?
    private var fileDescriptor: Int32 = -1
    private var freeBlocks: [UnsafeMutableRawPointer] = []
    private var allocatedBlocks: [UnsafeMutableRawPointer] = []
    private var blocksInUse = 0
    private var peakBlocks = 0
    private var blockLimit = 0
    private var records: [FrameRecord] = []
    private var bytesWritten = 0
    private var writeSeconds = 0.0
    private var writeFailed = false
    private var finished = false
    private var errors: [String] = []
    private var cfa: CFAPattern?
    private var referenceMetadata: DNGMetadata?

    public init(config: Config) throws {
        self.config = config
        try FileManager.default.createDirectory(at: config.directory, withIntermediateDirectories: true)
    }

    /// Takes one frame on the capture thread. Returns false if it was dropped.
    @discardableResult
    public func append(_ frame: RawFrame) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !finished else { return false }

        if layout == nil {
            guard begin(with: frame) else { return false }
        }
        guard let layout, FrameLayout(buffer: frame.buffer) == layout else {
            noteError("Frame layout changed mid-clip")
            stats.recordWriterDrop()
            return false
        }

        let index = records.count
        var record = FrameRecord(
            index: index, fileOffset: nil, pts: frame.pts, exposureSeconds: frame.exposureSeconds,
            iso: frame.iso, whiteBalanceGains: frame.whiteBalanceGains)

        if config.writeFrames {
            guard let block = takeBlock(size: layout.bytesPerFrame) else {
                stats.recordWriterDrop()
                return false
            }
            guard copy(frame.buffer, layout: layout, to: block) else {
                freeBlocks.append(block)
                blocksInUse -= 1
                stats.recordWriterDrop()
                return false
            }
            record.fileOffset = index * layout.bytesPerFrame
            let size = layout.bytesPerFrame
            writer.async { [self] in write(block, size: size) }
        }
        records.append(record)
        stats.recordFrame(pts: frame.pts)
        return true
    }

    public func recordCaptureDrop() { stats.recordCaptureDrop() }
    public func recordCaptureFailure() { stats.recordCaptureFailure() }

    public func beginReference() { references.enter() }

    /// Stores the reference DNG and its calibration tags in the clip folder.
    public func finishReference(dng: Data?, metadata: [String: Any]) {
        defer { references.leave() }
        let folder = config.directory
        if let dng {
            try? dng.write(to: folder.appendingPathComponent("reference.dng"))
            do {
                let parsed = try DNGMetadata(dng: dng)
                lock.lock()
                referenceMetadata = parsed
                lock.unlock()
            } catch {
                Log.shared.error("Reference DNG parse failed: \(error)")
            }
        } else {
            Log.shared.warn("No reference DNG was produced")
        }
        let safe = Self.jsonSafe(metadata)
        if let data = try? JSONSerialization.data(withJSONObject: safe, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: folder.appendingPathComponent("reference_metadata.json"))
        }
    }

    /// Stops taking frames, drains the writer and writes clip.json.
    public func finish(completion: @escaping (ClipResult) -> Void) {
        lock.lock()
        finished = true
        lock.unlock()
        writer.async { [self] in
            references.wait()
            if fileDescriptor >= 0 { close(fileDescriptor) }
            let result = writeSidecar()
            lock.lock()
            allocatedBlocks.forEach { free($0) }
            allocatedBlocks.removeAll()
            freeBlocks.removeAll()
            lock.unlock()
            DispatchQueue.main.async { completion(result) }
        }
    }

    // MARK: Private

    private func begin(with frame: RawFrame) -> Bool {
        let layout = FrameLayout(buffer: frame.buffer)
        guard layout.bytesPerFrame > 0 else {
            noteError("Frame has no addressable bytes")
            return false
        }
        self.layout = layout
        cfa = frame.cfa
        blockLimit = max(2, config.memoryBudget / layout.bytesPerFrame)
        Log.shared.info("Recording \(layout.pixelFormat) \(layout.width)x\(layout.height), "
            + "\(layout.bytesPerFrame / 1_000_000) MB per frame, pool limit \(blockLimit) frames")
        guard config.writeFrames else { return true }

        let path = config.directory.appendingPathComponent("frames.raw").path
        fileDescriptor = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        guard fileDescriptor >= 0 else {
            noteError("Cannot open frames.raw: errno \(errno)")
            return false
        }
        _ = fcntl(fileDescriptor, F_NOCACHE, 1)
        return true
    }

    private func takeBlock(size: Int) -> UnsafeMutableRawPointer? {
        var block = freeBlocks.popLast()
        if block == nil, allocatedBlocks.count < blockLimit {
            var pointer: UnsafeMutableRawPointer?
            if posix_memalign(&pointer, 16384, size) == 0, let pointer {
                allocatedBlocks.append(pointer)
                block = pointer
            } else {
                noteError("Pool allocation failed")
            }
        }
        if block != nil {
            blocksInUse += 1
            peakBlocks = max(peakBlocks, blocksInUse)
        }
        return block
    }

    private func copy(_ buffer: CVPixelBuffer, layout: FrameLayout, to block: UnsafeMutableRawPointer) -> Bool {
        guard CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else {
            noteError("Cannot lock pixel buffer")
            return false
        }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let isPlanar = CVPixelBufferIsPlanar(buffer)
        for (index, plane) in layout.planes.enumerated() {
            let base = isPlanar
                ? CVPixelBufferGetBaseAddressOfPlane(buffer, index)
                : CVPixelBufferGetBaseAddress(buffer)
            guard let base else {
                noteError("Pixel buffer has no base address, it may be compressed")
                return false
            }
            memcpy(block + plane.offset, base, plane.size)
        }
        return true
    }

    private func write(_ block: UnsafeMutableRawPointer, size: Int) {
        let start = DispatchTime.now().uptimeNanoseconds
        var remaining = size
        var cursor = UnsafeRawPointer(block)
        while remaining > 0, !writeFailed {
            let count = Darwin.write(fileDescriptor, cursor, remaining)
            if count <= 0 {
                writeFailed = true
                let code = errno
                lock.lock()
                noteError("Write failed: errno \(code)")
                lock.unlock()
                break
            }
            remaining -= count
            cursor += count
        }
        writeSeconds += Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9
        bytesWritten += size - remaining
        lock.lock()
        freeBlocks.append(block)
        blocksInUse -= 1
        lock.unlock()
    }

    private func noteError(_ message: String) {
        if !errors.contains(message) {
            errors.append(message)
            Log.shared.error(message)
        }
    }

    private func writeSidecar() -> ClipResult {
        let snapshot = stats.snapshot()
        lock.lock()
        let metadata = referenceMetadata
        let frames = records
        let layout = self.layout
        let cfa = self.cfa
        let peak = peakBlocks
        let limit = blockLimit
        let errors = self.errors
        lock.unlock()

        let throughput = writeSeconds > 0 ? Double(bytesWritten) / 1_000_000 / writeSeconds : 0
        let sidecar = ClipSidecar(
            createdAt: Storage.timestamp(), context: config.context, layout: layout,
            bitsPerSample: cfa == nil ? nil : 14,
            cfaPattern: metadata?.cfaPattern ?? cfa?.rawValue,
            blackLevel: metadata?.blackLevel, whiteLevel: metadata?.whiteLevel,
            whiteBalanceGains: frames.first?.whiteBalanceGains,
            colorMatrix1: metadata?.colorMatrix1, colorMatrix2: metadata?.colorMatrix2,
            dng: metadata, stats: snapshot, bytesWritten: bytesWritten,
            writeThroughputMBps: throughput, peakPoolBlocks: peak, poolLimitBlocks: limit,
            errors: errors, frames: frames)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            let data = try encoder.encode(sidecar)
            try data.write(to: config.directory.appendingPathComponent("clip.json"))
        } catch {
            Log.shared.error("clip.json failed: \(error)")
        }

        let summary = Self.summary(context: config.context, layout: layout, stats: snapshot, throughput: throughput)
        Log.shared.info("CLIP RESULT \(config.directory.lastPathComponent): \(summary)")
        appendBenchmark(snapshot: snapshot, layout: layout, throughput: throughput, peak: peak)
        return ClipResult(directory: config.directory, summary: summary, stats: snapshot)
    }

    private static func summary(
        context: ClipContext, layout: FrameLayout?, stats: FrameStats.Snapshot, throughput: Double
    ) -> String {
        let format = layout.map { "\($0.pixelFormat) \($0.width)x\($0.height)" } ?? "no frames"
        return String(
            format: "%@ %@: %.2f fps sustained, %d frames in %.1fs, gaps ms med %.1f p95 %.1f max %.1f sd %.1f, "
                + "missed~%d capDrop %d fail %d writerDrop %d, disk %.0f MB/s",
            context.method, format, stats.sustainedFPS, stats.frames, stats.durationSeconds,
            stats.gapMedianMs, stats.gapP95Ms, stats.gapMaxMs, stats.gapStdDevMs,
            stats.estimatedMissed, stats.captureDrops, stats.captureFailures, stats.writerDrops,
            throughput)
    }

    private func appendBenchmark(snapshot: FrameStats.Snapshot, layout: FrameLayout?, throughput: Double, peak: Int) {
        let url = Storage.benchmarks
        if !FileManager.default.fileExists(atPath: url.path) {
            try? "clip,method,lens,pixel_format,width,height,write,fps,frames,seconds,gap_med_ms,gap_p95_ms,gap_max_ms,missed,capture_drops,failures,writer_drops,disk_mbps,peak_pool,thermal\n"
                .write(to: url, atomically: true, encoding: .utf8)
        }
        let fields: [String] = [
            config.directory.lastPathComponent, config.context.method, config.context.lens,
            layout?.pixelFormat ?? "", "\(layout?.width ?? 0)", "\(layout?.height ?? 0)",
            "\(config.writeFrames)", String(format: "%.2f", snapshot.sustainedFPS), "\(snapshot.frames)",
            String(format: "%.2f", snapshot.durationSeconds), String(format: "%.2f", snapshot.gapMedianMs),
            String(format: "%.2f", snapshot.gapP95Ms), String(format: "%.2f", snapshot.gapMaxMs),
            "\(snapshot.estimatedMissed)", "\(snapshot.captureDrops)", "\(snapshot.captureFailures)",
            "\(snapshot.writerDrops)", String(format: "%.0f", throughput), "\(peak)", SystemStatus.thermalName,
        ]
        let line = fields.map { $0.replacingOccurrences(of: ",", with: ";") }.joined(separator: ",") + "\n"
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        }
    }

    /// Reduces capture metadata to values JSONSerialization accepts.
    static func jsonSafe(_ value: Any) -> Any {
        switch value {
        case let dictionary as [AnyHashable: Any]:
            var result: [String: Any] = [:]
            for (key, item) in dictionary {
                result[String(describing: key)] = jsonSafe(item)
            }
            return result
        case let array as [Any]:
            return array.map(jsonSafe)
        case let string as String:
            return string
        case let number as NSNumber:
            return number.doubleValue.isFinite ? number : String(describing: number)
        case let data as Data:
            return data.base64EncodedString()
        default:
            return String(describing: value)
        }
    }
}
