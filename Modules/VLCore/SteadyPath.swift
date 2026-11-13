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
/// It works with the optical stabilizer, which the iPhone 14 Pro's 1x runs during RAW capture.
/// The path models what the optics did and corrects only what reached the picture: the optics
/// take a share of each turn's fast part, above about 0.6 Hz, but only as far as their travel
/// allows, so a large shake mostly passes and a pan's start and stop pass in full. Fitted on
/// take 220644's own frames, this left 0.77 px a frame of shake above 2 Hz up and down in the
/// held stretch, against 1.96 for a model that left everything above 2 Hz to the optics. Roll,
/// which the optics leave alone, is corrected at every speed.
///
/// Angles are summed axis by axis, which is exact only for small turns, but what's corrected is
/// the difference between two smoothed copies of the same sum, a few degrees at most.
public struct SteadyPath: Sendable {
    public struct Settings: Equatable, Sendable {
        /// The spread, in seconds, of the smoothing that gives the camera's wanted path.
        public var smoothSeconds = 0.6
        /// What the lens's optical stabilizer takes out of the picture, or nil for a lens without
        /// one, whose every turn reaches the picture.
        public var optics: Optics? = .wide
        /// How far the picture may be enlarged to hide its moving edges.
        public var maxZoom = 1.3
        /// The gyro's time for a frame's time. Fast shake fits best at +5 ms on the 1x, take
        /// 220644, on all three axes, and at 0 to -5 ms on the ultra wide, take 000714. The first
        /// guess, 20 ms early, came from slow pans, which barely tell, and left two thirds of the
        /// ultra wide's shake in.
        public var frameOffset = 0.0

        public init() {}
    }

    /// A model of an optical stabilizer: it holds back `share` of the part of each turn faster
    /// than `cornerHertz`, as a first-order high-pass does, up to about `travel` radians, past
    /// which it gives way softly.
    public struct Optics: Equatable, Sendable {
        public var share: Double
        public var cornerHertz: Double
        public var travel: Double

        public init(share: Double, cornerHertz: Double, travel: Double) {
            self.share = share
            self.cornerHertz = cornerHertz
            self.travel = travel
        }

        /// The 14 Pro's 1x, fitted on take 220644's frames: a share of 0.9 above 0.6 Hz, within
        /// about 0.006 rad, 17 px at its focal length. Both halves of the take gave the same fit.
        public static let wide = Optics(share: 0.9, cornerHertz: 0.6, travel: 0.006)

        /// How far the optics turned the picture back at each reading, from the angles turned so
        /// far, `step` seconds apart. It runs forward in time only, as the optics do.
        public func held(_ angles: [Double], step: Double) -> [Double] {
            guard travel > 0, share > 0, angles.count > 1 else { return angles.map { _ in 0 } }
            let keep = 1 / (1 + 2 * Double.pi * cornerHertz * step)
            var fast = 0.0
            var out = [Double](repeating: 0, count: angles.count)
            for index in 1..<angles.count {
                fast = keep * (fast + angles[index] - angles[index - 1])
                out[index] = travel * tanh(share * fast / travel)
            }
            return out
        }
    }

    public let settings: Settings
    private let start: Double
    private let step: Double
    /// What to undo at each step, as turns about the phone's x, y and z, in radians.
    private let excess: [SIMD3<Double>]

    private init(settings: Settings, start: Double, step: Double, excess: [SIMD3<Double>]) {
        self.settings = settings
        self.start = start
        self.step = step
        self.excess = excess
    }

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
        // What reached the picture: the turn less what the optics held back, on the two axes
        // they steady.
        var seen = angles
        if let optics = settings.optics {
            let heldX = optics.held(angles.map(\.x), step: step)
            let heldY = optics.held(angles.map(\.y), step: step)
            for index in seen.indices {
                seen[index].x -= heldX[index]
                seen[index].y -= heldY[index]
            }
        }
        let wanted = Self.smoothed(seen, spread: settings.smoothSeconds / step)
        excess = seen.indices.map { seen[$0] - wanted[$0] }
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
        let share = Self.share(of: turn, width: width, height: height, focal: focal, zoom: zoom)
        return Self.warp(turn * share, width: width, height: height, focal: focal, zoom: zoom)
    }

    /// How much of `turn` can be undone at `zoom` before an edge shows: 1 for all of it.
    static func share(of turn: SIMD3<Double>, width: Double, height: Double, focal: Double, zoom: Double) -> Double {
        if fits(warp(turn, width: width, height: height, focal: focal, zoom: zoom), width: width, height: height) { return 1 }
        var low = 0.0
        var high = 1.0
        for _ in 0..<12 {
            let middle = (low + high) / 2
            if fits(warp(turn * middle, width: width, height: height, focal: focal, zoom: zoom), width: width, height: height) {
                low = middle
            } else {
                high = middle
            }
        }
        return low
    }

    /// This path with every moment turned back only as far as fits at `zoom`, eased in and out
    /// over about a third of a second. Cut off frame by frame, the picture stopped dead against
    /// its edge and started again, which showed as a shake of its own on take 000714. A path
    /// that already fits comes back as it is.
    public func eased(width: Double, height: Double, focal: Double, zoom: Double) -> SteadyPath {
        let shares = excess.map {
            Self.share(of: Self.pictureTurn($0), width: width, height: height, focal: focal, zoom: zoom)
        }
        guard shares.contains(where: { $0 < 1 }) else { return self }
        // The least share nearby, so the easing starts before the edge is reached.
        let reach = max(Int((0.3 / step).rounded()), 1)
        let least = shares.indices.map { index -> SIMD3<Double> in
            let nearby = shares[max(0, index - reach)...min(shares.count - 1, index + reach)]
            return SIMD3(nearby.min() ?? 1, 0, 0)
        }
        let soft = Self.smoothed(least, spread: 0.12 / step)
        let eased = excess.indices.map { excess[$0] * min(shares[$0], soft[$0].x) }
        return SteadyPath(settings: settings, start: start, step: step, excess: eased)
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
