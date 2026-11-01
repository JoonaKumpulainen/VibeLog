import Foundation

/// One motion reading on the phone's axes: x to the right of the portrait screen, y to its top and
/// z out of it.
public struct MotionSample: Sendable {
    /// Seconds on the same clock as frame timestamps.
    public var seconds: Double
    /// Right-handed, in radians per second.
    public var rotation: SIMD3<Double>
    /// In g, pointing up when the phone is still, as Gyroflow expects.
    public var acceleration: SIMD3<Double>

    public init(seconds: Double, rotation: SIMD3<Double>, acceleration: SIMD3<Double>) {
        self.seconds = seconds
        self.rotation = rotation
        self.acceleration = acceleration
    }
}

/// Text for a Gyroflow `.gcsv` file, version 1.3. Time zero is the take's first frame.
public enum GyroLog {
    /// The image's right is the phone's -y, its up is +x, and backward is +z. Worked out from the
    /// sensor's position in the phone and not yet checked in Gyroflow, whose IMU Orientation field
    /// overrides it.
    public static let orientation = "yXZ"

    // These match the scales in the header.
    private static let timeScale = 0.000001
    private static let rotationScale = 0.00001
    private static let accelerationScale = 0.0001

    public static func header(videoName: String, startedAt: Date, version: String) -> String {
        """
        GYROFLOW IMU LOG
        version,1.3
        id,vibelog
        orientation,\(orientation)
        fwversion,\(version)
        timestamp,\(Int(startedAt.timeIntervalSince1970))
        vendor,VibeLog
        videofilename,\(videoName)
        tscale,0.000001
        gscale,0.00001
        ascale,0.0001
        t,gx,gy,gz,ax,ay,az

        """
    }

    public static func line(_ sample: MotionSample, firstFrame: Double) -> String {
        func scaled(_ value: Double, _ scale: Double) -> Int { Int((value / scale).rounded()) }
        let values = [
            scaled(sample.seconds - firstFrame, timeScale),
            scaled(sample.rotation.x, rotationScale),
            scaled(sample.rotation.y, rotationScale),
            scaled(sample.rotation.z, rotationScale),
            scaled(sample.acceleration.x, accelerationScale),
            scaled(sample.acceleration.y, accelerationScale),
            scaled(sample.acceleration.z, accelerationScale),
        ]
        return values.map(String.init).joined(separator: ",") + "\n"
    }
}
