import Foundation
import simd

extension GyroLog {
    /// The readings of a `.gcsv` this app wrote, with its own scales. Rows that don't parse are
    /// left out.
    public static func samples(from text: String) -> [MotionSample] {
        var timeScale = 0.000001
        var rotationScale = 0.00001
        var accelerationScale = 0.0001
        var samples: [MotionSample] = []
        var inRows = false
        for line in text.split(whereSeparator: \.isNewline) {
            let fields = line.split(separator: ",", omittingEmptySubsequences: false)
            if !inRows {
                if fields.first == "t" {
                    inRows = true
                } else if fields.count == 2, let value = Double(fields[1]) {
                    switch fields[0] {
                    case "tscale": timeScale = value
                    case "gscale": rotationScale = value
                    case "ascale": accelerationScale = value
                    default: break
                    }
                }
                continue
            }
            let numbers = fields.compactMap { Double($0) }
            guard numbers.count >= 7 else { continue }
            samples.append(MotionSample(
                seconds: numbers[0] * timeScale,
                rotation: SIMD3(numbers[1], numbers[2], numbers[3]) * rotationScale,
                acceleration: SIMD3(numbers[4], numbers[5], numbers[6]) * accelerationScale))
        }
        return samples
    }
}

/// How far each frame of a take should be turned back to steady it, from the take's gyro log.
///
/// It works with the optical stabilizer, which the iPhone 14 Pro runs during RAW capture: take
/// 220644 showed pans reaching the picture whole, a hand's shake above about 2 Hz at only 0.13
/// to 0.35 of what the gyro predicts, and roll at 0.89. So for the two axes the optics steady,
/// the path corrects what lies between the wanted smoothness and that 2 Hz, and leaves the rest
/// to the optics, where a plain gyro correction would add the shake back in reverse. Roll, which
/// the optics leave alone, is corrected at every speed.
///
/// Angles are summed axis by axis, which is exact only for small turns, but what's corrected is
/// the difference between two smoothed copies of the same sum, a few degrees at most.
public struct SteadyPath: Sendable {
    public struct Settings: Equatable, Sendable {
        /// The spread, in seconds, of the smoothing that gives the camera's wanted path.
        public var smoothSeconds = 0.6
        /// The spread that stands for what the optics already took out: about 2 Hz.
        public var opticsSeconds = 0.08
        /// How far the picture may be enlarged to hide its moving edges.
        public var maxZoom = 1.4
        /// The gyro's time for a frame's time. Pans in take 220644 fitted best 10 to 30 ms early.
        public var frameOffset = -0.02

        public init() {}
    }

    public let settings: Settings
    private let start: Double
    private let step: Double
    /// What to undo at each step, as turns about the phone's x, y and z, in radians.
    private let excess: [SIMD3<Double>]

    /// Nil when the log is too short to steady anything.
    public init?(samples: [MotionSample], settings: Settings = Settings()) {
        guard samples.count >= 20, let first = samples.first, let last = samples.last,
            last.seconds > first.seconds
        else { return nil }
        self.settings = settings
        start = first.seconds
        step = (last.seconds - first.seconds) / Double(samples.count - 1)
        // The angle turned so far, by the trapezoid rule over the readings' own times.
        var angles = [SIMD3<Double>](repeating: .zero, count: samples.count)
        for index in 1..<samples.count {
            let seconds = samples[index].seconds - samples[index - 1].seconds
            angles[index] = angles[index - 1] + (samples[index].rotation + samples[index - 1].rotation) * 0.5 * seconds
        }
        let wanted = Self.smoothed(angles, spread: settings.smoothSeconds / step)
        let optics = Self.smoothed(angles, spread: settings.opticsSeconds / step)
        excess = angles.indices.map { index in
            SIMD3(
                optics[index].x - wanted[index].x, optics[index].y - wanted[index].y,
                angles[index].z - wanted[index].z)
        }
    }

    /// A Gaussian average with its spread in steps. Near the ends it averages what there is.
    static func smoothed(_ values: [SIMD3<Double>], spread: Double) -> [SIMD3<Double>] {
        guard spread > 0.01, values.count > 1 else { return values }
        let reach = max(Int((spread * 3).rounded(.up)), 1)
        let weights = (0...reach).map { exp(-0.5 * Double($0 * $0) / (spread * spread)) }
        return values.indices.map { index in
            var total = SIMD3<Double>.zero
            var weight = 0.0
            for offset in max(-reach, -index)...min(reach, values.count - 1 - index) {
                let share = weights[abs(offset)]
                total += values[index + offset] * share
                weight += share
            }
            return total / weight
        }
    }

