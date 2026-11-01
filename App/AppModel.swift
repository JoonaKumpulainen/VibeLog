import AVFoundation
import Combine
import Foundation
import UIKit
import VLCapture
import VLCore
import VLProcessing
import VLRecording

extension LogCurve {
    var shortLabel: String {
        switch self {
        case .appleLog: return "ALOG"
        case .sLog3: return "SLOG3"
        case .logC3: return "LOGC3"
        }
    }
}

extension EncoderPreset {
    var shortLabel: String {
        label.replacingOccurrences(of: "ProRes ", with: "")
            .replacingOccurrences(of: "10-bit ", with: "")
            .replacingOccurrences(of: ":", with: "")
            .uppercased()
    }
}

/// Why a take ended early or couldn't start. It stays until dismissed, because it's often read
/// after the fact.
struct TakeAlert: Equatable {
    let title: String
    let detail: String
}

/// The newest recording, for the button beside record.
struct LastTake {
    let url: URL
    let thumbnail: UIImage
}

final class AppModel: ObservableObject {
    let camera = CameraController()
    let pipeline = ProcessingPipeline()
    let hold = HoldTracker()

    @Published var lenses: [LensInfo] = []
    @Published var formats: [FormatInfo] = []
    @Published var options: CaptureOptions?
    @Published var stats = FrameStats.Snapshot()
    @Published var status = SystemLine()
    @Published var isStreaming = false
    @Published var isRecording = false
    @Published var isBusy: String?
    @Published var lastResult: String?
    /// A short message on the camera screen. Tapping it clears it.
    @Published var notice: String?
    @Published var takeAlert: TakeAlert?
    @Published private(set) var lastTake: LastTake?
    @Published private(set) var playingTake: URL?
    /// Only applies at 16:9. See `showsFullView`.
    @Published var fullView = false
    @Published var permissionDenied = false
    @Published var lastFrameLabel = "-"

    @Published var lensID = "" { didSet { if lensID != oldValue { lensChanged() } } }
    @Published var formatIndex = 0 { didSet { if formatIndex != oldValue { reconfigure() } } }
    @Published var method = CaptureMethod.photoReadiness { didSet { if method != oldValue { reconfigure() } } }
    @Published var rawFormat: OSType = 0 { didSet { if rawFormat != oldValue { reconfigure() } } }
    @Published var photoSize: PhotoSize? { didSet { if photoSize != oldValue { reconfigure() } } }
    @Published var videoFormat: OSType = 0 { didSet { if videoFormat != oldValue { reconfigure() } } }
    @Published var videoFPS = 30.0 { didSet { if videoFPS != oldValue { reconfigure() } } }
    @Published var bracketCount = 3 { didSet { if bracketCount != oldValue { reconfigure() } } }
    @Published var usePhotoPreset = true { didSet { if usePhotoPreset != oldValue { reconfigure() } } }

    @Published var processing = ProcessingSettings() { didSet { pipeline?.update(processing) } }
    @Published var pipelineStats = PipelineStats()

    @Published var recordEncoded = true
    /// The best preset proven at full size on an iPhone 14 Pro at 30 fps.
    @Published var encoderPreset = EncoderPreset.all.first { $0.id == "prores422hq" } ?? EncoderPreset.all[0]
    @Published var encoderSize = EncoderSize.all[0]
    @Published var widescreen = false {
        didSet {
            updateCrop()
            movePunch(to: punchCenter)
        }
    }
    @Published var lutNames: [String] = []
    /// Empty selects the built-in Rec.709 LUT.
    @Published var selectedLUT = "" { didSet { if selectedLUT != oldValue { loadSelectedLUT() } } }
    @Published var recordElapsed = 0
    /// The loudest the microphone reached in the last second of a take, from 0 to 1.
    @Published var audioPeak: Float = 0
    /// Megabytes per second written so far in this recording.
    @Published var dataRate = 0.0
    @Published var showTelemetry = true
    @Published var mainsHz = 50
    @Published var toolbar: [Tool] = []
    @Published private(set) var activeTools: Set<Tool> = [] {
        didSet {
            hold.tracksLevel = activeTools.contains(.level)
            applyMonitorView()
        }
    }

    /// Zero records until stopped.
    @Published var recordSeconds = 0.0
    @Published var writeFrames = true

    @Published var exposureLocked = false { didSet { applyExposure() } }
    @Published var iso: Float = 100 { didSet { if exposureLocked { throttled(.exposure) } } }
    /// Log2 of the shutter denominator: 6.64 is 1/100 s.
    @Published var shutterStops: Double = 6.64 { didSet { if exposureLocked { throttled(.exposure) } } }
    /// Offsets auto exposure at the sensor, in stops.
    @Published var exposureBias: Float = 0 { didSet { throttled(.bias) } }
    @Published var whiteBalanceLocked = false { didSet { applyWhiteBalance() } }
    @Published var temperature: Float = 5600 { didSet { if whiteBalanceLocked { throttled(.whiteBalance) } } }
    @Published var tint: Float = 0 { didSet { if whiteBalanceLocked { throttled(.whiteBalance) } } }
    @Published var focusLocked = false { didSet { applyFocus() } }
    @Published var lensPosition: Float = 0.8 { didSet { if focusLocked { throttled(.focus) } } }
    /// A tap's single autofocus holds the lens until focus is released.
    @Published var focusTapped = false
    /// Automatic controls stopped for the take, which resume when it ends.
    @Published private(set) var focusHeldForTake = false
    @Published private(set) var exposureHeldForTake = false
    @Published private(set) var whiteBalanceHeldForTake = false
    /// Freezes exposure and white balance as a take starts. Focus always holds.
    @Published var lockAtRoll = true

