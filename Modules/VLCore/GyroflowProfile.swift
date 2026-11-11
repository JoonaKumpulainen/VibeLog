import Foundation

/// A `LensProfile` written as a lens profile Gyroflow loads, so its stabilization knows the lens
/// of a VibeLog take. Gyroflow describes distortion with OpenCV's fisheye model, four
/// coefficients of a polynomial in the angle from the lens's axis, so Apple's table of
/// magnification along the radius is fitted to that. Only a lens Apple gave a table for gets one:
/// a focal length alone would call a distorted lens straight.
public enum GyroflowProfile {
    /// The coefficients, and how far the fit strays from Apple's table, in pixels rms.
    public struct Fit: Equatable, Sendable {
        public var coefficients: [Double]
        public var rms: Double
    }

    /// The radius Apple's table sends an undistorted radius to, both in pixels from the
    /// distortion centre. The table holds the magnification at evenly spaced radii from the
    /// centre out to `reach`, the farthest corner, as Apple's own sample code reads it.
    public static func distorted(radius: Double, table: [Double], reach: Double) -> Double {
        guard table.count > 1, reach > 0 else { return radius }
        let place = min(max(radius / reach, 0), 1) * Double(table.count - 1)
        let index = min(Int(place), table.count - 2)
        let part = place - Double(index)
        return radius * (1 + table[index] * (1 - part) + table[index + 1] * part)
    }

    /// From the distortion centre to the farthest corner of the picture.
    static func reach(_ profile: LensProfile) -> Double {
        let x = profile.distortionCenterX ?? profile.cx
        let y = profile.distortionCenterY ?? profile.cy
        return hypot(max(x, Double(profile.width) - x), max(y, Double(profile.height) - y))
    }

    /// The fisheye model's radius in pixels for an undistorted one: the angle from the axis,
    /// times one plus the polynomial in its square, times the focal length.
    public static func modelled(radius: Double, focal: Double, coefficients k: [Double]) -> Double {
        let angle = atan(radius / focal)
        var sum = 1.0
        var power = 1.0
        for value in k {
            power *= angle * angle
            sum += value * power
        }
        return focal * angle * sum
    }

    /// Least squares on the error in pixels, at 200 radii out to the farthest corner. The angle
    /// is scaled to 0...1 for the solve, since its ninth power beside its third is otherwise too
    /// small to solve with on a long lens.
    public static func fit(_ profile: LensProfile) -> Fit? {
        guard profile.isCalibrated, profile.fx > 0, profile.fy > 0 else { return nil }
        let focal = (profile.fx + profile.fy) / 2
        let reach = Self.reach(profile)
        let widest = atan(reach / focal)
        guard widest > 0 else { return nil }
        let samples = 200
        var matrix = [[Double]](repeating: [Double](repeating: 0, count: 4), count: 4)
        var target = [Double](repeating: 0, count: 4)
        for sample in 1...samples {
            let radius = reach * Double(sample) / Double(samples)
            let angle = atan(radius / focal)
            let scaled = angle / widest
            let basis = (0..<4).map { focal * widest * pow(scaled, Double(2 * $0 + 3)) }
            let wanted = distorted(radius: radius, table: profile.distortionTable, reach: reach) - focal * angle
            for row in 0..<4 {
                target[row] += basis[row] * wanted
                for column in 0..<4 { matrix[row][column] += basis[row] * basis[column] }
            }
        }
        guard let solved = solve(matrix, target) else { return nil }
        let coefficients = (0..<4).map { solved[$0] / pow(widest, Double(2 * $0 + 2)) }
        var squares = 0.0
        for sample in 1...samples {
            let radius = reach * Double(sample) / Double(samples)
            let error = modelled(radius: radius, focal: focal, coefficients: coefficients)
                - distorted(radius: radius, table: profile.distortionTable, reach: reach)
            squares += error * error
        }
        return Fit(coefficients: coefficients, rms: (squares / Double(samples)).squareRoot())
    }

