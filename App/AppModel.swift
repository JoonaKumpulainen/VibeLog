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
        // Each brand's own spelling, in capitals. Apple has no short name of its own.
        case .appleLog: return "ALOG"
        case .appleLog2: return "ALOG2"
        case .sLog3: return "S-LOG3"
        case .sLog2: return "S-LOG2"
        case .logC3: return "LOGC3"
        case .logC4: return "LOGC4"
        case .canonLog3: return "C-LOG3"
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
    let audioBar = AudioBar()

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
    @Published var fixedFrameTime = true { didSet { if fixedFrameTime != oldValue { reconfigure() } } }
    /// Stops the stream after this long with no touch. Zero never does.
    @Published var idlePauseMinutes = 2.0
    @Published var distortionCorrection = false { didSet { if distortionCorrection != oldValue { reconfigure() } } }
    /// ProRes 4444 keeps 12 bits instead of 10, at about the same data rate but more memory.
    @Published var twelveBitProRes = false
    /// What a take records with: the chosen preset, at 12 bits when that's on and it's 4444.
    var takePreset: EncoderPreset { twelveBitProRes ? encoderPreset.twelveBit : encoderPreset }
    @Published var frameGuide = FrameGuide.scope
    @Published var fileTag = FileTag.rec2020 { didSet { processing.rec709Matrix = fileTag == .rec709 } }
    /// Records the viewfinder's look, the Rec.709 view and any LUT, instead of log, tagged Rec.709.
    @Published var bakeLook = false {
        didSet {
            processing.bakeLook = bakeLook
            guard !adopting, bakeLook != oldValue else { return }
            // A baked take is a finished picture, which HEVC 4:2:0 keeps at about a sixth of
            // ProRes 422 HQ. Turning it off goes back, unless the codec was changed since.
            let hevc = EncoderPreset.all.first { $0.id == "hevc420" } ?? encoderPreset
            if bakeLook {
                codecBeforeBake = encoderPreset
                encoderPreset = hevc
            } else if let before = codecBeforeBake {
                if encoderPreset == hevc { encoderPreset = before }
                codecBeforeBake = nil
            }
        }
    }
    private var codecBeforeBake: EncoderPreset?
    /// A baked look is display Rec.709, so the file says so whatever the tag setting is.
    var takeFileTag: FileTag { bakeLook ? .rec709 : fileTag }
    /// What the sidecar says the file holds.
    var bakedLookLabel: String {
        guard bakeLook else { return "log, as recorded" }
        guard !selectedLUT.isEmpty else { return "Rec.709 view, baked in" }
        return "\(selectedLUT), baked in" + (processing.lutExpectsRec709 ? " after the Rec.709 view" : " on log")
    }

    @Published var processing = ProcessingSettings() {
        didSet {
            pipeline?.update(processing)
            if !adopting, processing.curve != oldValue.curve || processing.gamut != oldValue.gamut {
                followPairLUT(from: Self.lutKey(oldValue.curve, oldValue.gamut))
            }
        }
    }
    /// Viewfinder LUTs linked to a curve in a gamut, kept in presets. Choosing the pair chooses
    /// its LUT, and choosing a LUT linked to one pair chooses that pair.
    @Published var curveLUTs: [String: String] = [:]
    /// Settings being read back, which mustn't set off the links between pairs and LUTs.
    private var adopting = false
    @Published var pipelineStats = PipelineStats()

    @Published var recordEncoded = true
    /// Measures what Apple's preview costs while hidden. It resets at launch, like the other tests.
    @Published var disconnectAppPreview = false
    /// Saves when each photo was requested and arrived, beside each encoded take.
    @Published var logCaptureTiming = false
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
    /// Empty selects the built-in Rec.709 view.
    @Published var selectedLUT = "" {
        didSet {
            guard selectedLUT != oldValue else { return }
            loadSelectedLUT()
            if !adopting { followLUTPair() }
        }
    }
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

    @Published var exposureLocked = false {
        didSet {
            if !exposureLocked { isoAuto = false }
            applyExposure()
        }
    }
    @Published var iso: Float = 100 { didSet { if exposureLocked, !isoAuto { throttled(.exposure) } } }
    /// With a set shutter, ISO follows the meter: shutter priority. It needs `exposureLocked`.
    @Published var isoAuto = false { didSet { if isoAuto != oldValue { applyExposure() } } }
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
    /// Freezes exposure and white balance as a take starts. Off, auto keeps running during the
    /// take. Focus always holds.
    @Published var lockAtRoll = true
    /// Saves a Gyroflow file beside each take.
    @Published var saveGyroLog = true
    /// 24-bit PCM instead of AAC.
    @Published var pcmAudio = false
    /// Stereo from the built-in microphones, from the next take.
    @Published var stereoAudio = true { didSet { audio.stereo = stereoAudio } }
    @Published var presets: [FormatPreset] = []
    /// Where the test link connects, kept between launches. The link itself never is.
    @Published var testServer = ""
    @Published var testToken = ""
    @Published var testLinkOn = false { didSet { if testLinkOn != oldValue { updateTestLink() } } }
    @Published var testLinkState = "Off"
    @Published var testSendsResults = true
    @Published var testSendsGyro = true
    /// What the link reports as open: camera, settings or diagnostics.
    private(set) var openScreen = "camera"
    let testLink = TestLink()
    /// The preset the app opens with. Empty keeps the last choices used.
    @Published var defaultPreset = ""

    /// A shutter of half the frame time, the usual look for motion.
    var isHalfAngleShutter: Bool {
        exposureLocked && abs(pow(2, shutterStops) / (frameRate * 2) - 1) < 0.01
    }

    func setHalfAngleShutter() {
        shutterStops = log2(frameRate * 2)
        if !exposureLocked { exposureLocked = true }
    }

    var shutterLabel: String { "1/\(Int(pow(2, shutterStops).rounded()))" }

    /// The capture rate. A slower shutter than one frame can't last past a change. Sliding the
    /// format column passes through other rates, so only the one it settles on rebuilds the session.
    @Published var frameRate = 30.0 {
        didSet {
            guard frameRate != oldValue, !applyingOptions else { return }
            // A 180 degree shutter stays one at the new rate.
            let wasHalfAngle = exposureLocked && abs(pow(2, shutterStops) / (oldValue * 2) - 1) < 0.01
            shutterStops = wasHalfAngle ? log2(frameRate * 2) : max(shutterStops, log2(frameRate))
            pendingRateChange?.cancel()
            let change = DispatchWorkItem { [weak self] in
                self?.pendingRateChange = nil
                self?.reconfigure()
            }
            pendingRateChange = change
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: change)
        }
    }

    var frameRateLabel: String { FrameRates.label(frameRate) }

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
    private var streamStart = Date.distantPast
    /// Long enough after a session rebuild for the first frames to come steadily.
    private static let settleSeconds = 1.5
    /// One take's length, instead of the owner's **Stop after**.
    private var takeSeconds: Double?
    private var resumeAfterSettings = false
    private var hotEnded: Date?
    private var takeHeatEvents: [String] = []
    /// The camera's shutter, ISO and white balance during the take, for the sidecar.
    private var takeReadings = TakeReadings()
    private var lastTouch = Date()
    /// The camera stopped itself for want of a touch. A tap anywhere on the screen resumes it.
    @Published private(set) var idlePaused = false
    /// A dial or panel is open, which counts as using the camera.
    var isCameraControlOpen = false
    /// Names the log the test link sends, so one session keeps one file.
    let sessionStamp = Storage.timestamp()
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
        audio.onLevels = { [audioBar] left, right in audioBar.show(left: left, right: right) }
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

    var aspectLabel: String { widescreen ? "16:9" : "OPEN GATE" }

    var showsFullView: Bool { fullView && widescreen }

    /// Apple's preview leaves the session while the Metal monitor replaces it, if Diagnostics asks.
    var appPreviewConnected: Bool { !disconnectAppPreview || !monitorIsProcessed }

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

    /// The chosen guide's width to height, while the tool is on.
    var frameGuideRatio: Double? { isOn(.frameGuide) ? frameGuide.ratio : nil }

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
        config.frameRate = frameRate
        config.stopAfterSeconds = recordSeconds
        config.logCurve = processing.curve.label
        config.gamut = processing.gamut.label
        config.pairsGamut = processing.pairsGamut
        config.curveGamuts = processing.pairing.gamutLabels
        config.gamutCurves = processing.pairing.curveLabels
        config.curveLUTs = curveLUTs
        config.pipeline = processing.pipeline.rawValue
        config.debayer = processing.demosaic.label
        config.exposureOffset = processing.exposureStops
        config.reduceLoadWhenHot = processing.reduceLoadWhenHot
        config.bilinearWhenHot = processing.bilinearWhenHot
        config.idlePauseMinutes = idlePauseMinutes
        config.monitor = processing.monitor.rawValue
        config.monitorLUT = selectedLUT
        config.lutExpectsRec709 = processing.lutExpectsRec709
        config.monitorOffWhileRecording = processing.pauseMonitorWhileRecording
        config.telemetry = showTelemetry
        config.lockAtRoll = lockAtRoll
        config.saveGyroLog = saveGyroLog
        config.pcmAudio = pcmAudio
        config.stereoAudio = stereoAudio
        config.mainsHz = mainsHz
        config.toolbar = toolbar.map(\.rawValue)
        config.activeTools = activeTools.map(\.rawValue).sorted()
        config.presets = presets
        config.defaultPreset = defaultPreset
        config.peakingSensitivity = processing.peakingSensitivity.rawValue
        config.fixedFrameTime = fixedFrameTime
        config.distortionCorrection = distortionCorrection
        config.twelveBitProRes = twelveBitProRes
        config.efficientWhenHot = processing.efficientWhenHot
        config.frameGuide = frameGuide.rawValue
        config.desqueeze = processing.desqueeze
        config.fileTag = fileTag.rawValue
        config.bakeLook = bakeLook
        config.testServer = testServer
        config.testToken = testToken
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
        if let startup = loaded.startupPreset { loaded.use(startup) }
        // The first configuration comes after this and uses it.
        applyingOptions = true
        adoptSettings(loaded)
        applyingOptions = false
        presets = loaded.presets
        defaultPreset = loaded.startupPreset?.name ?? ""
        testServer = loaded.testServer
        testToken = loaded.testToken
        savedConfig = config
    }

    /// Every setting, at launch and from a preset. A choice this version no longer has stays as it is.
    private func adoptSettings(_ saved: AppConfig) {
        encoderPreset = EncoderPreset.all.first { $0.id == saved.codec } ?? encoderPreset
        encoderSize = EncoderSize.all.first { $0.label == saved.size } ?? encoderSize
        widescreen = saved.widescreen
        if FrameRates.all.contains(saved.frameRate) { frameRate = saved.frameRate }
        recordSeconds = saved.stopAfterSeconds
        adopting = true
        defer { adopting = false }
        processing.pairsGamut = saved.pairsGamut
        processing.pairing = GamutPairing(gamutLabels: saved.curveGamuts, curveLabels: saved.gamutCurves)
        let curve = LogCurve.allCases.first { $0.label == saved.logCurve } ?? processing.curve
        // Older files only said whether the curve's own gamut was on.
        let gamut = Gamut.allCases.first { $0.label == saved.gamut }
            ?? (saved.nativeGamut || saved.pairsGamut || curve == .appleLog2 ? curve.nativeGamut : .rec2020)
        processing.restore(curve: curve, gamut: gamut)
        curveLUTs = saved.curveLUTs
        processing.pipeline = PipelineMode(rawValue: saved.pipeline) ?? processing.pipeline
        processing.demosaic = DemosaicMethod.allCases.first { $0.label == saved.debayer } ?? processing.demosaic
        processing.exposureStops = saved.exposureOffset
        processing.reduceLoadWhenHot = saved.reduceLoadWhenHot
        processing.bilinearWhenHot = saved.bilinearWhenHot
        idlePauseMinutes = saved.idlePauseMinutes
        processing.monitor = MonitorMode(rawValue: saved.monitor) ?? processing.monitor
        if saved.monitorLUT.isEmpty || lutNames.contains(saved.monitorLUT) { selectedLUT = saved.monitorLUT }
        processing.lutExpectsRec709 = saved.lutExpectsRec709
        processing.pauseMonitorWhileRecording = saved.monitorOffWhileRecording
        showTelemetry = saved.telemetry
        lockAtRoll = saved.lockAtRoll
        saveGyroLog = saved.saveGyroLog
        pcmAudio = saved.pcmAudio
        stereoAudio = saved.stereoAudio
        mainsHz = saved.mainsHz
        toolbar = saved.toolbar.compactMap(Tool.init(rawValue:))
        activeTools = Set(saved.activeTools.compactMap(Tool.init(rawValue:)))
        processing.overlay = ExposureOverlay(rawValue: UInt32(saved.overlay)) ?? .none
        processing.peakingSensitivity = PeakingSensitivity(rawValue: saved.peakingSensitivity) ?? .low
        fixedFrameTime = saved.fixedFrameTime
        distortionCorrection = saved.distortionCorrection
        twelveBitProRes = saved.twelveBitProRes
        processing.efficientWhenHot = saved.efficientWhenHot
        frameGuide = FrameGuide(rawValue: saved.frameGuide) ?? frameGuide
        processing.desqueeze = saved.desqueeze
        fileTag = FileTag(rawValue: saved.fileTag) ?? fileTag
        bakeLook = saved.bakeLook
    }

    /// What a preset keeps. Zebras and false color only ever reach the file through here.
    private var presetSnapshot: AppConfig {
        var values = config.presetValues
        values.overlay = Int(processing.overlay.rawValue)
        return values
    }

    /// A name already in use takes the new choices.
    func savePreset(named name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        let saved = FormatPreset(name: name, settings: presetSnapshot)
        if let index = presets.firstIndex(where: { $0.name == name }) {
            presets[index] = saved
        } else {
            presets.append(saved)
        }
    }

    /// Keeps the name, place and default, with the current choices.
    func update(_ saved: FormatPreset) {
        savePreset(named: saved.name)
    }

    func deletePresets(at offsets: IndexSet) {
        if offsets.contains(where: { presets[$0].name == defaultPreset }) { defaultPreset = "" }
        for index in offsets.reversed() { presets.remove(at: index) }
    }

    func delete(_ saved: FormatPreset) {
        if let index = presets.firstIndex(of: saved) { deletePresets(at: [index]) }
    }

    func isCurrent(_ saved: FormatPreset) -> Bool { saved.settings == presetSnapshot }

    func apply(_ saved: FormatPreset) {
        guard !isRecording else { return }
        adoptSettings(saved.settings)
    }

    /// Returns every setting and manual control to the app's own, keeping presets and the test link.
    func resetSettings() {
        guard !isRecording else { return }
        adoptSettings(AppConfig())
        exposureBias = 0
        exposureLocked = false
        whiteBalanceLocked = false
        releaseFocus()
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
        return "RAW 14 › \(bakeLook ? "\(processing.curve.shortLabel) › BAKED \(lutShortLabel)" : curveLabel) › \(encoderPreset.label.uppercased())"
    }

    /// A baked take records the look, not the curve, so the status line says which.
    var curveLabel: String { bakeLook ? "BAKED \(lutShortLabel)" : processing.curve.shortLabel }

    /// The LUT's name cut to fit a status line, or 709 for the Rec.709 view.
    var lutShortLabel: String { Self.shortLUTName(selectedLUT) }

    static func shortLUTName(_ name: String) -> String {
        guard !name.isEmpty else { return "709" }
        return String((name as NSString).deletingPathExtension.prefix(6)).uppercased()
    }

    /// What the look panel started from, so Cancel can put it back.
    private var lookBeforePanel: (lut: String, bake: Bool, monitor: MonitorMode)?

    /// The look panel changes the viewfinder as it slides, and Cancel puts this back.
    func openLookPanel() {
        lookBeforePanel = (selectedLUT, bakeLook, processing.monitor)
    }

    /// Shows a LUT on the viewfinder without choosing its curve, which only Select does.
    func previewLUT(_ name: String) {
        guard name != selectedLUT else { return }
        adopting = true
        selectedLUT = name
        adopting = false
    }

    func closeLookPanel(keep: Bool) {
        defer { lookBeforePanel = nil }
        guard keep else {
            if let before = lookBeforePanel {
                previewLUT(before.lut)
                if !isRecording { bakeLook = before.bake }
                processing.monitor = before.monitor
            }
            return
        }
        followLUTPair()
    }

    var codecLabel: String { recordEncoded ? encoderPreset.shortLabel : "RAW" }

    /// What the monitor shows. A LUT replaces Rec.709, so it takes that label.
    var monitorLabel: String {
        switch processing.monitor {
        case .log: return "LOG"
        case .isp: return "ISP"
        case .rec709: return lutShortLabel
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
        let share = Double(outputSize.width * outputSize.height) / (4032 * 3024) * frameRate / 30
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
        // Nominal doesn't mean cool: a take started soon after heating up reached serious in 90 seconds.
        if let hotEnded, Date().timeIntervalSince(hotEnded) < 1200 {
            return "Phone was hot recently, so it may heat quickly"
        }
        if isStorageLow { return "\(timeLeftLabel) of storage left" }
        if isBatteryLow { return "Battery at \(batteryLabel), so the take may stall" }
        return nil
    }

    /// A short message over the controls, gone after a few seconds.
    func showNotice(_ text: String, seconds: Double = 3) {
        notice = text
        UIAccessibility.post(notification: .announcement, argument: text)
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
            streamStart = Date()
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

    static func lutKey(_ curve: LogCurve, _ gamut: Gamut) -> String {
        AppConfig.lutKey(curve: curve.label, gamut: gamut.label)
    }

    /// The LUT linked to a pair, or nil for none.
    func linkedLUT(_ curve: LogCurve, _ gamut: Gamut) -> String? { curveLUTs[Self.lutKey(curve, gamut)] }

    func linkLUT(_ name: String, to curve: LogCurve, in gamut: Gamut) {
        curveLUTs[Self.lutKey(curve, gamut)] = name.isEmpty ? nil : name
        if curve == processing.curve, gamut == processing.gamut, !name.isEmpty { selectedLUT = name }
    }

    /// A LUT linked to the last pair leaves with it, so it can't misread the new one.
    private func followPairLUT(from oldKey: String) {
        if let linked = linkedLUT(processing.curve, processing.gamut), lutNames.contains(linked) {
            selectedLUT = linked
        } else if let old = curveLUTs[oldKey], old == selectedLUT {
            selectedLUT = ""
        }
    }

    private func followLUTPair() {
        guard !isRecording, !selectedLUT.isEmpty,
            linkedLUT(processing.curve, processing.gamut) != selectedLUT
        else { return }
        let pairs = LogCurve.allCases.flatMap { curve in
            GamutPairing.gamuts(for: curve).map { (curve, $0) }
        }.filter { linkedLUT($0.0, $0.1) == selectedLUT }
        guard pairs.count == 1, let pair = pairs.first else { return }
        processing.restore(curve: pair.0, gamut: pair.1)
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
        if isRecording {
            takeReadings.add(seconds: live.seconds, iso: live.iso, temperature: live.temperature, tint: live.tint)
        }
        if !exposureLocked {
            iso = live.iso
            if live.seconds > 0 {
                shutterStops = min(max(log2(1 / live.seconds), log2(frameRate)), 13)
            }
        } else if isoAuto {
            iso = live.iso
        }
        if !whiteBalanceLocked {
            temperature = live.temperature ?? temperature
            tint = live.tint ?? tint
        }
        if !focusLocked { lensPosition = live.lensPosition }
    }

    /// How each reading behaved, from what the sidecar says exposure and white balance did.
    static func readingModes(exposure: String?, whiteBalance: String?)
        -> (shutter: TakeReadings.Mode, iso: TakeReadings.Mode, whiteBalance: TakeReadings.Mode) {
        let shutter: TakeReadings.Mode
        let iso: TakeReadings.Mode
        switch exposure {
        case "frozen at start": (shutter, iso) = (.frozen, .frozen)
        case "manual": (shutter, iso) = (.manual, .manual)
        case "shutter priority": (shutter, iso) = (.manual, .auto)
        default: (shutter, iso) = (.auto, .auto)
        }
        let balance: TakeReadings.Mode = whiteBalance == "manual" ? .manual
            : whiteBalance == "frozen at start" ? .frozen : .auto
        return (shutter, iso, balance)
    }

    private func updateHeatMode() {
        let state = ProcessInfo.processInfo.thermalState
        let hot = state == .serious || state == .critical
        pipeline?.setHot(hot)
        DispatchQueue.main.async { [self] in
            guard hot != loadReduced else { return }
            loadReduced = hot
            if !hot { hotEnded = Date() }
            noteHeatChange(hot: hot)
            if processing.reduceLoadWhenHot || processing.bilinearWhenHot || processing.efficientWhenHot {
                showNotice(hot ? "Hot: reduced load" : "Cool: full quality", seconds: 4)
            }
        }
    }

    private var outputSize: EncoderSize { widescreen ? encoderSize.widescreen : encoderSize }

    /// What the phone changes to while hot, as a take's details name it.
    private var hotChanges: String {
        var changes: [String] = []
        if processing.efficientWhenHot, processing.pipeline == .maximum { changes.append("Efficient") }
        if processing.bilinearWhenHot, processing.demosaic != .bilinear { changes.append("Bilinear") }
        return changes.isEmpty ? "no change" : changes.joined(separator: ", ")
    }

    /// The picture can change at these moments, so the take's details keep them.
    private func noteHeatChange(hot: Bool) {
        guard isRecording else { return }
        let seconds = Int(Date().timeIntervalSince(recordStart))
        let event = String(format: "%d:%02d %@", seconds / 60, seconds % 60, hot ? "hot: \(hotChanges)" : "cool")
        takeHeatEvents.append(event)
        Log.shared.info("Heat change at \(event)")
    }

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
        UIAccessibility.post(notification: .announcement, argument: "Recording stopped. \(reason)")
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

    /// The sheet covers the picture, so the stream stops to save heat and battery. A take keeps
    /// running. Settings only change what the next stream starts with.
    func settingsOpened() {
        openScreen = "settings"
        guard isStreaming, !isRecording else { return }
        resumeAfterSettings = true
        toggleStream()
    }

    func settingsClosed() {
        openScreen = "camera"
        resumeStreamAfterSettings()
    }

    private func resumeStreamAfterSettings() {
        guard resumeAfterSettings else { return }
        resumeAfterSettings = false
        if !isStreaming { toggleStream() }
    }

    /// Diagnostics tools use the stream, and leave it running when they close Settings.
    func diagnosticsOpened() {
        openScreen = "diagnostics"
        resumeStreamAfterSettings()
    }

    func diagnosticsClosed() {
        // Its tools close Settings outright, which has already said so.
        if openScreen == "diagnostics" { openScreen = "settings" }
    }

    /// Any touch anywhere in the app, seen by the window before any view handles it.
    func noteTouch() {
        lastTouch = Date()
    }

    /// The tap that wakes a paused camera. It lands on a layer over the whole screen, so it
    /// presses nothing underneath.
    func cameraTouched() {
        lastTouch = Date()
        guard idlePaused else { return }
        idlePaused = false
        notice = nil
        if !isStreaming, playingTake == nil { toggleStream() }
    }

    /// Runs once a second. The test link's runs start and stop the stream themselves.
    private func pauseIfIdle() {
        // A take counts as use, so the wait starts again when it ends.
        if isRecording || recordStarting { lastTouch = Date() }
        guard idlePauseMinutes > 0, isStreaming, !isRecording, !recordStarting, isBusy == nil,
            openScreen == "camera", playingTake == nil, !isCameraControlOpen, !testLinkOn,
            Date().timeIntervalSince(lastTouch) >= idlePauseMinutes * 60
        else { return }
        Log.shared.info("Camera paused after \(idlePauseMinutes) minutes idle")
        idlePaused = true
        toggleStream()
        notice = "Camera paused to save heat. Tap anywhere to resume"
    }

    /// Records for a set time, leaving **Stop after** as it is.
    func record(seconds: Double) {
        guard !isRecording else { return }
        takeSeconds = seconds
        startRecording()
    }

    /// The tools on the picture, as a log and a sidecar record them.
    var toolsLabel: String {
        let names = Tool.allCases.filter(isOn).map(\.shortTitle)
        return names.isEmpty ? "none" : names.joined(separator: " ")
    }

    /// Removes each video and its sidecar, then finds the newest that's left.
    func delete(_ takes: [Take]) {
        for take in takes {
            do {
                try TakeLibrary.delete(take)
                Log.shared.info("Deleted \(take.url.lastPathComponent)")
            } catch {
                Log.shared.error("Cannot delete \(take.url.lastPathComponent): \(error)")
            }
        }
        guard takes.contains(where: { $0.url == lastTake?.url }) else { return }
        lastTake = nil
        loadLastTake()
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
        runReleasingCamera(CaptureProbe.run)
    }

    private func runReleasingCamera(
        _ probe: @escaping (@escaping (String) -> Void, @escaping (URL) -> Void) -> Void
    ) {
        guard !isRecording, isBusy == nil else { return }
        isBusy = "Releasing camera"
        isStreaming = false
        camera.teardown { [self] in
            probe({ text in
                DispatchQueue.main.async { self.isBusy = text }
            }, { [self] url in
                isBusy = nil
                lastResult = "Probe saved: probes/\(url.lastPathComponent)"
                startStreamAfterConfigure = true
                reconfigure()
            })
        }
    }

    // MARK: Private

    /// Reading a still back takes GPU time, so the link refuses this during a take.
    func sendPreview() {
        pipeline?.requestStill { [weak self] still in
            DispatchQueue.global(qos: .utility).async {
                guard let still, let data = StillExporter.preview(still) else {
                    Log.shared.error("Preview failed")
                    return
                }
                self?.testLink.send(data: data, name: "preview_\(Storage.timestamp()).jpg")
            }
        }
    }

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
            frameRate: frameRate, bracketCount: bracketCount, usePhotoPreset: usePhotoPreset,
            fixedFrameTime: fixedFrameTime, distortionCorrection: distortionCorrection)
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
        if options.frameRateUnavailable, options.config.frameRate != frameRate {
            showNotice("\(frameRateLabel) fps isn't available on this lens", seconds: 4)
            frameRate = options.config.frameRate
        }
        applyingOptions = false
    }

    func applyExposure() {
        guard !applyingOptions else { return }
        let seconds = 1 / pow(2, shutterStops)
        if exposureLocked, isoAuto {
            camera.setShutterPriority(seconds: seconds, iso: iso)
            return
        }
        camera.stopShutterPriority()
        camera.setExposure(exposureLocked ? .locked : .auto, seconds: seconds, iso: iso)
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
    /// the owner set are already still. Auto exposure and white balance are the owner's choice.
    private func holdForTake() {
        if !focusLocked, !focusTapped {
            focusHeldForTake = true
            camera.holdFocus()
        }
        guard lockAtRoll else { return }
        if !exposureLocked || isoAuto {
            exposureHeldForTake = true
            camera.stopShutterPriority()
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
        guard !isRecording, !recordStarting, pendingRateChange == nil else { return }
        takeReadings = TakeReadings()
        idlePaused = false
        lastTouch = Date()
        notice = nil
        takeAlert = nil
        if let takeWarning { showNotice(takeWarning, seconds: 4) }
        // A frame processed before the reference arrives has no calibration.
        let warmUp = !isStreaming || !hasReference
        if !isStreaming { toggleStream() }
        if recordEncoded {
            // The first frames after a stream starts are unreliable, so give it a moment. A take
            // started 1.2 seconds after a rebuild still lost 3 frames in its first second.
            let settling = max(0, Self.settleSeconds - Date().timeIntervalSince(streamStart))
            recordStarting = true
            DispatchQueue.main.asyncAfter(deadline: .now() + (warmUp ? max(1, settling) : settling)) { [self] in
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
            router.stats.setExpectedRate(frameRate)
            pipeline?.resetStats()
            router.beginRecording(recorder, seconds: rawDumpSeconds)
            recordDeadline = Date().addingTimeInterval(rawDumpSeconds + 5)
            recordStart = Date()
            recordElapsed = 0
            isRecording = true
            Log.shared.info("Recording \(name) for \(rawDumpSeconds)s, write=\(writeFrames), budget \(budget / 1_000_000) MB")
            takeSeconds = nil
        } catch {
            Log.shared.error("Cannot start recording: \(error.localizedDescription)")
        }
    }

    /// RAW dumps need an end time, so until-stopped means an hour.
    private var rawDumpSeconds: Double {
        let seconds = takeSeconds ?? recordSeconds
        return seconds > 0 ? seconds : 3600
    }

    private func startEncoding() {
        guard let pipeline, processing.enabled, method.isPhoto else {
            Log.shared.error("Encoding needs a photo method and the GPU pipeline")
            takeAlert = TakeAlert(
                title: "Can't record", detail: "Recording needs a photo method and the GPU pipeline.")
            return
        }
        let name = "video_\(Storage.timestamp())"
        let url = Storage.videos.appendingPathComponent(name + ".mov")
        let metadata: [String: String] = [
            "curve": processing.curve.label, "gamut": processing.gamut.label,
            "audio": (pcmAudio ? "24-bit PCM" : "AAC") + (stereoAudio ? " stereo" : " mono"),
            "matrix": "Rec.2020 non-constant luminance, video range",
            "exposureStops": String(processing.exposureStops),
            "frameRate": frameRateLabel,
            "exposureDuringTake": lockAtRoll && (!exposureLocked || isoAuto) ? "frozen at start"
                : isoAuto ? "shutter priority" : exposureLocked ? "manual" : "auto",
            "whiteBalanceDuringTake": whiteBalanceLocked ? "manual" : lockAtRoll ? "frozen at start" : "auto",
            "aspect": widescreen ? "16:9 center crop" : "4:3 open gate",
            "debayer": processing.demosaic.label,
            "pipeline": processing.pipeline.label,
            "orientation": hold.hold.label,
            "reducedLoadAtStart": isHot && processing.bilinearWhenHot ? "yes, bilinear debayer" : "no",
            "lens": currentLensLabel,
            "tools": toolsLabel,
            "frameTime": fixedFrameTime ? "fixed" : "variable at 30 fps",
            "distortionCorrection": distortionCorrection ? "on" : "off, so the lens's distortion stays in the picture",
            "bitDepth": String(takePreset.bitDepth),
            "appPreview": appPreviewConnected ? "connected" : "disconnected",
            "fileTag": takeFileTag.label,
            "look": bakedLookLabel,
            "desqueeze": processing.desqueeze == 1 ? "off" : String(processing.desqueeze),
            "hotPath": processing.efficientWhenHot ? "Efficient when hot" : "stays on the chosen pipeline",
            "hotDebayer": processing.bilinearWhenHot ? "Bilinear when hot" : "stays on the chosen debayer",
            "gyroLog": saveGyroLog ? "on" : "off",
            "thermalAtStart": SystemStatus.thermalName,
            "note": "The file's transfer tag is nominal; decode with the curve named here.",
        ]
        do {
            let encoder = try VideoEncoder(config: .init(
                url: url, preset: takePreset, size: outputSize, frameRate: frameRate, audio: true,
                pcmAudio: pcmAudio, audioChannels: stereoAudio ? 2 : 1, metadata: metadata,
                rotationDegrees: hold.hold.clipRotation, fileTag: takeFileTag))
            audio.onSample = { [weak encoder] sample in encoder?.appendAudio(sample) }
            audioPeak = 0
            audioBar.reset()
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
            if saveGyroLog {
                let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "-"
                motion.start(url: TakeLibrary.gyroLog(for: url), videoName: url.lastPathComponent, version: version)
                encoder.onFirstFrame = { [motion] seconds in motion.setFirstFrame(seconds: seconds) }
            }
            activeEncoder = encoder
            holdForTake()
            router.stats.reset()
            router.stats.setExpectedRate(frameRate)
            pipeline.resetStats()
            pipeline.setSink(encoder)
            testLink.holdFiles(true)
            if logCaptureTiming { camera.timing.begin() }
            recordStart = Date()
            recordElapsed = 0
            takeHeatEvents = isHot ? ["0:00 hot: \(hotChanges)"] : []
            recordingFile = url
            isRecording = true
            let seconds = takeSeconds ?? recordSeconds
            takeSeconds = nil
            Log.shared.info("Encoding \(name): lens \(currentLensLabel), \(takePreset.label) \(takePreset.bitDepth)-bit \(outputSize.label) at \(frameRateLabel) fps, frame time \(metadata["frameTime"] ?? "?"), audio \(metadata["audio"] ?? "?"), gyro \(metadata["gyroLog"] ?? "?"), tools \(toolsLabel), exposure \(metadata["exposureDuringTake"] ?? "?"), white balance \(metadata["whiteBalanceDuringTake"] ?? "?"), \(processing.curve.label), \(processing.pipeline.label) pipeline, \(seconds > 0 ? "\(seconds)s" : "until stopped"), battery \(SystemStatus.batteryText), thermal \(SystemStatus.thermalName), free \(SystemStatus.freeDisk / 1_000_000_000) GB")
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

    /// Writes on a background queue, so the end of a take isn't held up by a large log.
    private func saveCaptureTiming(for file: URL?) {
        let entries = camera.timing.finish()
        guard let file, !entries.isEmpty else { return }
        DispatchQueue.global(qos: .utility).async { [self] in
            Log.shared.info(CaptureTimingLog.summary(entries))
            let url = TakeLibrary.captureTiming(for: file)
            do {
                try CaptureTimingLog.csv(entries).write(to: url, atomically: true, encoding: .utf8)
                self.sendTimingFile(url)
            } catch {
                Log.shared.error("Capture timing save failed: \(error.localizedDescription)")
            }
        }
    }

    private func stopEncoding(_ encoder: VideoEncoder) {
        saveCaptureTiming(for: recordingFile)
        activeEncoder = nil
        recordingFile = nil
        isRecording = false
        pipeline?.setSink(nil)
        audio.stop()
        if saveGyroLog { motion.stop() }
        resumeAfterTake()
        let capture = router.stats.snapshot()
        let gpu = pipeline?.currentStats() ?? PipelineStats()
        encoder.finish { [self] finished in
            let encoderDrops = finished.framesDropped
            var result = finished
            // The library and the sidecar show one number for frames the file lost.
            result.framesDropped = encoderDrops + gpu.dropped
            result.droppedAtGPU = gpu.dropped
            result.missed = capture.estimatedMissed
            result.duplicates = capture.duplicates
            result.captureFPS = capture.sustainedFPS
            if !takeHeatEvents.isEmpty { result.metadata["heatChanges"] = takeHeatEvents.joined(separator: "; ") }
            let modes = Self.readingModes(
                exposure: result.metadata["exposureDuringTake"], whiteBalance: result.metadata["whiteBalanceDuringTake"])
            result.metadata["shutter"] = takeReadings.shutter(modes.shutter)
            result.metadata["iso"] = takeReadings.isoText(modes.iso)
            result.metadata["whiteBalance"] = takeReadings.whiteBalance(modes.whiteBalance)
            let summary = String(
                format: "%@ %dx%d: %.2f fps written, %d frames, %d lost (%d gpu, %d encoder: %d no buffer, %d not ready), %.1f MB/s, audio %d, capture %.2f fps fail %d missed %d duplicates %d gap %.0f ms, gpu %.1f recent %.1f max ms, steps copy %.1f queue %.1f append %.1f draw %.1f ms, viewfinder yields %d",
                result.preset, result.width, result.height, result.fps, result.framesWritten,
                result.framesDropped, gpu.dropped, encoderDrops, result.droppedNoBuffer, result.droppedNotReady,
                result.megabytesPerSecond, result.audioSamplesWritten,
                capture.sustainedFPS, capture.captureFailures, capture.estimatedMissed, capture.duplicates,
                capture.gapMaxMs, gpu.gpuRecentMs, gpu.gpuMaxMs, gpu.copyMs, gpu.queueMs, gpu.appendMs,
                gpu.drawMs, gpu.monitorYields)
            if let failure = result.failure {
                Log.shared.error("VIDEO FAILED \(result.file): \(failure)")
            }
            Log.shared.info("VIDEO RESULT \(result.file): \(summary)")
            lastResult = summary
            guard result.framesWritten > 0 else {
                testLink.holdFiles(false)
                return
            }
            makeThumbnail(for: Storage.videos.appendingPathComponent(result.file))
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let sidecar = Storage.videos.appendingPathComponent(result.file + ".json")
            try? encoder.encode(result).write(to: sidecar)
            sendTakeFiles(video: Storage.videos.appendingPathComponent(result.file))
            testLink.holdFiles(false)
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

    private var pendingRateChange: DispatchWorkItem?
    private var loadReduced = false
    private var resumeAfterPlayback = false
    private var thumbnailGenerator: AVAssetImageGenerator?
    private var pendingReferences: [RawRecorder] = []
    private let audio = AudioCapture()
    private let motion = MotionLogger()
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
        pauseIfIdle()
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
                    format: "Recording: %.2f fps now, n=%d, fail %d, writer drops %d, 1/%.0f s ISO %.0f, gains %@, gpu %d done %d dropped %.1f recent %.1f max ms, steps copy %.1f queue %.1f append %.1f draw %.1f ms, yields %d, mem %d MB, avail %d MB, thermal %@, free %d GB, battery %@",
                    stats.rollingFPS, stats.frames, stats.captureFailures, stats.writerDrops,
                    capture.exposureSeconds > 0 ? 1 / capture.exposureSeconds : 0, capture.iso,
                    capture.gains.map { String(format: "%.2f", $0) }.joined(separator: "/"),
                    gpu.processed, gpu.dropped, gpu.gpuRecentMs, gpu.gpuMaxMs,
                    gpu.copyMs, gpu.queueMs, gpu.appendMs, gpu.drawMs, gpu.monitorYields,
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