    var shutterLabel: String { "1/\(Int(pow(2, shutterStops).rounded()))" }

    /// The capture rate. Only 30 fps is proven so far.
    let frameRate = 30.0

    private enum Control { case exposure, bias, whiteBalance, focus }

    struct SystemLine {
        var thermal = "-"
        var footprintMB = 0
        var availableMB = 0
        var freeDiskGB = 0
        var battery = "?"
    }

    let router = FrameRouter()
    private var timer: Timer?
    private var applyingOptions = false
    private var thermalObserver: NSObjectProtocol?
    private var recordDeadline: Date?
    private var started = false
    /// The camera screen opens live, so the first configuration starts the stream.
    private var startStreamAfterConfigure = true
    private var resumeInForeground = false
    private var hasReference = false
    private var pendingControls: Set<Control> = []
    private var recordingFile: URL?
    private var savedConfig: AppConfig?
    private var ticksSinceReport = 0
    private var recordStart = Date()
    private var recordStarting = false
    private let statsQueue = DispatchQueue(label: "vibelog.stats", qos: .utility)

    func onAppear() {
        guard !started else { return }
        started = true
        router.pipeline = pipeline
        SystemStatus.enableBatteryMonitoring()
        refreshLUTs()
        loadConfig()
        loadLastTake()
        router.onRecordingElapsed = { [weak self] in
            DispatchQueue.main.async { self?.stopRecording() }
        }
        camera.onFrame = { [router] frame in router.handle(frame) }
        camera.onCaptureDrop = { [router] reason in router.handleDrop(reason) }
        camera.onCaptureFailure = { [router] _ in router.handleFailure() }
        camera.onReference = { [weak self] data, metadata in self?.handleReference(data, metadata) }
        camera.onOptionsChanged = { [weak self] options in self?.adopt(options) }

        thermalObserver = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: nil
        ) { [weak self] _ in
            Log.shared.warn("Thermal state changed to \(SystemStatus.thermalName)")
            self?.updateHeatMode()
        }
        updateHeatMode()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.tick()
        }

        AVCaptureDevice.requestAccess(for: .video) { granted in
            DispatchQueue.main.async { [self] in
                if granted {
                    loadLenses()
                    AVCaptureDevice.requestAccess(for: .audio) { _ in }
                } else {
                    permissionDenied = true
                    Log.shared.error("Camera permission denied")
                }
            }
        }
    }

    /// Focuses and meters at a sensor point. Stays off during a take until the control test
    /// shows what a single autofocus costs there.
    func focus(at point: CGPoint) {
        guard !isRecording else { return }
        if focusLocked { focusLocked = false }
        focusTapped = true
        camera.focus(at: point)
        guard !exposureLocked else { return }
        exposureBias = 0
        camera.meter(at: point)
    }

    /// Returns to continuous autofocus, which lost 8 frames when switched on during a take.
    func releaseFocus() {
        guard !isRecording else { return }
        focusTapped = false
        focusLocked = false
    }

    func enteredBackground() {
        if isRecording { stopRecording() }
        resumeInForeground = isStreaming
        if isStreaming { toggleStream() }
    }

    func enteredForeground() {
        guard resumeInForeground else { return }
        resumeInForeground = false
        if !isStreaming { toggleStream() }
    }

    var outputLabel: String { outputSize.label }

    var aspectLabel: String { widescreen ? "16:9" : "4:3" }

    var showsFullView: Bool { fullView && widescreen }

    /// The Metal monitor is on screen, rather than the ISP preview.
    var monitorIsProcessed: Bool {
        method.isPhoto && processing.enabled && processing.monitor != .isp
    }

    /// Punch-in shows this share of the picture's width and height.
    static let punchScale: CGFloat = 1.0 / 3

    /// The middle of the punch-in, as a share of the portrait picture.
    private(set) var punchCenter = CGPoint(x: 0.5, y: 0.5)

    /// Stops at the edges of what gets recorded.
    func movePunch(to center: CGPoint) {
        let edge = Self.punchScale / 2
        let reach = (widescreen ? 0.75 : 1) / 2 - edge
        punchCenter = CGPoint(
            x: min(max(center.x, 0.5 - reach), 0.5 + reach), y: min(max(center.y, edge), 1 - edge))
        applyMonitorView()
    }

    /// Turns a share of the view on screen into a share of the whole picture.
    func pictureShare(ofView share: CGPoint) -> CGPoint {
        guard isOn(.punchIn), monitorIsProcessed else { return share }
        let scale = Self.punchScale
        return CGPoint(
            x: punchCenter.x + (share.x - 0.5) * scale, y: punchCenter.y + (share.y - 0.5) * scale)
    }

    private func applyMonitorView() {
        let punched = isOn(.punchIn)
        let scale = punched ? Self.punchScale : 1
        let origin = punched
            ? SIMD2(Float(punchCenter.x - scale / 2), Float(punchCenter.y - scale / 2))
            : SIMD2<Float>(0, 0)
        pipeline?.setMonitorView(origin: origin, scale: Float(scale), peaking: isOn(.peaking))
    }

    /// The shutter as a share of the frame time.
    var shutterAngleLabel: String { "\(Int((360 * frameRate / pow(2, shutterStops)).rounded()))°" }

    var isoRange: ClosedRange<Double> {
        let range = options?.isoRange ?? 57...12768
        return Double(range.lowerBound)...Double(range.upperBound)
    }

    var isHot: Bool { status.thermal == "SERIOUS" || status.thermal == "CRITICAL" }

    var currentLensLabel: String {
        lenses.first { $0.id == lensID }?.zoomLabel ?? "1x"
    }

    /// Lens changes rebuild the capture session, which would end a recording.
    func nextLens() {
        guard !isRecording, lenses.count > 1 else { return }
        let ordered = lenses.sorted { $0.zoom < $1.zoom }
        let index = ordered.firstIndex { $0.id == lensID } ?? 0
        lensID = ordered[(index + 1) % ordered.count].id
    }

    func isOn(_ tool: Tool) -> Bool {
        switch tool {
        case .zebras: return processing.overlay == .zebras
        case .falseColor: return processing.overlay == .falseColor
        default: return activeTools.contains(tool)
        }
    }

    func toggle(_ tool: Tool) {
        switch tool {
        case .zebras: processing.overlay = processing.overlay == .zebras ? .none : .zebras
        case .falseColor: processing.overlay = processing.overlay == .falseColor ? .none : .falseColor
        default:
            if activeTools.contains(tool) { activeTools.remove(tool) } else { activeTools.insert(tool) }
        }
    }

    private var config: AppConfig {
        var config = AppConfig()
        config.codec = encoderPreset.id
        config.size = encoderSize.label
        config.widescreen = widescreen
        config.stopAfterSeconds = recordSeconds
        config.logCurve = processing.curve.label
        config.pipeline = processing.pipeline.rawValue
        config.debayer = processing.demosaic.label
        config.exposureOffset = processing.exposureStops
        config.reduceLoadWhenHot = processing.reduceLoadWhenHot
        config.monitor = processing.monitor.rawValue
        config.monitorLUT = selectedLUT
        config.lutExpectsRec709 = processing.lutExpectsRec709
        config.monitorOffWhileRecording = processing.pauseMonitorWhileRecording
        config.telemetry = showTelemetry
        config.lockAtRoll = lockAtRoll
        config.mainsHz = mainsHz
        config.toolbar = toolbar.map(\.rawValue)
        config.activeTools = activeTools.map(\.rawValue).sorted()
        return config
    }

    /// A file that can't be read is kept beside the new one, so hand edits aren't lost.
    private func loadConfig() {
        var loaded = AppConfig()
        if FileManager.default.fileExists(atPath: Storage.config.path) {
            do {
                loaded = try AppConfig.load(from: Storage.config)
            } catch {
                Log.shared.error("Cannot read VibeLog.config.json: \(error)")
                try? FileManager.default.moveItem(
                    at: Storage.config, to: Storage.config.appendingPathExtension("invalid"))
            }
        }
        encoderPreset = EncoderPreset.all.first { $0.id == loaded.codec } ?? encoderPreset
        encoderSize = EncoderSize.all.first { $0.label == loaded.size } ?? encoderSize
        widescreen = loaded.widescreen
        recordSeconds = loaded.stopAfterSeconds
        processing.curve = LogCurve.allCases.first { $0.label == loaded.logCurve } ?? processing.curve
        processing.pipeline = PipelineMode(rawValue: loaded.pipeline) ?? processing.pipeline
        processing.demosaic = DemosaicMethod.allCases.first { $0.label == loaded.debayer } ?? processing.demosaic
        processing.exposureStops = loaded.exposureOffset
        processing.reduceLoadWhenHot = loaded.reduceLoadWhenHot
        processing.monitor = MonitorMode(rawValue: loaded.monitor) ?? processing.monitor
        if lutNames.contains(loaded.monitorLUT) { selectedLUT = loaded.monitorLUT }
        processing.lutExpectsRec709 = loaded.lutExpectsRec709
        processing.pauseMonitorWhileRecording = loaded.monitorOffWhileRecording
        showTelemetry = loaded.telemetry
        lockAtRoll = loaded.lockAtRoll
        mainsHz = loaded.mainsHz
        toolbar = loaded.toolbar.compactMap(Tool.init(rawValue:))
        activeTools = Set(loaded.activeTools.compactMap(Tool.init(rawValue:)))
        savedConfig = config
    }

    /// Writes only after a change, and never during a take.
    private func saveConfigIfChanged() {
        let current = config
        guard !isRecording, current != savedConfig else { return }
        savedConfig = current
        statsQueue.async {
            do {
                try current.save(to: Storage.config)
            } catch {
                Log.shared.error("Cannot save VibeLog.config.json: \(error)")
            }
        }
    }

    /// The real chain, from sensor to file.
    var signalPath: String {
        guard recordEncoded else { return "RAW 14 › DUMP" }
        return "RAW 14 › \(curveLabel) › \(encoderPreset.label.uppercased())"
    }

    var curveLabel: String { processing.curve.shortLabel }

    var codecLabel: String { recordEncoded ? encoderPreset.shortLabel : "RAW" }

    /// What the monitor shows. A LUT replaces Rec.709, so it takes that label.
    var monitorLabel: String {
        switch processing.monitor {
        case .log: return "LOG"
        case .isp: return "ISP"
        case .rec709:
            guard !selectedLUT.isEmpty else { return "709" }
            return String((selectedLUT as NSString).deletingPathExtension.prefix(6)).uppercased()
        }
    }

    var monitorName: String {
        processing.monitor == .rec709 && !selectedLUT.isEmpty ? selectedLUT : processing.monitor.label
    }

    /// The offset auto exposure is following, to a tenth of a stop. Nil at zero or when locked.
    var exposureOffsetLabel: String? {
        let tenths = (exposureBias * 10).rounded()
        guard tenths != 0, !exposureLocked else { return nil }
        return String(format: "%+.1f", Double(tenths) / 10)
    }

    private var usableGB: Int { max(status.freeDiskGB - 10, 0) }

    /// Uses rates measured on the phone at full size. Other codecs have none yet.
    private var minutesLeft: Int? {
        let measured = ["prores422hq": 167.0, "prores4444": 240.0][encoderPreset.id]
        guard let measured else { return nil }
        let share = Double(outputSize.width * outputSize.height) / (4032 * 3024)
        return Int(Double(usableGB) * 1000 / (measured * share) / 60)
    }

    var timeLeftLabel: String {
        guard let minutes = minutesLeft else { return "\(usableGB) GB" }
        return minutes >= 60 ? "\(minutes / 60)H \(minutes % 60)M" : "\(minutes)M"
    }

    /// Only the digits in use, as in 0:07, 12:47 or 1:12:47.
    var timecodeLabel: String {
        let minutes = recordElapsed / 60 % 60
        let seconds = recordElapsed % 60
        guard recordElapsed >= 3600 else { return String(format: "%d:%02d", minutes, seconds) }
        return String(format: "%d:%02d:%02d", recordElapsed / 3600, minutes, seconds)
    }

    var heatLabel: String {
        switch status.thermal {
        case "nominal": return "OK"
        case "fair": return "FAIR"
        case "SERIOUS": return "HOT"
        case "CRITICAL": return "CRIT"
        default: return status.thermal
        }
    }

    var isStorageLow: Bool { minutesLeft.map { $0 < 5 } ?? (usableGB < 3) }

    /// Near-empty batteries stalled the encoder.
    var isBatteryLow: Bool { (Int(status.battery.prefix(while: \.isNumber)) ?? 100) < 15 }

    /// Frames lost to the camera, the writer or the GPU since the take started.
    var takeDrops: Int { stats.captureDrops + stats.writerDrops + pipelineStats.dropped }

    private var takeWarning: String? {
        if isHot { return "Phone is hot, so the take may stop early" }
        if isStorageLow { return "\(timeLeftLabel) of storage left" }
        if isBatteryLow { return "Battery at \(batteryLabel), so the take may stall" }
        return nil
    }

    /// A short message over the controls, gone after a few seconds.
    func showNotice(_ text: String, seconds: Double = 3) {
        notice = text
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            if self?.notice == text { self?.notice = nil }
        }
    }

    var batteryLabel: String { String(status.battery.prefix { $0 != " " }) }

    func toggleStream() {
        if isStreaming {
            if isRecording { stopRecording() }
            camera.stop()
            isStreaming = false
        } else {
            router.stats.reset()
            pipeline?.resetStats()
            hasReference = false
            if method.isPhoto { camera.requestReference() }
            camera.start()
            isStreaming = true
            // The driver may only exist once the session runs, which loses the first request.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [self] in
                if isStreaming, method.isPhoto, !hasReference { camera.requestReference() }
            }
        }
    }

    func runEncoderTest() {
        guard !isRecording, isBusy == nil else { return }
        isBusy = "Releasing camera"
        isStreaming = false
        camera.teardown { [self] in
            EncoderProbe.run(progress: { text in
                DispatchQueue.main.async { self.isBusy = text }
            }, completion: { [self] url in
                isBusy = nil
                lastResult = "Encoder test saved: probes/\(url.lastPathComponent)"
                startStreamAfterConfigure = true
                reconfigure()
            })
        }
    }

    func importLUT(from url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let text = try String(contentsOf: url, encoding: .utf8)
            let lut = try CubeLUT(text: text)
            let target = Storage.luts.appendingPathComponent(url.lastPathComponent)
            try text.write(to: target, atomically: true, encoding: .utf8)
            Log.shared.info("Imported LUT \(url.lastPathComponent), size \(lut.size)")
            refreshLUTs()
            selectedLUT = url.lastPathComponent
        } catch {
            Log.shared.error("LUT import failed for \(url.lastPathComponent): \(error)")
        }
    }

    private func refreshLUTs() {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: Storage.luts.path)) ?? []
        lutNames = files.filter { $0.lowercased().hasSuffix(".cube") }.sorted()
    }

    private func loadSelectedLUT() {
        let name = selectedLUT
        guard !name.isEmpty else {
            pipeline?.setCustomLUT(nil)
            return
        }
        DispatchQueue.global(qos: .userInitiated).async { [pipeline] in
            do {
                let url = Storage.luts.appendingPathComponent(name)
                let lut = try CubeLUT(text: String(contentsOf: url, encoding: .utf8))
                pipeline?.setCustomLUT(lut)
            } catch {
                Log.shared.error("Cannot load LUT \(name): \(error)")
            }
        }
    }

    /// Dial drags change values far faster than the camera needs them.
    private func throttled(_ control: Control) {
        guard pendingControls.insert(control).inserted else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [self] in
            pendingControls.remove(control)
            switch control {
            case .exposure: applyExposure()
            case .bias: applyBias()
            case .whiteBalance: applyWhiteBalance()
            case .focus: applyFocus()
            }
        }
    }

    /// Unlocked controls follow the camera, so a lock or dial starts from what it is doing.
    private func adopt(_ live: LiveCameraValues) {
        if !exposureLocked {
            iso = live.iso
            if live.seconds > 0 {
                shutterStops = min(max(log2(1 / live.seconds), log2(frameRate)), 13)
            }
        }
        if !whiteBalanceLocked {
            temperature = live.temperature ?? temperature
            tint = live.tint ?? tint
        }
        if !focusLocked { lensPosition = live.lensPosition }
    }

    private func updateHeatMode() {
        let state = ProcessInfo.processInfo.thermalState
        let hot = state == .serious || state == .critical
        pipeline?.setHot(hot)
        DispatchQueue.main.async { [self] in
            guard hot != loadReduced else { return }
            loadReduced = hot
            if processing.reduceLoadWhenHot {
                showNotice(hot ? "Hot: reduced load" : "Cool: full quality", seconds: 4)
            }
        }
    }

    private var outputSize: EncoderSize { widescreen ? encoderSize.widescreen : encoderSize }

    private func updateCrop() {
        // The sensor is 4:3, so 16:9 keeps three quarters of its height.
        processing.cropFraction = widescreen ? 0.75 : 1
    }

    func toggleRecord() {
        isRecording ? stopRecording() : startRecording()
    }

    /// The controls come back, so the reason can't be missed.
    private func takeStopped(_ reason: String) {
        fullView = false
        takeAlert = TakeAlert(
            title: "Recording stopped", detail: "\(reason) Stopped at \(timecodeLabel).")
    }

    /// Playing ProRes while the camera runs would add heat to the next take.
    func openLastTake() {
        guard let take = lastTake, !isRecording, isBusy == nil else { return }
        guard FileManager.default.fileExists(atPath: take.url.path) else {
            lastTake = nil
            loadLastTake()
            return
        }
        resumeAfterPlayback = isStreaming
        if isStreaming { toggleStream() }
        playingTake = take.url
    }

    func closeLastTake() {
        playingTake = nil
        guard resumeAfterPlayback else { return }
        resumeAfterPlayback = false
        if !isStreaming { toggleStream() }
    }

    /// Names sort by time.
    private func loadLastTake() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let files = (try? FileManager.default.contentsOfDirectory(
                at: Storage.videos, includingPropertiesForKeys: nil)) ?? []
            let newest = files.filter { $0.pathExtension == "mov" }
                .max { $0.lastPathComponent < $1.lastPathComponent }
            guard let newest else { return }
            DispatchQueue.main.async { self?.makeThumbnail(for: newest) }
        }
    }

    private func makeThumbnail(for url: URL) {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 156, height: 156)
        thumbnailGenerator = generator
        generator.generateCGImageAsynchronously(for: .zero) { [weak self] image, _, error in
            guard let image else {
                Log.shared.warn("No thumbnail for \(url.lastPathComponent): \(String(describing: error))")
                return
            }
            let take = LastTake(url: url, thumbnail: UIImage(cgImage: image))
            DispatchQueue.main.async { self?.lastTake = take }
        }
    }

    func runProbe() {
        guard !isRecording, isBusy == nil else { return }
        isBusy = "Releasing camera"
        isStreaming = false
        camera.teardown { [self] in
            CaptureProbe.run(progress: { text in
                DispatchQueue.main.async { self.isBusy = text }
            }, completion: { [self] url in
                isBusy = nil
                lastResult = "Probe saved: probes/\(url.lastPathComponent)"
                startStreamAfterConfigure = true
                reconfigure()
            })
        }
    }

    // MARK: Private

    func saveStill() {
        guard let pipeline else { return }
        guard isStreaming else {
            Log.shared.warn("Start streaming before saving a still")
            return
        }
        pipeline.requestStill { [weak self] still in
            guard let still else {
                Log.shared.error("Still readback failed")
                return
            }
            DispatchQueue.global(qos: .utility).async {
                do {
                    let (folder, spot) = try StillExporter.export(still)
                    let message = "Still saved: stills/\(folder.lastPathComponent)"
                    Log.shared.info("\(message), center log \(spot.log) linear \(spot.linear)")
                    DispatchQueue.main.async { self?.lastResult = message }
                } catch {
                    Log.shared.error("Still export failed: \(error)")
                }
            }
        }
    }

    private func loadLenses() {
        lenses = CameraController.lenses()
        guard let lens = lenses.first else {
            Log.shared.error("No rear camera found")
            return
        }
        lensID = lens.id
    }

    private func lensChanged() {
        formats = CameraController.formats(lensID: lensID)
        guard let format = CameraController.defaultFormat(in: formats) else { return }
        applyingOptions = true
        formatIndex = format.id
        applyingOptions = false
        reconfigure()
    }

    private func reconfigure() {
        guard !applyingOptions, !lensID.isEmpty else { return }
        let wasStreaming = isStreaming || startStreamAfterConfigure
        startStreamAfterConfigure = false
        if isRecording { stopRecording() }
        isStreaming = false
        let config = CaptureConfig(
            lensID: lensID, formatIndex: formatIndex, method: method,
            rawPixelFormat: rawFormat == 0 ? nil : rawFormat, photoSize: photoSize,
            videoPixelFormat: videoFormat == 0 ? nil : videoFormat, videoFPS: videoFPS,
            bracketCount: bracketCount, usePhotoPreset: usePhotoPreset)
        camera.configure(config) { [self] options in
            guard let options else { return }
            adopt(options)
            focusTapped = false
            applyExposure()
            if exposureBias != 0 { applyBias() }
            applyWhiteBalance()
            applyFocus()
            if wasStreaming { toggleStream() }
        }
    }

    private func adopt(_ options: CaptureOptions) {
        applyingOptions = true
        self.options = options
        rawFormat = options.config.rawPixelFormat ?? 0
        photoSize = options.config.photoSize
        videoFormat = options.config.videoPixelFormat ?? 0
        bracketCount = options.config.bracketCount
        iso = min(max(iso, options.isoRange.lowerBound), options.isoRange.upperBound)
        applyingOptions = false
    }

    func applyExposure() {
        guard !applyingOptions else { return }
        camera.setExposure(exposureLocked ? .locked : .auto, seconds: 1 / pow(2, shutterStops), iso: iso)
    }

    func applyBias() {
        guard !applyingOptions else { return }
        camera.setExposureBias(exposureBias)
    }

    func applyWhiteBalance() {
        guard !applyingOptions else { return }
        camera.setWhiteBalance(whiteBalanceLocked ? .locked : .auto, temperature: temperature, tint: tint)
    }

    func applyFocus() {
        guard !applyingOptions else { return }
        camera.setFocus(focusLocked ? .locked : .auto, lensPosition: lensPosition)
    }

    /// Refocusing during a take can cost frames, and white balance is baked into the file. Values
    /// the owner set are already still.
    private func holdForTake() {
        if !focusLocked, !focusTapped {
            focusHeldForTake = true
            camera.holdFocus()
        }
        guard lockAtRoll else { return }
        if !exposureLocked {
            exposureHeldForTake = true
            camera.holdExposure()
        }
        if !whiteBalanceLocked {
            whiteBalanceHeldForTake = true
            camera.holdWhiteBalance()
        }
    }

    private func resumeAfterTake() {
        if focusHeldForTake {
            focusHeldForTake = false
            applyFocus()
        }
        if exposureHeldForTake {
            exposureHeldForTake = false
            applyExposure()
        }
        if whiteBalanceHeldForTake {
            whiteBalanceHeldForTake = false
            applyWhiteBalance()
        }
    }

    private func startRecording() {
        guard !isRecording, !recordStarting else { return }
        notice = nil
        takeAlert = nil
        if let takeWarning { showNotice(takeWarning, seconds: 4) }
        // A frame processed before the reference arrives has no calibration.
        let warmUp = !isStreaming || !hasReference
        if !isStreaming { toggleStream() }
        if recordEncoded {
            // The first frames after a stream starts are unreliable, so give it a moment.
            recordStarting = true
            DispatchQueue.main.asyncAfter(deadline: .now() + (warmUp ? 1 : 0)) { [self] in
                recordStarting = false
                if isStreaming { startEncoding() }
            }
            return
        }
        let name = "clip_\(Storage.timestamp())"
        let budget = min(1_000_000_000, SystemStatus.availableMemory * 2 / 5)
        let lens = lenses.first { $0.id == lensID }?.name ?? lensID
        let context = ClipContext(
            method: method.rawValue, lens: lens, format: options?.formatDescription ?? "",
            requestedSeconds: rawDumpSeconds)
        do {
            let recorder = try RawRecorder(config: .init(
                directory: Storage.clips.appendingPathComponent(name, isDirectory: true),
                writeFrames: writeFrames, memoryBudget: budget, context: context))
            if method.isPhoto {
                recorder.beginReference()
                pendingReferences.append(recorder)
                camera.requestReference()
            }
            holdForTake()
            router.stats.reset()
            pipeline?.resetStats()
            router.beginRecording(recorder, seconds: rawDumpSeconds)
            recordDeadline = Date().addingTimeInterval(rawDumpSeconds + 5)
            recordStart = Date()
            recordElapsed = 0
            isRecording = true
            Log.shared.info("Recording \(name) for \(rawDumpSeconds)s, write=\(writeFrames), budget \(budget / 1_000_000) MB")
        } catch {
            Log.shared.error("Cannot start recording: \(error.localizedDescription)")
        }
    }

    /// RAW dumps need an end time, so until-stopped means an hour.
    private var rawDumpSeconds: Double { recordSeconds > 0 ? recordSeconds : 3600 }

    private func startEncoding() {
        guard let pipeline, processing.enabled, method.isPhoto else {
            Log.shared.error("Encoding needs a photo method and the GPU pipeline")
            takeAlert = TakeAlert(
                title: "Can't record", detail: "Recording needs a photo method and the GPU pipeline.")
            return
        }
        let name = "video_\(Storage.timestamp())"
        let url = Storage.videos.appendingPathComponent(name + ".mov")
        let metadata = [
            "curve": processing.curve.label, "gamut": "Rec.2020",
            "matrix": "Rec.2020 non-constant luminance, video range",
            "exposureStops": String(processing.exposureStops),
            "aspect": widescreen ? "16:9 center crop" : "4:3 open gate",
            "pipeline": processing.pipeline.label,
            "orientation": hold.hold.label,
            "reducedLoadAtStart": isHot && processing.reduceLoadWhenHot ? "yes, bilinear debayer" : "no",
            "note": "The file's transfer tag is nominal; decode with the curve named here.",
        ]
        do {
            let encoder = try VideoEncoder(config: .init(
                url: url, preset: encoderPreset, size: outputSize, audio: true, metadata: metadata,
                rotationDegrees: hold.hold.clipRotation))
            audio.onSample = { [weak encoder] sample in encoder?.appendAudio(sample) }
            audioPeak = 0
            encoder.onFailure = { [weak self] message in
                Log.shared.error("Recording stopped: \(message)")
                DispatchQueue.main.async { self?.takeStopped("The encoder failed.") }
                self?.stopRecording()
            }
            audio.start { [weak self] ready in
                guard !ready else { return }
                DispatchQueue.main.async {
                    self?.showNotice("No mic: recording silent", seconds: 4)
                }
            }
            activeEncoder = encoder
            holdForTake()
            router.stats.reset()
            pipeline.resetStats()
            pipeline.setSink(encoder)
            recordStart = Date()
            recordElapsed = 0
            recordingFile = url
            isRecording = true
            let seconds = recordSeconds
            Log.shared.info("Encoding \(name): \(encoderPreset.label) \(outputSize.label), \(processing.curve.label), \(processing.pipeline.label) pipeline, \(seconds > 0 ? "\(seconds)s" : "until stopped"), battery \(SystemStatus.batteryText), thermal \(SystemStatus.thermalName), free \(SystemStatus.freeDisk / 1_000_000_000) GB")
            guard seconds > 0 else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self, weak encoder] in
                guard let self, let encoder, self.activeEncoder === encoder else { return }
                self.stopRecording()
            }
        } catch {
            Log.shared.error("Cannot start \(encoderPreset.label) \(outputSize.label): \(error)")
            takeAlert = TakeAlert(
                title: "Can't record", detail: "\(encoderPreset.label) \(outputSize.label) wouldn't start.")
        }
    }

    private func stopEncoding(_ encoder: VideoEncoder) {
        activeEncoder = nil
        recordingFile = nil
        isRecording = false
        pipeline?.setSink(nil)
        audio.stop()
        resumeAfterTake()
        let capture = router.stats.snapshot()
        let gpu = pipeline?.currentStats() ?? PipelineStats()
        encoder.finish { [self] result in
            let summary = String(
                format: "%@ %dx%d: %.2f fps written, %d frames, %d dropped (%d no buffer, %d not ready), %.1f MB/s, audio %d, capture %.2f fps fail %d, gpu %.1f recent %.1f max ms drop %d",
                result.preset, result.width, result.height, result.fps, result.framesWritten,
                result.framesDropped, result.droppedNoBuffer, result.droppedNotReady,
                result.megabytesPerSecond, result.audioSamplesWritten,
                capture.sustainedFPS, capture.captureFailures, gpu.gpuRecentMs, gpu.gpuMaxMs, gpu.dropped)
            if let failure = result.failure {
                Log.shared.error("VIDEO FAILED \(result.file): \(failure)")
            }
            Log.shared.info("VIDEO RESULT \(result.file): \(summary)")
            lastResult = summary
            guard result.framesWritten > 0 else { return }
            makeThumbnail(for: Storage.videos.appendingPathComponent(result.file))
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let sidecar = Storage.videos.appendingPathComponent(result.file + ".json")
            try? encoder.encode(result).write(to: sidecar)
        }
    }

    private func stopRecording() {
        if let encoder = activeEncoder {
            stopEncoding(encoder)
            return
        }
        recordDeadline = nil
        guard isRecording, let recorder = router.endRecording() else { return }
        isRecording = false
        resumeAfterTake()
        // A photo reference that never arrives must not block the clip from closing.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [self] in
            if let index = pendingReferences.firstIndex(where: { $0 === recorder }) {
                pendingReferences.remove(at: index)
                recorder.finishReference(dng: nil, metadata: [:])
            }
        }
        recorder.finish { [self] result in
            lastResult = result.summary
        }
    }

    private var loadReduced = false
    private var resumeAfterPlayback = false
    private var thumbnailGenerator: AVAssetImageGenerator?
    private var pendingReferences: [RawRecorder] = []
    private let audio = AudioCapture()
    private var activeEncoder: VideoEncoder?

    /// Runs off the main thread with a DNG from the capture driver.
    private func handleReference(_ data: Data?, _ metadata: [String: Any]) {
        let levels = RawLevels(photoMetadata: metadata)
        pipeline?.setCalibration(data.flatMap { try? DNGMetadata(dng: $0) }, levels: levels)
        if let levels {
            Log.shared.info("RAW buffer levels: black \(levels.black) white \(levels.white) clip \(levels.clipValue)")
        } else {
            Log.shared.warn("Photo metadata has no RAW levels")
        }
        if let data, let parsed = try? DNGMetadata(dng: data) {
            Log.shared.info("DNG: cfa=\(parsed.cfaPattern ?? "?") black=\(parsed.blackLevel ?? []) "
                + "white=\(parsed.whiteLevel ?? []) neutral=\(parsed.asShotNeutral ?? []) "
                + "model=\(parsed.model ?? "?")")
        } else {
            Log.shared.warn("Reference DNG missing or unreadable (\(data?.count ?? 0) bytes)")
        }
        DispatchQueue.main.async { [self] in
            hasReference = true
            guard !pendingReferences.isEmpty else { return }
            let recorder = pendingReferences.removeFirst()
            DispatchQueue.global(qos: .utility).async {
                recorder.finishReference(dng: data, metadata: metadata)
            }
        }
    }

    /// Measures off the main thread, which capture readiness callbacks depend on.
    private func tick() {
        saveConfigIfChanged()
        let battery = SystemStatus.batteryText
        let file = recordingFile
        let seconds = Date().timeIntervalSince(recordStart)
        camera.liveValues { [weak self] live in
            DispatchQueue.main.async { self?.adopt(live) }
        }
        statsQueue.async { [self] in
            let snapshot = router.stats.snapshot()
            let gpu = pipeline?.currentStats() ?? PipelineStats()
            let line = SystemLine(
                thermal: SystemStatus.thermalName,
                footprintMB: SystemStatus.footprint / 1_000_000,
                availableMB: SystemStatus.availableMemory / 1_000_000,
                freeDiskGB: Int(SystemStatus.freeDisk / 1_000_000_000), battery: battery)
            let attributes = file.flatMap { try? FileManager.default.attributesOfItem(atPath: $0.path) }
            let bytes = (attributes?[.size] as? NSNumber)?.doubleValue ?? 0
            DispatchQueue.main.async { [self] in
                dataRate = seconds > 0 ? bytes / 1_000_000 / seconds : 0
                show(snapshot, gpu, line)
            }
        }
    }

    private func show(_ snapshot: FrameStats.Snapshot, _ gpu: PipelineStats, _ line: SystemLine) {
        stats = snapshot
        pipelineStats = gpu
        if isRecording {
            recordElapsed = Int(Date().timeIntervalSince(recordStart))
            audioPeak = audio.takePeak()
            if line.thermal == "CRITICAL" {
                Log.shared.warn("Stopping at \(recordElapsed)s: thermal state is critical")
                takeStopped("The phone is too hot.")
                stopRecording()
            } else if line.freeDiskGB < 10 {
                // Encoder drops began at about 8 GB free in a 10-minute test.
                Log.shared.warn("Stopping at \(recordElapsed)s: less than 10 GB free")
                takeStopped("Less than 10 GB free.")
                stopRecording()
            }
        }
        status = line
        if isRecording {
            ticksSinceReport += 1
            if ticksSinceReport >= 5 {
                ticksSinceReport = 0
                let capture = router.latestCapture
                let line = String(
                    format: "Recording: %.2f fps now, n=%d, fail %d, writer drops %d, 1/%.0f s ISO %.0f, gpu %d done %d dropped %.1f recent %.1f max ms, mem %d MB, avail %d MB, thermal %@, free %d GB, battery %@",
                    stats.rollingFPS, stats.frames, stats.captureFailures, stats.writerDrops,
                    capture.exposureSeconds > 0 ? 1 / capture.exposureSeconds : 0, capture.iso,
                    gpu.processed, gpu.dropped, gpu.gpuRecentMs, gpu.gpuMaxMs,
                    status.footprintMB, status.availableMB,
                    status.thermal, status.freeDiskGB, status.battery)
                if let activeEncoder {
                    activeEncoder.counts { written, dropped in
                        Log.shared.info("\(line), encoder \(written) written \(dropped) dropped")
                    }
                } else {
                    Log.shared.info(line)
                }
            }
        }
        if let deadline = recordDeadline, Date() > deadline {
            Log.shared.warn("Recording stopped by deadline, frames stopped arriving")
            stopRecording()
        }
    }
}
