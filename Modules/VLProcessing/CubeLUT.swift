import Foundation
import simd

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

    /// The LUT at a point, interpolated between the eight grid points around it, as the GPU's
    /// texture lookup does. For building a LUT from this one on the CPU.
    public func sample(_ input: SIMD3<Float>) -> SIMD3<Float> {
        let last = Float(size - 1)
        // A value that isn't a number would stop the app when it's made an index.
        let input = SIMD3(input.x.isFinite ? input.x : 0, input.y.isFinite ? input.y : 0, input.z.isFinite ? input.z : 0)
        let unit = simd_clamp((input - domainMin) / (domainMax - domainMin), SIMD3(repeating: 0), SIMD3(repeating: 1))
        let position = unit * last
        let low = SIMD3<Int>(Int(position.x), Int(position.y), Int(position.z))
        let high = pointwiseMin(low &+ 1, SIMD3(repeating: size - 1))
        let t = position - SIMD3<Float>(Float(low.x), Float(low.y), Float(low.z))
        func at(_ r: Int, _ g: Int, _ b: Int) -> SIMD3<Float> { samples[(b * size + g) * size + r] }
        let c00 = simd_mix(at(low.x, low.y, low.z), at(high.x, low.y, low.z), SIMD3(repeating: t.x))
        let c10 = simd_mix(at(low.x, high.y, low.z), at(high.x, high.y, low.z), SIMD3(repeating: t.x))
        let c01 = simd_mix(at(low.x, low.y, high.z), at(high.x, low.y, high.z), SIMD3(repeating: t.x))
        let c11 = simd_mix(at(low.x, high.y, high.z), at(high.x, high.y, high.z), SIMD3(repeating: t.x))
        let c0 = simd_mix(c00, c10, SIMD3(repeating: t.y))
        let c1 = simd_mix(c01, c11, SIMD3(repeating: t.y))
        return simd_mix(c0, c1, SIMD3(repeating: t.z))
    }

    /// RGBA samples for a cubic rgba16Unorm texture. A value that isn't a number becomes black:
    /// converting one to an integer stops the app, as a graded export preview did on 2026-11-07.
    public var textureSamples: [UInt16] {
        var output = [UInt16]()
        output.reserveCapacity(samples.count * 4)
        for sample in samples {
            for channel in 0..<3 {
                let value = sample[channel]
                output.append(value.isFinite ? UInt16((min(max(value, 0), 1) * 65535).rounded()) : 0)
            }
            output.append(65535)
        }
        return output
    }
}
