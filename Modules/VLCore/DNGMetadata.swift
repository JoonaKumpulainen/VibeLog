import Foundation

/// Calibration tags read from the reference DNG, in the shape Phase 2 needs.
public struct DNGMetadata: Codable, Equatable, Sendable {
    public var make: String?
    public var model: String?
    public var cfaPattern: String?
    public var blackLevel: [Double]?
    public var whiteLevel: [Double]?
    public var asShotNeutral: [Double]?
    public var colorMatrix1: [Double]?
    public var colorMatrix2: [Double]?
    public var forwardMatrix1: [Double]?
    public var forwardMatrix2: [Double]?
    public var cameraCalibration1: [Double]?
    public var cameraCalibration2: [Double]?
    public var calibrationIlluminant1: [Double]?
    public var calibrationIlluminant2: [Double]?
    public var baselineExposure: [Double]?
    public var noiseProfile: [Double]?
    public var activeArea: [Double]?
    public var bitsPerSample: [Double]?

    public init(dng data: Data) throws {
        let tags = try TIFFReader(data: data).readAllIFDs()
        make = tags.strings[271]
        model = tags.strings[272]
        cfaPattern = tags.numbers[33422].flatMap { CFAPattern(dngPattern: $0)?.rawValue }
        blackLevel = tags.numbers[50714]
        whiteLevel = tags.numbers[50717]
        asShotNeutral = tags.numbers[50728]
        colorMatrix1 = tags.numbers[50721]
        colorMatrix2 = tags.numbers[50722]
        forwardMatrix1 = tags.numbers[50964]
        forwardMatrix2 = tags.numbers[50965]
        cameraCalibration1 = tags.numbers[50723]
        cameraCalibration2 = tags.numbers[50724]
        calibrationIlluminant1 = tags.numbers[50778]
        calibrationIlluminant2 = tags.numbers[50779]
        baselineExposure = tags.numbers[50730]
        noiseProfile = tags.numbers[51041]
        activeArea = tags.numbers[50829]
        bitsPerSample = tags.numbers[258]
    }
}

/// Minimal TIFF reader for DNG tags. Walks IFD0, its chain and SubIFDs; the first
/// value seen for a tag wins, and raw-only tags appear only in the raw IFD.
public struct TIFFReader {
    public enum Failure: Error { case notTIFF, truncated }

    public struct Tags {
        public var numbers: [UInt16: [Double]] = [:]
        public var strings: [UInt16: String] = [:]
    }

    private let bytes: [UInt8]
    private let littleEndian: Bool
    private let maxValues = 4096

    public init(data: Data) throws {
        bytes = [UInt8](data)
        guard bytes.count >= 8 else { throw Failure.notTIFF }
        if bytes[0] == 0x49, bytes[1] == 0x49 {
            littleEndian = true
        } else if bytes[0] == 0x4D, bytes[1] == 0x4D {
            littleEndian = false
        } else {
            throw Failure.notTIFF
        }
        guard try u16(2) == 42 else { throw Failure.notTIFF }
    }

    public func readAllIFDs() throws -> Tags {
        var tags = Tags()
        var pending = [Int(try u32(4))]
        var visited = Set<Int>()
        while let offset = pending.popLast() {
            guard offset != 0, visited.insert(offset).inserted else { continue }
            pending += try readIFD(at: offset, into: &tags)
        }
        return tags
    }

    private func readIFD(at offset: Int, into tags: inout Tags) throws -> [Int] {
        var next: [Int] = []
        let count = Int(try u16(offset))
        for index in 0..<count {
            let entry = offset + 2 + index * 12
            let tag = try u16(entry)
            let type = Int(try u16(entry + 2))
            let valueCount = Int(try u32(entry + 4))
            guard let size = Self.typeSize(type), valueCount > 0 else { continue }
            let total = size * valueCount
            let dataOffset = total <= 4 ? entry + 8 : Int(try u32(entry + 8))
            if type == 2 {
                guard dataOffset + total <= bytes.count else { continue }
                if tags.strings[tag] == nil {
                    let raw = bytes[dataOffset..<(dataOffset + total)].prefix { $0 != 0 }
                    tags.strings[tag] = String(decoding: raw, as: UTF8.self)
                }
                continue
            }
            guard valueCount <= maxValues, dataOffset + total <= bytes.count else { continue }
            let values = try (0..<valueCount).map {
                try number(type: type, at: dataOffset + $0 * size)
            }
            if tag == 330 {
                next += values.map { Int($0) }
            } else if tags.numbers[tag] == nil {
                tags.numbers[tag] = values
            }
        }
        next.append(Int(try u32(offset + 2 + count * 12)))
        return next
    }

    private static func typeSize(_ type: Int) -> Int? {
        switch type {
        case 1, 2, 6, 7: return 1
        case 3, 8: return 2
        case 4, 9, 11: return 4
        case 5, 10, 12: return 8
        default: return nil
        }
    }

    private func number(type: Int, at offset: Int) throws -> Double {
        switch type {
        case 1, 7:
            guard offset < bytes.count else { throw Failure.truncated }
            return Double(bytes[offset])
        case 6:
            guard offset < bytes.count else { throw Failure.truncated }
            return Double(Int8(bitPattern: bytes[offset]))
        case 3: return Double(try u16(offset))
        case 8: return Double(Int16(bitPattern: try u16(offset)))
        case 4: return Double(try u32(offset))
        case 9: return Double(Int32(bitPattern: try u32(offset)))
        case 5:
            let denominator = try u32(offset + 4)
            return denominator == 0 ? 0 : Double(try u32(offset)) / Double(denominator)
        case 10:
            let denominator = Int32(bitPattern: try u32(offset + 4))
            return denominator == 0 ? 0 : Double(Int32(bitPattern: try u32(offset))) / Double(denominator)
        case 11: return Double(Float(bitPattern: try u32(offset)))
        case 12:
            let high = UInt64(try u32(littleEndian ? offset + 4 : offset))
            let low = UInt64(try u32(littleEndian ? offset : offset + 4))
            return Double(bitPattern: (high << 32) | low)
        default: return 0
        }
    }

    private func u16(_ offset: Int) throws -> UInt16 {
        guard offset >= 0, offset + 2 <= bytes.count else { throw Failure.truncated }
        let a = UInt16(bytes[offset])
        let b = UInt16(bytes[offset + 1])
        return littleEndian ? a | (b << 8) : (a << 8) | b
    }

    private func u32(_ offset: Int) throws -> UInt32 {
        guard offset >= 0, offset + 4 <= bytes.count else { throw Failure.truncated }
        let a = UInt32(bytes[offset])
        let b = UInt32(bytes[offset + 1])
        let c = UInt32(bytes[offset + 2])
        let d = UInt32(bytes[offset + 3])
        return littleEndian
            ? a | (b << 8) | (c << 16) | (d << 24)
            : (a << 24) | (b << 16) | (c << 8) | d
    }
}
