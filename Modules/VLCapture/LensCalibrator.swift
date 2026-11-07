import AVFoundation
import ObjCGuard
import VLCore

/// Measures this phone's lenses once and saves a `LensProfile` for each. Apple's factory
/// calibration only comes from a virtual camera's depth photo, one lens each: Dual Wide gives the
/// 1x and Dual Camera the tele, as the probe of 2026-11-04 found. The ultra wide gives none, so its
/// focal length comes from its field of view. Whether the table describes the RAW frame exactly,
/// rather than the processed photo it came with, is unproven.
public enum LensCalibrator {
    /// Runs on a background queue, with the camera released first. `completion` gets the folder
    /// the profiles went to, on the main queue.
    public static func run(progress: @escaping (String) -> Void, completion: @escaping (URL) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let model = SystemStatus.deviceModel
            let measured = ISO8601DateFormatter().string(from: Date())
            var saved: [String] = []
            func keep(_ profile: LensProfile) {
                do {
                    try profile.save()
                    saved.append(profile.fileName)
                } catch {
                    Log.shared.error("Lenses: can't save \(profile.fileName): \(error.localizedDescription)")
                }
            }
            // Each lens's field of view first, from its own photo format.
            var fields: [String: (fov: Double, corrected: Double, width: Int, height: Int)] = [:]
            for (lens, type) in lenses {
                guard let device = AVCaptureDevice.default(type, for: .video, position: .back) else { continue }
                progress("Measuring \(label(lens))")
                if let field = fieldOfView(device) { fields[lens] = field }
            }
            for (virtual, lens) in [(AVCaptureDevice.DeviceType.builtInDualWideCamera, "back-wide"),
                                    (.builtInDualCamera, "back-tele")] {
                guard let device = AVCaptureDevice.default(virtual, for: .video, position: .back) else { continue }
                // One capture's centre moved about 12 px from another's, likely the stabilizer
                // shifting the lens, so several are averaged and their spread kept.
                var all: [Found] = []
                for capture in 1...captureCount {
                    progress("Reading Apple's calibration for \(label(lens)), \(capture) of \(captureCount)")
                    all += calibrations(device)
                }
                // A photo names the lens it came from; failing that, the one this camera gives.
                let groups = Dictionary(grouping: all) { found in
                    "\(lenses.first { $0.type == found.source }?.lens ?? lens) \(found.width)x\(found.height)"
                }
                for (_, group) in groups.sorted(by: { $0.key < $1.key }) {
                    guard let first = group.first else { continue }
                    let from = lenses.first { $0.type == first.source }?.lens ?? lens
                    let field = fields[from]
                    let average = Found.average(group)
                    let centreSpread = group.map { hypot($0.cx - average.cx, $0.cy - average.cy) }.max() ?? 0
                    let focalSpread = group.map { abs($0.fx - average.fx) / max(average.fx, 1) }.max() ?? 0
                    keep(LensProfile(
                        model: model, lens: from, width: average.width, height: average.height,
                        fx: average.fx, fy: average.fy, cx: average.cx, cy: average.cy,
                        distortionCenterX: average.centerX, distortionCenterY: average.centerY,
                        distortionTable: average.table, pixelSize: average.pixelSize,
                        fieldOfView: field?.fov ?? 0, correctedFieldOfView: field?.corrected,
                        source: "Apple's calibration, from \(virtual.rawValue) with depth", measured: measured,
                        captures: group.count, centreSpread: centreSpread, focalSpread: focalSpread,
                        focusPosition: average.focus))
                    Log.shared.info(String(
                        format: "Lenses: %@ from %ld captures, fx %.2f within %.2f%%, centre (%.1f, %.1f) within %.1f px",
                        from, group.count, average.fx, focalSpread * 100, average.cx, average.cy, centreSpread))
                }
            }
            // Lenses Apple gave nothing for get a pinhole focal length from their field of view.
            let calibrated = Set(LensProfile.saved().filter(\.isCalibrated).map(\.lens))
            for (lens, field) in fields where !calibrated.contains(lens) {
                let fx = LensProfile.focalLength(fieldOfView: field.fov, width: field.width)
                keep(LensProfile(
                    model: model, lens: lens, width: field.width, height: field.height,
                    fx: fx, fy: fx, cx: Double(field.width) / 2, cy: Double(field.height) / 2,
                    fieldOfView: field.fov, correctedFieldOfView: field.corrected,
                    source: "field of view, with the centre assumed in the middle", measured: measured))
            }
            Log.shared.info("Lenses measured on \(model): \(saved.isEmpty ? "none" : saved.joined(separator: ", "))")
            DispatchQueue.main.async { completion(LensProfile.folder) }
        }
    }

    /// Captures averaged per virtual camera.
    static let captureCount = 5

    private static let lenses: [(lens: String, type: AVCaptureDevice.DeviceType)] = [
        ("back-wide", .builtInWideAngleCamera), ("back-ultrawide", .builtInUltraWideCamera),
        ("back-tele", .builtInTelephotoCamera),
    ]

    private static func label(_ lens: String) -> String {
        switch lens {
        case "back-wide": return "the 1x lens"
        case "back-ultrawide": return "the ultra wide"
        default: return "the tele"
        }
    }

    /// The photo format's horizontal field of view, plain and with distortion corrected, and its
    /// photo size, from a session set up as the app's own RAW capture is.
    private static func fieldOfView(_ device: AVCaptureDevice) -> (fov: Double, corrected: Double, width: Int, height: Int)? {
        let session = AVCaptureSession()
        guard let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) else { return nil }
        session.beginConfiguration()
        session.addInput(input)
        session.sessionPreset = .photo
        session.commitConfiguration()
        defer { session.removeInput(input) }
        let format = device.activeFormat
        let size = format.supportedMaxPhotoDimensions.first { $0.width == 4032 }
            ?? format.supportedMaxPhotoDimensions.first
        let width = Int(size?.width ?? CMVideoFormatDescriptionGetDimensions(format.formatDescription).width)
        let height = Int(size?.height ?? CMVideoFormatDescriptionGetDimensions(format.formatDescription).height)
        return (Double(format.videoFieldOfView), Double(format.geometricDistortionCorrectedVideoFieldOfView), width, height)
    }

    struct Found {
        var source: AVCaptureDevice.DeviceType?
        var width: Int
        var height: Int
        var fx, fy, cx, cy: Double
        var centerX, centerY: Double
        var table: [Double]
        var pixelSize: Double
        /// The lens position, 0 to 1, it was held at while measured, if it could be.
        var focus: Double?

        /// The mean of each value, the tables point by point where their lengths agree.
        static func average(_ group: [Found]) -> Found {
            let n = Double(group.count)
            func mean(_ value: (Found) -> Double) -> Double { group.map(value).reduce(0, +) / n }
            var tables = group.map(\.table)
            let length = tables.first?.count ?? 0
            tables = tables.filter { $0.count == length }
            let table = (0..<length).map { index in tables.map { $0[index] }.reduce(0, +) / Double(max(tables.count, 1)) }
            return Found(
                source: group[0].source, width: group[0].width, height: group[0].height,
                fx: mean(\.fx), fy: mean(\.fy), cx: mean(\.cx), cy: mean(\.cy),
                centerX: mean(\.centerX), centerY: mean(\.centerY), table: table, pixelSize: mean(\.pixelSize),
                focus: group.compactMap(\.focus).first)
        }
    }

    /// One depth photo from a virtual camera, with each constituent's photo, and the calibration
    /// any of them carries.
    private static func calibrations(_ device: AVCaptureDevice) -> [Found] {
        let session = AVCaptureSession()
        let photo = AVCapturePhotoOutput()
        guard let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) else { return [] }
        session.beginConfiguration()
        session.addInput(input)
        if session.canAddOutput(photo) { session.addOutput(photo) }
        session.sessionPreset = .photo
        session.commitConfiguration()
        // The output only offers these once it's in a session, and raises if set unsupported.
        if photo.isVirtualDeviceConstituentPhotoDeliverySupported {
            _ = VLTryCatch { photo.isVirtualDeviceConstituentPhotoDeliveryEnabled = true }
        }
        if photo.isDepthDataDeliverySupported {
            _ = VLTryCatch { photo.isDepthDataDeliveryEnabled = true }
        }
        session.startRunning()
        // The tele's focal length moved 2.4% between sessions, likely with focus, so each lens is
        // held at its farthest focus while measured, and the position kept with the profile.
        let held = holdFocus(device)
        defer {
            release(held)
            session.stopRunning()
            session.removeInput(input)
        }
        let settings = AVCapturePhotoSettings()
        if photo.isVirtualDeviceConstituentPhotoDeliveryEnabled {
            settings.virtualDeviceConstituentPhotoDeliveryEnabledDevices = device.constituentDevices
        }
        settings.isDepthDataDeliveryEnabled = photo.isDepthDataDeliveryEnabled
        settings.isCameraCalibrationDataDeliveryEnabled = photo.isCameraCalibrationDataDeliverySupported
        let catcher = Catcher()
        if let raised = VLTryCatch({ photo.capturePhoto(with: settings, delegate: catcher) }) {
            Log.shared.warn("Lenses: \(device.localizedName) refused the photo: \(raised.reason ?? "")")
            return []
        }
        if catcher.done.wait(timeout: .now() + 10) == .timedOut {
            Log.shared.warn("Lenses: \(device.localizedName) timed out")
        }
        return catcher.found.map { found in
            var found = found
            found.focus = held.first { $0.deviceType == found.source }.map { Double($0.lensPosition) }
            return found
        }
    }

    /// Locks each lens of a virtual camera at its farthest focus, waiting until it's there, and
    /// returns the ones it locked.
    private static func holdFocus(_ device: AVCaptureDevice) -> [AVCaptureDevice] {
        let lenses = device.constituentDevices.isEmpty ? [device] : device.constituentDevices
        var locked: [AVCaptureDevice] = []
        for lens in lenses where lens.isLockingFocusWithCustomLensPositionSupported {
            guard (try? lens.lockForConfiguration()) != nil else { continue }
            let arrived = DispatchSemaphore(value: 0)
            lens.setFocusModeLocked(lensPosition: 1.0) { _ in arrived.signal() }
            lens.unlockForConfiguration()
            _ = arrived.wait(timeout: .now() + 2)
            locked.append(lens)
        }
        return locked
    }

    private static func release(_ lenses: [AVCaptureDevice]) {
        for lens in lenses where lens.isFocusModeSupported(.continuousAutoFocus) {
            guard (try? lens.lockForConfiguration()) != nil else { continue }
            lens.focusMode = .continuousAutoFocus
            lens.unlockForConfiguration()
        }
    }

    private final class Catcher: NSObject, AVCapturePhotoCaptureDelegate {
        let done = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var collected: [Found] = []
        var found: [Found] {
            lock.lock()
            defer { lock.unlock() }
            return collected
        }

        func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
            guard let calibration = photo.cameraCalibrationData ?? photo.depthData?.cameraCalibrationData else { return }
            let k = calibration.intrinsicMatrix
            let size = calibration.intrinsicMatrixReferenceDimensions
            let table = calibration.lensDistortionLookupTable.map { data in
                data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }.map(Double.init)
            } ?? []
            let found = Found(
                source: photo.sourceDeviceType, width: Int(size.width), height: Int(size.height),
                fx: Double(k.columns.0.x), fy: Double(k.columns.1.y), cx: Double(k.columns.2.x), cy: Double(k.columns.2.y),
                centerX: Double(calibration.lensDistortionCenter.x), centerY: Double(calibration.lensDistortionCenter.y),
                table: table, pixelSize: Double(calibration.pixelSize))
            lock.lock()
            // One per lens and size: a constituent and the depth photo can carry the same.
            if !collected.contains(where: { $0.source == found.source && $0.width == found.width }) {
                collected.append(found)
            }
            lock.unlock()
        }

        func photoOutput(
            _ output: AVCapturePhotoOutput, didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings, error: Error?
        ) {
            if let error { Log.shared.warn("Lenses: capture ended with error \((error as NSError).code)") }
            done.signal()
        }
    }
}