    /// Gaussian elimination with the largest pivot first, or nil when there's no one answer.
    static func solve(_ matrix: [[Double]], _ target: [Double]) -> [Double]? {
        let count = target.count
        var rows = matrix.enumerated().map { $0.element + [target[$0.offset]] }
        for column in 0..<count {
            guard let pivot = (column..<count).max(by: { abs(rows[$0][column]) < abs(rows[$1][column]) }),
                  abs(rows[pivot][column]) > 1e-300 else { return nil }
            rows.swapAt(column, pivot)
            for row in (column + 1)..<count {
                let factor = rows[row][column] / rows[column][column]
                for index in column...count { rows[row][index] -= factor * rows[column][index] }
            }
        }
        var answer = [Double](repeating: 0, count: count)
        for row in stride(from: count - 1, through: 0, by: -1) {
            var value = rows[row][count]
            for index in (row + 1)..<count { value -= rows[row][index] * answer[index] }
            answer[row] = value / rows[row][row]
        }
        return answer.allSatisfy(\.isFinite) ? answer : nil
    }

    /// The picture a profile is for: the lens's whole frame, or its centred 16:9 crop.
    static func size(_ profile: LensProfile, widescreen: Bool) -> (width: Int, height: Int) {
        guard widescreen else { return (profile.width, profile.height) }
        // Even, as the encoder's sizes are.
        return (profile.width, profile.width * 9 / 16 / 2 * 2)
    }

    static func lensName(_ lens: String) -> String {
        switch lens {
        case "back-wide": return "1x"
        case "back-ultrawide": return "0.5x"
        case "back-tele": return "Tele"
        default: return lens
        }
    }

    public static func fileName(_ profile: LensProfile, widescreen: Bool) -> String {
        let size = Self.size(profile, widescreen: widescreen)
        return "gyroflow-\(profile.lens)-\(size.width)x\(size.height).json"
    }

    /// The profile as Gyroflow's JSON, or nil for a lens with no table. Gyroflow scales a profile
    /// to a smaller take of the same shape itself, so one for each shape covers every size. The
    /// readout time is left out, for Gyroflow to estimate, since it hasn't been measured.
    public static func json(for profile: LensProfile, widescreen: Bool) -> Data? {
        guard let fit = Self.fit(profile) else { return nil }
        let size = Self.size(profile, widescreen: widescreen)
        // A centred crop only moves the centre up by half of what it cuts.
        let centreY = profile.cy - Double(profile.height - size.height) / 2
        let dimension: [String: Any] = ["w": size.width, "h": size.height]
        let lens = lensName(profile.lens)
        let shape = widescreen ? "16:9" : "open gate"
        let document: [String: Any] = [
            "name": "Apple_\(profile.model)_\(lens)_VibeLog_\(size.width)x\(size.height)",
            "note": "Apple's factory calibration as VibeLog read it, fitted within "
                + String(format: "%.3f", fit.rms) + " px. For VibeLog takes with lens distortion correction off.",
            "calibrated_by": "VibeLog",
            "camera_brand": "Apple",
            "camera_model": profile.model,
            "lens_model": lens,
            "camera_setting": "VibeLog RAW, \(shape)",
            "calib_dimension": dimension,
            "orig_dimension": dimension,
            "output_dimension": dimension,
            "input_horizontal_stretch": 1.0,
            "input_vertical_stretch": 1.0,
            "num_images": profile.captures ?? 1,
            "fps": 30.0,
            "official": false,
            "asymmetrical": false,
            "fisheye_params": [
                "RMS_error": fit.rms,
                "camera_matrix": [[profile.fx, 0.0, profile.cx], [0.0, profile.fy, centreY], [0.0, 0.0, 1.0]],
                "distortion_coeffs": fit.coefficients,
            ] as [String: Any],
            "distortion_model": "opencv_fisheye",
            "identifier": "",
            "calibrator_version": "VibeLog",
            "date": String(profile.measured.prefix(10)),
            "compatible_settings": [Any](),
        ]
        return try? JSONSerialization.data(withJSONObject: document, options: [.prettyPrinted, .sortedKeys])
    }

    /// Writes each calibrated lens's profiles, open gate and 16:9, beside the lens profiles, and
    /// returns the files. They're named apart from the lens profiles, which skip them on reading.
    public static func write(_ profiles: [LensProfile]) -> [URL] {
        var files: [URL] = []
        for profile in profiles where profile.isCalibrated {
            for widescreen in [false, true] {
                guard let data = json(for: profile, widescreen: widescreen) else { continue }
                let url = LensProfile.folder.appendingPathComponent(fileName(profile, widescreen: widescreen))
                do {
                    try data.write(to: url, options: .atomic)
                    files.append(url)
                } catch {
                    Log.shared.error("Lenses: can't write \(url.lastPathComponent): \(error.localizedDescription)")
                }
            }
        }
        return files
    }
}
