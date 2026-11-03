import Foundation

/// A 3D LUT from a .cube file, used for monitoring only.
public struct CubeLUT: Sendable {
    public enum ParseError: Error, Equatable {
        case oneDimensional
        case missingSize
        case unsupportedSize(Int)
        case badLine(String)
        case wrongSampleCount(expected: Int, found: Int)
        case badDomain
    }

    public static let maximumSize = 129

    public let size: Int
    public let domainMin: SIMD3<Float>
    public let domainMax: SIMD3<Float>
    /// RGB triples with red varying fastest, as .cube files store them.
    public let samples: [SIMD3<Float>]

    public init(text: String) throws {
        var size: Int?
        var low = SIMD3<Float>(repeating: 0)
        var high = SIMD3<Float>(repeating: 1)
        var samples: [SIMD3<Float>] = []

        func triple(_ parts: ArraySlice<Substring>, line: Substring) throws -> SIMD3<Float> {
            let values = parts.compactMap { Float($0) }
            guard values.count == 3 else { throw ParseError.badLine(String(line)) }
            return SIMD3(values[0], values[1], values[2])
        }

        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.drop { $0 == " " || $0 == "\t" }
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            switch parts[0] {
            case "TITLE":
                continue
            case "LUT_1D_SIZE":
                throw ParseError.oneDimensional
            case "LUT_3D_SIZE":
                guard parts.count == 2, let value = Int(parts[1]) else {
                    throw ParseError.badLine(String(line))
                }
                guard (2...Self.maximumSize).contains(value) else {
                    throw ParseError.unsupportedSize(value)
                }
                size = value
                samples.reserveCapacity(value * value * value)
            case "DOMAIN_MIN":
                low = try triple(parts.dropFirst(), line: line)
            case "DOMAIN_MAX":
                high = try triple(parts.dropFirst(), line: line)
            default:
                samples.append(try triple(parts[...], line: line))
            }
        }

        guard let size else { throw ParseError.missingSize }
        let expected = size * size * size
        guard samples.count == expected else {
            throw ParseError.wrongSampleCount(expected: expected, found: samples.count)
        }
        guard low.x < high.x, low.y < high.y, low.z < high.z else { throw ParseError.badDomain }
        self.size = size
        domainMin = low
        domainMax = high
        self.samples = samples
    }

    /// A LUT made in code over the unit cube, such as the built-in ACES looks.
    public init(size: Int, samples: [SIMD3<Float>]) {
        self.size = size
        domainMin = SIMD3(repeating: 0)
        domainMax = SIMD3(repeating: 1)
        self.samples = samples
    }

    /// RGBA samples for a cubic rgba16Unorm texture.
    public var textureSamples: [UInt16] {
        var output = [UInt16]()
        output.reserveCapacity(samples.count * 4)
        for sample in samples {
            for channel in 0..<3 {
                output.append(UInt16((min(max(sample[channel], 0), 1) * 65535).rounded()))
            }
            output.append(65535)
        }
        return output
    }
}