    /// What to undo for the frame at `seconds` from the take's first frame, about the phone's
    /// axes. Before the log starts and after it ends, the nearest reading's.
    public func excess(at seconds: Double) -> SIMD3<Double> {
        let position = (seconds + settings.frameOffset - start) / step
        guard position > 0 else { return excess[0] }
        let index = Int(position)
        guard index < excess.count - 1 else { return excess[excess.count - 1] }
        let share = position - Double(index)
        return excess[index] * (1 - share) + excess[index + 1] * share
    }

    /// The picture's own turn for a turn of the phone, in the stored picture's axes: x to its
    /// right, y down and z into the scene. Measured on take 220644: a turn about the phone's x
    /// moves the picture right, one about y moves it up, and one about z turns it clockwise.
    public static func pictureTurn(_ phone: SIMD3<Double>) -> SIMD3<Double> {
        SIMD3(phone.y, phone.x, phone.z)
    }

    /// Where an output pixel's content lies in the frame as recorded: `matrix * (x, y, 1)`, then
    /// divided by its third part. The picture is `width` by `height` as stored, with the lens's
    /// focal length in its pixels, enlarged by `zoom` about its middle. A frame that would show
    /// its edge even so is turned back less.
    public func matrix(at seconds: Double, width: Double, height: Double, focal: Double, zoom: Double) -> simd_double3x3 {
        let turn = Self.pictureTurn(excess(at: seconds))
        var share = 1.0
        if !Self.fits(Self.warp(turn, width: width, height: height, focal: focal, zoom: zoom), width: width, height: height) {
            var low = 0.0
            for _ in 0..<12 {
                let middle = (low + share) / 2
                if Self.fits(Self.warp(turn * middle, width: width, height: height, focal: focal, zoom: zoom), width: width, height: height) {
                    low = middle
                } else {
                    share = middle
                }
            }
            share = low
        }
        return Self.warp(turn * share, width: width, height: height, focal: focal, zoom: zoom)
    }

    /// The least enlargement, up to the settings' most, that keeps every frame's edges out of
    /// the picture.
    public func zoom(width: Double, height: Double, focal: Double) -> Double {
        // Every third reading is about a frame apart.
        let turns = stride(from: 0, to: excess.count, by: 3).map { Self.pictureTurn(excess[$0]) }
        func fitsAll(_ zoom: Double) -> Bool {
            turns.allSatisfy { Self.fits(Self.warp($0, width: width, height: height, focal: focal, zoom: zoom), width: width, height: height) }
        }
        if fitsAll(1) { return 1 }
        guard fitsAll(settings.maxZoom) else { return settings.maxZoom }
        var low = 1.0
        var high = settings.maxZoom
        for _ in 0..<16 {
            let middle = (low + high) / 2
            if fitsAll(middle) { high = middle } else { low = middle }
        }
        return high
    }

    public static func warp(_ turn: SIMD3<Double>, width: Double, height: Double, focal: Double, zoom: Double) -> simd_double3x3 {
        let centre = SIMD2(width / 2, height / 2)
        let camera = simd_double3x3(rows: [
            SIMD3(focal, 0, centre.x), SIMD3(0, focal, centre.y), SIMD3(0, 0, 1),
        ])
        // The output shows the middle 1/zoom of the picture.
        let enlarge = simd_double3x3(rows: [
            SIMD3(1 / zoom, 0, centre.x * (1 - 1 / zoom)), SIMD3(0, 1 / zoom, centre.y * (1 - 1 / zoom)), SIMD3(0, 0, 1),
        ])
        return camera * rotation(turn) * camera.inverse * enlarge
    }

    /// Rodrigues' formula: the rotation by `turn`'s length about its direction.
    static func rotation(_ turn: SIMD3<Double>) -> simd_double3x3 {
        let angle = simd_length(turn)
        guard angle > 1e-12 else { return matrix_identity_double3x3 }
        let axis = turn / angle
        let cross = simd_double3x3(rows: [
            SIMD3(0, -axis.z, axis.y), SIMD3(axis.z, 0, -axis.x), SIMD3(-axis.y, axis.x, 0),
        ])
        return matrix_identity_double3x3 + cross * sin(angle) + (cross * cross) * (1 - cos(angle))
    }

    /// Whether the output's four corners all take their content from inside the frame.
    public static func fits(_ matrix: simd_double3x3, width: Double, height: Double) -> Bool {
        for corner in [SIMD3(0, 0, 1.0), SIMD3(width, 0, 1), SIMD3(0, height, 1), SIMD3(width, height, 1)] {
            let source = matrix * corner
            guard source.z > 0 else { return false }
            let x = source.x / source.z
            let y = source.y / source.z
            // Half a pixel of slack, for rounding at no turn at all.
            guard x >= -0.5, y >= -0.5, x <= width + 0.5, y <= height + 0.5 else { return false }
        }
        return true
    }
}
