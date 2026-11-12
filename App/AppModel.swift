import AVFoundation
import Combine
import Foundation
import Metal
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
    /// The newest take's file name, which the test link reports so a round can fetch it.
    var lastTakeFile = ""
    /// A run of trial takes, in `TrialTakes.swift`, or nil.
    var trialState: TrialState?
    /// This phone's benchmark, in `Benchmark.swift`.
    @Published var benchmark = BenchmarkProgress.saved()
    @Published var benchmarkRunning = false
    /// The one-time offer to measure this phone, and the question about log sharing after it.
    @Published var benchmarkOffer = false
    @Published var benchmarkAsksSharing = false
    @Published var benchmarkSummaryShown = false
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
            syncBakeHDR()
            if bakeLook != oldValue { buildLook() }
            guard !adopting, bakeLook != oldValue else { return }
            // A baked take is a finished picture, which HEVC 4:2:0 keeps at about a sixth of
            // ProRes 422 HQ. Turning it off goes back, unless the codec was changed since.
            let baked = Self.bakeCodec(proRes: bakeToProRes) ?? encoderPreset
            if bakeLook {
                codecBeforeBake = encoderPreset
                encoderPreset = baked
            } else if let before = codecBeforeBake {
                if encoderPreset == baked { encoderPreset = before }
                codecBeforeBake = nil
            }
        }
    }
    /// Baked takes in ProRes 422 HQ, for finishing in an editor, instead of small HEVC files.
    @Published var bakeToProRes = false {
        didSet {
            guard !adopting, bakeLook, bakeToProRes != oldValue,
                encoderPreset == Self.bakeCodec(proRes: oldValue),
                let baked = Self.bakeCodec(proRes: bakeToProRes)
            else { return }
            encoderPreset = baked
        }
    }
    private var codecBeforeBake: EncoderPreset?
    private static func bakeCodec(proRes: Bool) -> EncoderPreset? {
        let id = proRes ? "prores422hq" : "hevc420"
        return EncoderPreset.all.first { $0.id == id }
    }
    /// A baked look is display Rec.709, so the file says so whatever the tag setting is.
    var takeFileTag: FileTag {
        guard bakeLook else { return fileTag }
        guard bakesHDR else { return .rec709 }
        return bakeTarget == .hlg ? .hlg : .pq
    }

    /// The viewfinder shows ACES 2.0's HDR picture through the screen's extended range while the
    /// look's dynamic range is HDR, baked or not. Off keeps it SDR.
    @Published var hdrViewfinder = true {
        didSet { if hdrViewfinder != oldValue { buildLook() } }
    }

    /// Builds the camera's look at 129 points rather than 65, for the viewfinder and baked takes.
    @Published var fineLookLUT = false {
        didSet { if fineLookLUT != oldValue { buildLook() } }
    }

    var showsHDRViewfinder: Bool {
        hdrViewfinder && bakeTarget.isHDR && selectedLUT == BuiltInLook.aces20.name && processing.monitor == .rec709
    }

    /// HDR for baked takes, which only ACES 2.0 has.
    @Published var bakeTarget = BakeTarget.sdr {
        didSet {
            guard bakeTarget != oldValue else { return }
            syncBakeHDR()
            buildLook()
        }
    }
    var bakesHDR: Bool { bakeLook && bakeTarget.isHDR && selectedLUT == BuiltInLook.aces20.name }

    /// An HDR bake keeps Rec.2020's matrix, where an SDR one uses Rec.709's.
    private func syncBakeHDR() {
        if processing.bakeHDR != bakesHDR { processing.bakeHDR = bakesHDR }
    }
    /// The pipeline a take runs on. Baked FX take the Efficient one, whatever is chosen.
    var takePipelineLabel: String {
        let bakesEffects = bakeLook && processing.bakeEffects && !lookEffects.isNeutral
        guard bakesEffects, processing.pipeline != .efficient else { return processing.pipeline.label }
        return "\(PipelineMode.efficient.label), for the baked FX"
    }

    /// The grade a baked take records, for an export to copy: what `bakedLookLabel` describes.
    var bakedRecipe: GradeRecipe? {
        guard bakeLook else { return nil }
        let effects = processing.bakeEffects ? lookEffects : LookEffects()
        if bakesHDR { return GradeRecipe(look: BuiltInLook.aces20.name, grade: lookGrade, effects: effects) }
        return GradeRecipe(
            look: selectedLUT, lutMadeForRec709: processing.lutExpectsRec709,
            grade: gradeApplies ? lookGrade : LookGrade(), effects: effects)
    }

    /// What the sidecar says the file holds.
    var bakedLookLabel: String {
        guard bakeLook else { return "log, as recorded" }
        if bakesHDR {
            let graded = lookGrade.isNeutral ? "" : ", graded (\(lookGrade.label))"
            return "ACES 2.0 HDR 1000 nits, \(bakeTarget == .hlg ? "HLG" : "PQ")\(graded), baked in"
        }
        let graded = gradeApplies && !lookGrade.isNeutral ? ", graded (\(lookGrade.label))" : ""
        guard !selectedLUT.isEmpty else { return "Rec.709 view\(graded), baked in" }
        if BuiltInLook.named(selectedLUT) != nil { return "\(selectedLUT) Rec.709\(graded), baked in" }
        return "\(selectedLUT)\(graded), baked in" + (processing.lutExpectsRec709 ? " after the Rec.709 view" : " on log")
    }

    /// The grade under the look, any look but LOG, kept in presets.
    @Published var lookGrade = LookGrade() {
        didSet { if lookGrade != oldValue { buildLook() } }
    }
    /// Styles the owner saved from ADJUST, after the built-in ones.
    @Published var savedStyles: [LookStyle] = []
    var styles: [LookStyle] { LookStyle.builtIn + savedStyles }
    /// Styles share the carousel with looks, so their choices carry a prefix no file name has.
    static let stylePrefix = "style:"

    func style(forChoice choice: String) -> LookStyle? {
        guard choice.hasPrefix(Self.stylePrefix) else { return nil }
        let name = String(choice.dropFirst(Self.stylePrefix.count))
        return styles.first { $0.name == name }
    }

    /// The styles under a look in the carousel, built-in first.
    func styles(for look: String) -> [LookStyle] { styles.filter { $0.belongs(to: look) } }

    /// The style under the current look whose grade is on now, so the panel opens on it.
    var currentStyle: LookStyle? { styles(for: selectedLUT).first { $0.grade == lookGrade } }
    var currentStyleChoice: String? { currentStyle.map { Self.stylePrefix + $0.name } }

    /// Shows a style on the viewfinder. A built-in style keeps whichever ACES look is on.
    func previewStyle(_ style: LookStyle) {
        if !style.belongs(to: selectedLUT) { previewLUT(isAvailableLook(style.look) ? style.look : "") }
        lookGrade = style.grade
    }

    /// Keeps the current look and grade as a style, numbered if the name is taken.
    @discardableResult
    func saveStyle(named wanted: String, look: String? = nil, grade: LookGrade? = nil) -> String {
        let base = wanted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Style" : wanted
        var name = base
        var number = 2
        while styles.contains(where: { $0.name == name }) {
            name = "\(base) \(number)"
            number += 1
        }
        savedStyles.append(LookStyle(name: name, look: look ?? selectedLUT, grade: grade ?? lookGrade))
        return name
    }

    func deleteStyle(named name: String) {
        savedStyles.removeAll { $0.name == name }
    }

    /// The FX tab's effects. The viewfinder and export apply them; takes don't yet, baked or not.
    @Published var lookEffects = LookEffects() {
        didSet { pipeline?.setEffects(lookEffects) }
    }

    /// The export screen's grade in progress, kept across exports and launches until an export
    /// with it succeeds or it's reset. Nil when there's nothing to keep.
    @Published var exportRecipe: GradeRecipe? = GradeRecipe.loadSaved() {
        didSet { if exportRecipe != oldValue { GradeRecipe.save(exportRecipe) } }
    }

    /// Shows effects on the viewfinder while a slider moves, without publishing anything.
    func previewEffects(_ effects: LookEffects) {
        guard !isRecording else { return }
        pipeline?.setEffects(effects)
    }

    /// Whether the viewfinder shows a look that takes the grade. LOG is for judging exposure.
    var gradeApplies: Bool { processing.monitor == .rec709 }

    @Published var processing = ProcessingSettings() {
        didSet {
            pipeline?.update(processing)
            if processing.monitor != oldValue.monitor {
                updateScope()
                // The HDR viewfinder only shows a look, so leaving LOG may need its LUT.
                if showsHDRViewfinder { buildLook() }
            }
            if processing.curve != oldValue.curve || processing.gamut != oldValue.gamut {
                if !adopting { followPairLUT(from: Self.lutKey(oldValue.curve, oldValue.gamut)) }
                buildLook()
            } else if processing.lutExpectsRec709 != oldValue.lutExpectsRec709, !lookGrade.isNeutral {
                // A graded imported LUT has the Rec.709 view built into it, or not.
                buildLook()
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
    /// Saves when each photo was requested and arrived, beside each encoded take.
    @Published var logCaptureTiming = false
    /// The best preset proven at full size on an iPhone 14 Pro at 30 fps. A phone without ProRes
    /// moves off it at launch, in `fitToPhone`.
    @Published var encoderPreset = EncoderPreset.all.first { $0.id == "prores422hq" } ?? EncoderPreset.all[0]
    @Published var encoderSize = EncoderSize.all[0]
    /// What this phone's encoders can do: the codec list at once, then trial encodes, measured
    /// once per phone and iOS version.
    @Published private(set) var encoderSupport = EncoderSupport.saved() ?? EncoderSupport.codecList()
    /// The GPU's cost per recording setup on this phone, and what takes showed about them.
    @Published private(set) var gpuSupport = GPUSupport.saved()
    /// How this phone's RAW stream is set up: the standard way until its own stream stalls.
    @Published private(set) var captureSupport = CaptureSupport.saved()
    /// The current step was reached after a stall and hasn't streamed long enough to keep.
    private var captureOnTrial = false
    /// The presets this phone can record with.
    var recordPresets: [EncoderPreset] { EncoderPreset.all.filter(encoderSupport.supports) }
    /// There was no settings file, so the phone's own defaults may be chosen.
    private var firstLaunch = false
    /// A15 and later, from the 13 Pro on, run Maximum quality. The 12's A14 starts on Efficient,
    /// since the 14 Pro's A16 already needs about 26 of a frame's 33 ms for it.
    static let gpuKeepsMaximum = MTLCreateSystemDefaultDevice()?.supportsFamily(.apple8) ?? false
    @Published var widescreen = false {
        didSet {
            updateCrop()
            movePunch(to: punchCenter)
        }
    }
    @Published var lutNames: [String] = [] {
        // A LUT imported again under the same name must be read again.
        didSet { lookQueue.async { [weak self] in self?.importedCubes = [:] } }
    }
    /// The built-in ACES looks, then every imported LUT.
    var lookNames: [String] { BuiltInLook.allCases.map(\.name) + lutNames }
    /// Built-in looks for each curve and gamut, made once a session.
    private var builtInLUTs: [String: CubeLUT] = [:]

    func isAvailableLook(_ name: String) -> Bool { BuiltInLook.named(name) != nil || lutNames.contains(name) }
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
    /// A server reached through a tunnel such as ngrok, by its https:// address. Off at every launch,
    /// like the link, kept out of presets, and never set from the server. Switching it disconnects.
    @Published var testOverInternet = false {
        didSet { if testOverInternet != oldValue, testLinkOn { testLinkOn = false } }
    }
    @Published var testLinkState = "Off"
    @Published var testSendsResults = true
    @Published var testSendsGyro = true
    /// What the link reports as open: camera, settings or diagnostics.
    private(set) var openScreen = "camera"
    let testLink = TestLink()
    /// Sends test logs to the owner's log service, once the tester turns it on in Diagnostics.
    let logUploader = LogUploader()
    /// Bakes the takes the test link asks for, one at a time. Only touched on the main thread.
    private(set) lazy var testExport: LookExportJob = MainActor.assumeIsolated { LookExportJob() }
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
    /// When the app last left the screen, so returning can log how long it was away.
    private var backgroundSince: Date?
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
    /// Logs when the main thread answers late, and on which screen.
    private let mainWatch = MainThreadWatch()
    /// Names the log the test link sends, so one session keeps one file.
    let sessionStamp = Storage.timestamp()
    private let statsQueue = DispatchQueue(label: "vibelog.stats", qos: .utility)

    func onAppear() {
        guard !started else { return }
        started = true
        router.pipeline = pipeline
        mainWatch.screen = { [unowned self] in
            if playingTake != nil { return "player" }
            if openScreen == "camera", isCameraControlOpen { return "camera with a panel open" }
            return openScreen
        }
        mainWatch.drawSummary = { [weak pipeline] in
            guard let stats = pipeline?.currentStats(), stats.mainDrawMaxMs > 0 else { return nil }
            return String(
                format: "viewfinder draw on the main thread %.1f ms recently, %.0f ms at most",
                stats.mainDrawMs, stats.mainDrawMaxMs)
        }
        mainWatch.start()
        SystemStatus.enableBatteryMonitoring()
        refreshLUTs()
        loadConfig()
        if firstLaunch, !Self.gpuKeepsMaximum {
            processing.pipeline = .efficient
            Log.shared.info("Starting on the Efficient path: this GPU is older than the A15")
        }
        fitToPhone(choosingDefaults: firstLaunch)
        refitOldDefault()
        // The first launch's choices are the app's own, which the benchmark may move later.
        if firstLaunch { recordFittedDefaults() }
        if !encoderSupport.measured { measureEncoders() }
        if captureSupport.step > 0 {
            Log.shared.info("Capture setup for \(captureSupport.device): \(captureSupport.setup.label)")
        }
        loadLastTake()
        checkBenchmarkAtLaunch()
        // The previous session's logs go once the camera has settled, if sharing is on.
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in self?.shareLogs("launch") }
        router.onRecordingElapsed = { [weak self] in
            DispatchQueue.main.async { self?.stopRecording() }
        }
        audio.onLevels = { [audioBar] left, right in audioBar.show(left: left, right: right) }
        camera.onFrame = { [router] frame in router.handle(frame) }
        camera.onCaptureDrop = { [router] reason in router.handleDrop(reason) }
        camera.onCaptureFailure = { [router] _ in router.handleFailure() }
        camera.onReference = { [weak self] data, metadata in self?.handleReference(data, metadata) }
        camera.onOptionsChanged = { [weak self] options in self?.adopt(options) }
        camera.onCaptureStalled = { [weak self] in self?.captureStalled() }

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
        backgroundSince = Date()
        Log.shared.info("Left the app" + (isRecording ? " during a take" : "") + (isStreaming ? ", camera streaming" : ""))
        if isRecording { stopRecording() }
        resumeInForeground = isStreaming
        if isStreaming { toggleStream() }
        // A take that just stopped finishes writing first, then the logs go, with the few
        // seconds iOS gives an app on its way out.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self else { return }
            var task = UIBackgroundTaskIdentifier.invalid
            task = UIApplication.shared.beginBackgroundTask(withName: "Log sharing") {
                UIApplication.shared.endBackgroundTask(task)
            }
            self.shareLogs("left the app") { UIApplication.shared.endBackgroundTask(task) }
        }
    }

    /// The names the owner typed, which log sharing takes out of every file.
    var privateNames: [String] {
        presets.map(\.name) + savedStyles.map(\.name) + lutNames + lutNames.map { ($0 as NSString).deletingPathExtension }
    }

    func shareLogs(_ reason: String, completion: (() -> Void)? = nil) {
        logUploader.sendIfDue(recording: isRecording, names: privateNames, reason: reason, completion: completion)
    }

    func enteredForeground() {
        // Time away isn't idle time on the camera. Without this, coming back after two minutes
        // restarted the stream and the idle pause stopped it again within a second.
        lastTouch = Date()
        if let since = backgroundSince {
            Log.shared.info(String(format: "Returned to the app after %.0f s away", Date().timeIntervalSince(since))
                + (resumeInForeground ? ", restarting the camera" : ""))
            backgroundSince = nil
        }
        guard resumeInForeground else { return }
        resumeInForeground = false
        if !isStreaming { toggleStream() }
    }

    var outputLabel: String { outputSize.label }

    var aspectLabel: String { widescreen ? "16:9" : "OPEN GATE" }

    var showsFullView: Bool { fullView && widescreen }

    /// Apple's preview is only on the session for the ISP preview look. Hidden behind the Metal
    /// monitor it costs heat: take `180159` ran 10 minutes with nothing lost without it.
    /// A phone whose stream stalled without it keeps it connected: see `CaptureSetup`.
    var appPreviewConnected: Bool { !monitorIsProcessed || captureSupport.setup.keepsPreview }

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

    var activeToolCount: Int { Tool.allCases.filter(isOn).count }

    /// Haptic ticks across the app, from Settings.
    @Published var hapticsOn = true { didSet { Haptics.isOn = hapticsOn } }
    /// The screen corner the scope sits in, after the owner drags it there, in every hold.
    @Published var scopeCorner = ScreenCorner.bottomLeft
    /// The scope's size against its standard one, from its resize handle.
    @Published var scopeScale = 1.0

    /// RGB and YRGB draw their channels in one panel, mixing toward white where they agree.
    @Published var scopeOverlaid = true { didSet { updateScope() } }

    /// The scope the SCOPE tool shows; a tap on it moves to the next.
    @Published var scopeKind = ScopeKind.waveform { didSet { updateScope() } }
    /// Drawn on its own layer from the scope's queue, as the mic bar is, so the main thread
    /// never draws a scope.
    let scopeLayer: CALayer = {
        let layer = CALayer()
        layer.contentsGravity = .resize
        layer.magnificationFilter = .linear
        return layer
    }()
    /// The hold, in clockwise quarter turns from portrait, so a waveform runs across the picture as held.
    var scopeTurns = 0 {
        didSet { if scopeTurns != oldValue { updateScope() } }
    }

    func updateScope() {
        let on = isOn(.scope) && processing.monitor != .isp
        let layer = scopeLayer
        pipeline?.showScope(on ? scopeKind : nil, overlaid: scopeOverlaid, turns: scopeTurns) { image in
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.contents = image
            CATransaction.commit()
        }
        if !on { layer.contents = nil }
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
        if tool == .scope { updateScope() }
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
        config.vignetteCorrection = processing.vignetteCorrection
        config.bakeEffects = processing.bakeEffects
        config.idlePauseMinutes = idlePauseMinutes
        config.monitor = processing.monitor.rawValue
        config.monitorLUT = selectedLUT
        config.lutExpectsRec709 = processing.lutExpectsRec709
        config.monitorOffWhileRecording = processing.pauseMonitorWhileRecording
        config.lockAtRoll = lockAtRoll
        config.saveGyroLog = saveGyroLog
        config.pcmAudio = pcmAudio
        config.stereoAudio = stereoAudio
        config.mainsHz = mainsHz
        config.toolbar = toolbar.map(\.rawValue)
        config.activeTools = activeTools.map(\.rawValue).sorted()
        config.presets = presets
        config.styles = savedStyles
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
        config.bakeToProRes = bakeToProRes
        config.bakeTarget = bakeTarget.rawValue
        config.lookGrade = lookGrade
        config.lookEffects = lookEffects
        config.scopeOverlaid = scopeOverlaid
        config.haptics = hapticsOn
        config.hdrViewfinder = hdrViewfinder
        config.fineLookLUT = fineLookLUT
        config.scopeCorner = scopeCorner.rawValue
        config.scopeScale = scopeScale
        config.testServer = testServer
        config.testToken = testToken
        return config
    }

    /// A file that can't be read is kept beside the new one, so hand edits aren't lost.
    private func loadConfig() {
        var loaded = AppConfig()
        firstLaunch = !FileManager.default.fileExists(atPath: Storage.config.path)
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
        savedStyles = loaded.styles
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
        processing.vignetteCorrection = saved.vignetteCorrection
        processing.bakeEffects = saved.bakeEffects
        idlePauseMinutes = saved.idlePauseMinutes
        processing.monitor = MonitorMode(rawValue: saved.monitor) ?? processing.monitor
        if saved.monitorLUT.isEmpty || isAvailableLook(saved.monitorLUT) { selectedLUT = saved.monitorLUT }
        processing.lutExpectsRec709 = saved.lutExpectsRec709
        processing.pauseMonitorWhileRecording = saved.monitorOffWhileRecording
        lockAtRoll = saved.lockAtRoll
        saveGyroLog = saved.saveGyroLog
        pcmAudio = saved.pcmAudio
        stereoAudio = saved.stereoAudio
        mainsHz = saved.mainsHz
        toolbar = saved.toolbar.compactMap(Tool.init(rawValue:))
        activeTools = Set(saved.activeTools.compactMap(Tool.init(rawValue:)))
        updateScope()
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
        bakeToProRes = saved.bakeToProRes
        bakeTarget = BakeTarget(rawValue: saved.bakeTarget) ?? .sdr
        lookGrade = saved.lookGrade
        lookEffects = saved.lookEffects
        scopeOverlaid = saved.scopeOverlaid
        hapticsOn = saved.haptics
        hdrViewfinder = saved.hdrViewfinder
        fineLookLUT = saved.fineLookLUT
        scopeCorner = ScreenCorner(rawValue: saved.scopeCorner) ?? .bottomLeft
        scopeScale = saved.scopeScale
        // A preset made on another phone may name a codec this one hasn't got.
        fitToPhone(choosingDefaults: false)
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
        // The phone finds its capture setup again by itself, if it still needs one.
        CaptureSupport.forget()
        captureSupport = CaptureSupport.current()
        captureOnTrial = false
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
        if let builtIn = BuiltInLook.named(name) { return builtIn.shortLabel }
        return String((name as NSString).deletingPathExtension.prefix(6)).uppercased()
    }

    /// What the look panel started from, so Cancel can put it back.
    private var lookBeforePanel: (lut: String, bake: Bool, monitor: MonitorMode, grade: LookGrade, effects: LookEffects)?

    /// The look panel changes the viewfinder as it slides, and Cancel puts this back.
    func openLookPanel() {
        lookBeforePanel = (selectedLUT, bakeLook, processing.monitor, lookGrade, lookEffects)
    }

    /// Shows a LUT on the viewfinder without choosing its curve, which only Done does.
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
                if !isRecording {
                    bakeLook = before.bake
                    lookGrade = before.grade
                    lookEffects = before.effects
                }
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
        if !bakeLook, let warning = encoderSupport.warning(for: encoderKey, size: encoderSize.label) {
            return warning
        }
        if let warning = gpuSupport.warning(for: gpuSetupKey, hotFallback: gpuHotFallback) { return warning }
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

    /// The battery's level as a share, nil before iOS reports one.
    var batteryShare: Double? { Int(status.battery.prefix(while: \.isNumber)).map { Double($0) / 100 } }
    var isCharging: Bool { status.battery.contains("charging") || status.battery.contains("full") }

    /// Free space as a share of the whole disk, for the storage gauge.
    var storageShare: Double {
        let total = Double(SystemStatus.totalDisk) / 1_000_000_000
        return total > 0 ? min(Double(status.freeDiskGB) / total, 1) : 0
    }

    /// GB left to record into, or the minutes they hold during a take, when the codec's rate is known.
    var storageGaugeLabel: String {
        if isRecording, let minutes = minutesLeft { return "\(minutes)MIN" }
        return "\(usableGB)GB"
    }

    /// 0 for nominal, 1 for fair, 2 for serious or worse.
    var heatLevel: Int {
        switch status.thermal {
        case "nominal": return 0
        case "fair": return 1
        case "SERIOUS", "CRITICAL": return 2
        default: return 0
        }
    }

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

    /// A take started while the encoders were being timed, which slows both.
    private var takeDuringEncoderCheck = false
    private var checkingEncoders = false

    /// Times each encoder once, then moves off anything this phone can't record. Its answer is
    /// kept unless a take ran alongside it, which would have slowed the trials; the next launch
    /// measures again then.
    private func measureEncoders() {
        let before = (encoderPreset, encoderSize)
        checkingEncoders = true
        takeDuringEncoderCheck = false
        EncoderSupport.measure { [weak self] support in
            guard let self else { return }
            checkingEncoders = false
            // Whether a preset works doesn't depend on load, so that part is used either way.
            encoderSupport = support
            if takeDuringEncoderCheck || isRecording {
                Log.shared.warn("Encoder check overlapped a take, so it runs again at the next launch")
            } else {
                support.save()
            }
            // Only a choice nobody has touched since launch moves to the phone's best size.
            fitToPhone(choosingDefaults: firstLaunch && !takeDuringEncoderCheck && (encoderPreset, encoderSize) == before)
            if firstLaunch { recordFittedDefaults() }
        }
    }

    /// Moves off a codec or setting this phone can't record, and on the first launch picks the
    /// largest size the codec encodes at 30 fps. Never during a take, whose encoder is working.
    private func fitToPhone(choosingDefaults: Bool) {
        guard !isRecording else { return }
        let support = encoderSupport
        var changes: [String] = []
        if twelveBitProRes, !support.supportsTwelveBit {
            twelveBitProRes = false
            changes.append("12-bit ProRes off")
        }
        // Turned off first, so a baked take's codec follows it to HEVC.
        if bakeToProRes, !support.hasProRes {
            bakeToProRes = false
            changes.append("baking to HEVC")
        }
        if !support.supports(encoderPreset) {
            let replacement = support.replacement(for: encoderPreset)
            changes.append("\(encoderPreset.label) to \(replacement.label)")
            encoderPreset = replacement
            if let size = support.bestSize(for: replacement) { encoderSize = size }
        } else if choosingDefaults, let best = support.bestDefault(for: encoderPreset) {
            if best.preset != encoderPreset {
                changes.append("\(encoderPreset.label) to \(best.preset.label)")
                encoderPreset = best.preset
            }
            if best.size != encoderSize {
                changes.append("size \(best.size.label)")
                encoderSize = best.size
            }
        }
        if !changes.isEmpty {
            Log.shared.info("Fitted to \(SystemStatus.deviceModel): " + changes.joined(separator: ", "))
        }
    }

    /// Builds before this one kept the codec and only shrank the size, which left a phone with a
    /// slow ProRes encoder on a small ProRes picture. A choice that still matches what that rule
    /// made is fitted once more. Anything the owner chose since stays.
    private func refitOldDefault() {
        let version = 2
        let defaults = UserDefaults.standard
        defer { defaults.set(version, forKey: "fitVersion") }
        guard !firstLaunch, defaults.integer(forKey: "fitVersion") < version, encoderSupport.measured,
            encoderSize != EncoderSize.all[0], encoderSupport.bestSize(for: encoderPreset) == encoderSize
        else { return }
        fitToPhone(choosingDefaults: true)
    }

    /// The photo loop gave up: its requests stopped finishing. The next setup on the ladder is
    /// tried, and kept for this phone once it streams. Phones that never stall never get here.
    private func captureStalled() {
        guard isStreaming, method == .photoReadiness else { return }
        if isRecording {
            takeStopped("The camera stopped delivering frames.")
            stopRecording()
        }
        guard let next = captureSupport.next else {
            Log.shared.error("The camera stalled in every capture setup on \(captureSupport.device)")
            captureSupport = CaptureSupport.current()
            captureOnTrial = false
            camera.stop()
            isStreaming = false
            idlePaused = true
            takeAlert = TakeAlert(
                title: "Camera stopped",
                detail: "The camera stopped delivering frames in every setup. Tap the picture to try again, and send the session log.")
            return
        }
        Log.shared.warn("Capture stalled on \(captureSupport.setup.label), trying \(next.setup.label)")
        captureSupport = next
        captureOnTrial = true
        showNotice("Camera stalled, trying another setup", seconds: 4)
        reconfigure()
    }

    /// A setup tried after a stall is kept once it has streamed for a few seconds.
    private func keepCaptureSetupIfProven(frames: Int) {
        guard captureOnTrial, isStreaming, frames >= 90 else { return }
        captureOnTrial = false
        captureSupport.save()
        Log.shared.info("Capture setup kept for \(captureSupport.device): \(captureSupport.setup.label)")
    }

    /// How the encoder limits were measured, for Diagnostics.
    var encoderLimitsText: String {
        guard encoderSupport.measured else { return "Not measured yet" }
        var text = encoderSupport.method == .careful ? "Camera stopped" : "Quick check"
        if !encoderSupport.heat.isEmpty { text += ", \(encoderSupport.heat)" }
        if let date = encoderSupport.measuredAt { text += ", " + date.formatted(date: .abbreviated, time: .omitted) }
        let proven = encoderSupport.proven.values.reduce(0) { $0 + $1.count }
        if proven > 0 { text += "; \(proven) proven by takes" }
        return text
    }

    /// The recording setup a take would run, as `GPUSupport` keys it: baked FX always run on the
    /// Efficient path.
    var gpuSetupKey: String {
        let fx = bakeLook && processing.bakeEffects && !lookEffects.isNeutral
        let path = fx ? "efficient" : (processing.pipeline == .efficient ? "efficient" : "maximum")
        let work = fx ? "fx" : bakeLook ? "look" : "log"
        return GPUSupport.key(path: path, work: work, debayer: processing.demosaic == .bilinear ? "bilinear" : "malvar")
    }

    /// Whether the current setup moves onto lighter work when the phone gets hot.
    var gpuHotFallback: Bool {
        gpuSetupKey.hasPrefix("maximum") ? processing.efficientWhenHot : processing.bilinearWhenHot
    }

    /// The key a take's codec has in `EncoderSupport`, with 12-bit ProRes apart.
    var encoderKey: String { twelveBitProRes ? EncoderSupport.twelveBitID : encoderPreset.id }

    /// How long **Run benchmark** waits for the phone to cool before measuring anyway.
    static let encoderCoolingLimit: TimeInterval = 300

    /// **Run benchmark**: stops the camera, waits up to five minutes for nominal heat,
    /// writes the full encoder report, and replaces the quick first-launch figures with careful
    /// ones, which the warnings and defaults then use. What real takes showed is kept, since a
    /// take outranks any trial.
    func runEncoderTest() {
        guard !isRecording, isBusy == nil else { return }
        isBusy = "Releasing camera"
        isStreaming = false
        camera.teardown { [self] in
            waitForNominalHeat(until: Date().addingTimeInterval(Self.encoderCoolingLimit)) { [self] in
                EncoderProbe.run(progress: { text in
                    DispatchQueue.main.async { self.isBusy = text }
                }, completion: { [self] url in
                    isBusy = "Saving encoder limits"
                    EncoderSupport.measure(frames: 45, careful: true) { [self] fresh in
                        var support = fresh
                        support.proven = encoderSupport.proven
                        support.strained = encoderSupport.strained
                        encoderSupport = support
                        support.save()
                        fitToPhone(choosingDefaults: false)
                        // The GPU's setups next, with the camera still stopped.
                        guard let pipeline else {
                            isBusy = nil
                            startStreamAfterConfigure = true
                            reconfigure()
                            return
                        }
                        pipeline.runCostTest(progress: { text in
                            DispatchQueue.main.async { self.isBusy = text }
                        }, completion: { [self] gpuReport in
                            saveGPUCosts(from: gpuReport)
                            isBusy = nil
                            lastResult = "Measured at \(support.heat) heat; reports in probes/\(url.lastPathComponent) and \(gpuReport.lastPathComponent)"
                            startStreamAfterConfigure = true
                            reconfigure()
                        })
                    }
                })
            }
        }
    }

    /// Keeps the cost test's figures per setup, with the heat they were measured at. What takes
    /// showed is kept.
    private func saveGPUCosts(from report: URL) {
        let lines = ((try? String(contentsOf: report, encoding: .utf8)) ?? "").components(separatedBy: "\n")
        let costs = GPUSupport.costs(fromReport: lines)
        guard !costs.isEmpty else { return }
        gpuSupport.costs = costs
        gpuSupport.heat = SystemStatus.thermalName
        gpuSupport.measuredAt = Date()
        gpuSupport.save()
        Log.shared.info("GPU limits saved: " + costs.sorted { $0.key < $1.key }
            .map { String(format: "%@ %.1f ms", $0.key, $0.value) }.joined(separator: ", "))
    }

    /// How the GPU limits stand, for Diagnostics.
    var gpuLimitsText: String {
        guard !gpuSupport.costs.isEmpty else { return "Not measured yet" }
        var text = "\(gpuSupport.costs.count) setups timed"
        if let date = gpuSupport.measuredAt { text += ", " + date.formatted(date: .abbreviated, time: .omitted) }
        if !gpuSupport.proven.isEmpty { text += "; \(gpuSupport.proven.count) proven by takes" }
        if !gpuSupport.strained.isEmpty { text += "; \(gpuSupport.strained.count) fell behind" }
        if !gpuSupport.strainedHot.isEmpty { text += "; \(gpuSupport.strainedHot.count) fell behind when hot" }
        return text
    }

    /// Calls back on the main queue once the phone is at nominal heat, or at the deadline.
    private func waitForNominalHeat(until deadline: Date, then: @escaping () -> Void) {
        DispatchQueue.main.async { [self] in
            if SystemStatus.thermalName == "nominal" || Date() >= deadline {
                then()
                return
            }
            isBusy = "Letting the phone cool first: \(SystemStatus.thermalName)"
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [self] in
                waitForNominalHeat(until: deadline, then: then)
            }
        }
    }

    /// Times each stage of a frame on the GPU, with the camera stopped.
    func runCostTest() {
        guard !isRecording, isBusy == nil, let pipeline else { return }
        isBusy = "Releasing camera"
        isStreaming = false
        camera.teardown { [self] in
            pipeline.runCostTest(progress: { text in
                DispatchQueue.main.async { self.isBusy = text }
            }, completion: { [self] url in
                saveGPUCosts(from: url)
                isBusy = nil
                lastResult = "GPU cost test saved: probes/\(url.lastPathComponent)"
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
        if let linked = linkedLUT(processing.curve, processing.gamut), isAvailableLook(linked) {
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
        syncBakeHDR()
        buildLook()
    }

    /// Every look reaches the pipeline through this one queue, newest request only: a request
    /// that's been overtaken by the time its turn comes is skipped, so a fast drag builds only
    /// the latest grade, and building and uploading the LUT never touch the main thread.
    private let lookQueue = DispatchQueue(label: "VibeLog.look", qos: .userInitiated)
    private let lookLock = NSLock()
    private var lookRequest = 0

    private func nextLookRequest() -> Int {
        lookLock.lock()
        defer { lookLock.unlock() }
        lookRequest += 1
        return lookRequest
    }

    private func isCurrentLook(_ request: Int) -> Bool {
        lookLock.lock()
        defer { lookLock.unlock() }
        return request == lookRequest
    }

    /// Shows a grade on the viewfinder while a slider moves, from a 33-point LUT that builds in a
    /// fraction of the full one's time, without publishing anything. Committing the grade builds
    /// the full LUT.
    func previewGrade(_ grade: LookGrade) {
        guard gradeApplies, !isRecording else { return }
        buildLook(grade: grade, size: 33)
    }

    /// Keeps a grade set by a slider, and replaces its preview with the full LUT even when the
    /// grade ends where it started.
    func commitGrade(_ grade: LookGrade) {
        if lookGrade == grade { buildLook() } else { lookGrade = grade }
    }

    /// Imported LUTs as read from their files, touched only on `lookQueue`.
    private var importedCubes: [String: CubeLUT] = [:]

    /// Every look is made as a LUT on log for the curve, gamut and grade, and remade when any of
    /// them changes: a built-in look graded before its transform, the Rec.709 view the same way,
    /// and an imported LUT with the grade folded in front of it. Ungraded, the Rec.709 view needs
    /// no LUT and an imported one goes as read. Ungraded built-in looks are kept for the session;
    /// graded ones change too often while a slider moves.
    /// A finished look's LUT size in the camera: 65, or 129 with **Fine look LUT**, which CI run 90
    /// measured at about a quarter of the error between grid points but which the GPU reads from a
    /// texture eight times larger during takes, unmeasured.
    var lookLUTSize: Int { fineLookLUT ? 129 : 65 }

    private func buildLook(grade override: LookGrade? = nil, size requested: Int? = nil) {
        let size = requested ?? lookLUTSize
        // A drag's preview builds small; only a finished build is kept or recorded.
        let finished = requested == nil
        let name = selectedLUT
        let look = BuiltInLook.named(name)
        let grade = override ?? lookGrade
        let request = nextLookRequest()
        let pipeline = self.pipeline
        let curve = processing.curve
        let gamut = processing.gamut
        let madeForRec709 = processing.lutExpectsRec709
        // Takes record the HDR look only from a finished build, never a drag's preview.
        let hdrTarget: BakeTarget? = bakesHDR ? bakeTarget : nil
        if finished {
            lookQueue.async { [weak self] in
                guard let self, self.isCurrentLook(request) else { return }
                let hdr = hdrTarget.map { BuiltInLook.hdrLUT(curve: curve, gamut: gamut, grade: grade, target: $0, size: size) }
                if self.isCurrentLook(request) { pipeline?.setBakeLUT(hdr) }
            }
        }
        // The HDR viewfinder shows the look at 1000 nits as PQ, whichever HDR the takes encode,
        // and follows a drag's preview, as the SDR one does.
        let hdrView = showsHDRViewfinder
        lookQueue.async { [weak self] in
            guard let self, self.isCurrentLook(request) else { return }
            let lut = hdrView ? BuiltInLook.hdrLUT(curve: curve, gamut: gamut, grade: grade, target: .pq, size: size) : nil
            if self.isCurrentLook(request) { pipeline?.setMonitorHDR(lut) }
        }
        if look == nil, !name.isEmpty {
            lookQueue.async { [weak self] in
                guard let self, self.isCurrentLook(request) else { return }
                do {
                    let cube = try self.importedCubes[name] ?? CubeLUT(
                        text: String(contentsOf: Storage.luts.appendingPathComponent(name), encoding: .utf8))
                    self.importedCubes[name] = cube
                    guard self.isCurrentLook(request) else { return }
                    if grade.isNeutral {
                        pipeline?.setCustomLUT(cube)
                    } else {
                        let lut = BuiltInLook.graded(
                            cube, expectsRec709: madeForRec709, curve: curve, gamut: gamut, grade: grade, size: size)
                        if self.isCurrentLook(request) { pipeline?.setCustomLUT(lut, expectsRec709: false) }
                    }
                } catch {
                    Log.shared.error("Cannot load LUT \(name): \(error)")
                }
            }
            return
        }
        guard look != nil || !grade.isNeutral else {
            lookQueue.async { [weak self] in
                if self?.isCurrentLook(request) == true { pipeline?.setCustomLUT(nil) }
            }
            return
        }
        let key = "\(look?.name ?? "Rec.709") · \(curve.label) · \(gamut.label) · \(size)"
        let cached = grade.isNeutral && finished ? builtInLUTs[key] : nil
        lookQueue.async { [weak self] in
            guard let self, self.isCurrentLook(request) else { return }
            let start = Date()
            let lut = cached ?? look?.lut(curve: curve, gamut: gamut, grade: grade, size: size)
                ?? BuiltInLook.rec709LUT(curve: curve, gamut: gamut, grade: grade, size: size)
            if cached == nil, grade.isNeutral, finished {
                Log.shared.info("Built \(key) in \(String(format: "%.2f", Date().timeIntervalSince(start))) s")
                DispatchQueue.main.async { self.builtInLUTs[key] = lut }
            }
            if self.isCurrentLook(request) { pipeline?.setCustomLUT(lut, expectsRec709: false) }
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
        if hot { takeReachedSerious = true }
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

    /// Saves a profile of each lens from Apple's calibration, or its field of view, for this phone.
    func measureLenses() {
        runReleasingCamera(LensCalibrator.run) { _ in
            let saved = LensProfile.saved()
            // Their Gyroflow profiles too, so the test link can fetch them with no one on the page.
            let gyroflow = GyroflowProfile.write(saved)
            Log.shared.info("Lenses: \(gyroflow.count) Gyroflow profiles written: \(gyroflow.map(\.lastPathComponent).joined(separator: ", "))")
            return saved.isEmpty ? "No lens gave a profile" : "Lens profiles saved: " + saved.map(\.lens).joined(separator: ", ")
        }
    }

    private func runReleasingCamera(
        _ probe: @escaping (@escaping (String) -> Void, @escaping (URL) -> Void) -> Void,
        result: @escaping (URL) -> String = { "Probe saved: probes/\($0.lastPathComponent)" }
    ) {
        guard !isRecording, isBusy == nil else { return }
        isBusy = "Releasing camera"
        isStreaming = false
        camera.teardown { [self] in
            probe({ text in
                DispatchQueue.main.async { self.isBusy = text }
            }, { [self] url in
                isBusy = nil
                lastResult = result(url)
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
        let setup = captureSupport.setup
        // Only the default method follows the phone's setup. One picked in Diagnostics stays.
        camera.reportsStalls = method == .photoReadiness
        let config = CaptureConfig(
            lensID: lensID, formatIndex: formatIndex,
            method: method == .photoReadiness && setup.sequential ? .photoSequential : method,
            rawPixelFormat: rawFormat == 0 ? nil : rawFormat, photoSize: photoSize,
            videoPixelFormat: videoFormat == 0 ? nil : videoFormat, videoFPS: videoFPS,
            frameRate: frameRate, bracketCount: bracketCount, usePhotoPreset: usePhotoPreset,
            fixedFrameTime: fixedFrameTime, distortionCorrection: distortionCorrection,
            fastCapture: setup.fastCapture)
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
        if checkingEncoders { takeDuringEncoderCheck = true }
        guard !isRecording, !recordStarting, pendingRateChange == nil else { return }
        // A stream that delivers nothing would record an empty file and only say so at the end.
        if isStreaming, Date().timeIntervalSince(streamStart) > 3, (router.stats.secondsSinceFrame() ?? .infinity) > 2 {
            Log.shared.warn("Record refused: no frame has arrived for over 2 seconds")
            showNotice("The camera isn't delivering frames, so nothing would be recorded", seconds: 4)
            takeSeconds = nil
            return
        }
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

    /// The take's codec and size as it started, for what it shows about the encoder.
    private var takeBaked = false
    private var takeSize = ""
    private var takeChosenSize = ""
    private var takeEncoderKey = ""
    private var takeGPUSetup = ""
    /// The take reached serious heat, which changes what falling behind says about its setup.
    private var takeReachedSerious = false

    private func startEncoding() {
        guard let pipeline, processing.enabled, method.isPhoto else {
            Log.shared.error("Encoding needs a photo method and the GPU pipeline")
            takeAlert = TakeAlert(
                title: "Can't record", detail: "Recording needs a photo method and the GPU pipeline.")
            return
        }
        takeBaked = bakeLook
        takeSize = outputSize.label
        takeChosenSize = encoderSize.label
        takeEncoderKey = encoderKey
        takeGPUSetup = gpuSetupKey
        takeReachedSerious = isHot
        let name = "video_\(Storage.timestamp())"
        let url = Storage.videos.appendingPathComponent(name + ".mov")
        var metadata: [String: String] = [
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
            "pipeline": takePipelineLabel,
            "orientation": hold.hold.label,
            "reducedLoadAtStart": isHot && processing.bilinearWhenHot ? "yes, bilinear debayer" : "no",
            "lens": currentLensLabel,
            "tools": toolsLabel,
            "frameTime": fixedFrameTime ? "fixed" : "variable at 30 fps",
            "distortionCorrection": distortionCorrection ? "on" : "off, so the lens's distortion stays in the picture",
            "vignetteCorrection": processing.vignetteCorrection ? "Apple's lens shading, FixVignetteRadial" : "off",
            "effects": bakeLook && processing.bakeEffects && !lookEffects.isNeutral ? "baked in: \(lookEffects.label)" : "none in the file",
            "bitDepth": String(takePreset.bitDepth),
            "appPreview": appPreviewConnected ? "connected" : "disconnected",
            "captureSetup": captureSupport.setup.label,
            "fileTag": takeFileTag.label,
            "look": bakedLookLabel,
            "desqueeze": processing.desqueeze == 1 ? "off" : String(processing.desqueeze),
            "hotPath": processing.efficientWhenHot ? "Efficient when hot" : "stays on the chosen pipeline",
            "hotDebayer": processing.bilinearWhenHot ? "Bilinear when hot" : "stays on the chosen debayer",
            "gyroLog": saveGyroLog ? "on" : "off",
            "thermalAtStart": SystemStatus.thermalName,
            "note": bakeLook ? "The look is baked in, and the file's tags describe it."
                : "The file's transfer tag is nominal; decode with the curve named here.",
        ]
        if let recipe = bakedRecipe { metadata[GradeRecipe.metadataKey] = recipe.metadataValue }
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
                let version = SystemStatus.appVersion
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
            Log.shared.info("Encoding \(name): lens \(currentLensLabel), \(takePreset.label) \(takePreset.bitDepth)-bit \(outputSize.label) at \(frameRateLabel) fps, frame time \(metadata["frameTime"] ?? "?"), audio \(metadata["audio"] ?? "?"), gyro \(metadata["gyroLog"] ?? "?"), tools \(toolsLabel), exposure \(metadata["exposureDuringTake"] ?? "?"), white balance \(metadata["whiteBalanceDuringTake"] ?? "?"), \(processing.curve.label), \(takePipelineLabel) pipeline, \(seconds > 0 ? "\(seconds)s" : "until stopped"), battery \(SystemStatus.batteryText), thermal \(SystemStatus.thermalName), free \(SystemStatus.freeDisk / 1_000_000_000) GB")
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
            // What the take showed about its encoder, for log takes in the chosen size only: a
            // baked take adds GPU work and may write another codec, and 16:9 is a smaller size.
            logUploader.takeFinished()
            // A take whose path or debayer changed for heat mixes two setups, so it says nothing.
            let changedForHeat = takeHeatEvents.contains { $0.contains("hot:") && !$0.contains("no change") }
            if !changedForHeat {
                gpuSupport.record(take: takeGPUSetup, seconds: finished.seconds, frames: finished.framesWritten,
                                  gpuDropped: gpu.dropped, reachedSerious: takeReachedSerious)
                gpuSupport.save()
            }
            if !takeBaked, takeSize == takeChosenSize {
                encoderSupport.record(take: takeEncoderKey, size: takeChosenSize, seconds: finished.seconds,
                                      fps: finished.fps, encoderDrops: encoderDrops)
                if encoderSupport.measured { encoderSupport.save() }
            }
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
            lastTakeFile = result.file
            lastResult = summary
            guard result.framesWritten > 0 else {
                testLink.holdFiles(false)
                trialTakeFinished(file: result.file, summary: summary)
                return
            }
            makeThumbnail(for: Storage.videos.appendingPathComponent(result.file))
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let sidecar = Storage.videos.appendingPathComponent(result.file + ".json")
            try? encoder.encode(result).write(to: sidecar)
            // A trial take is deleted once measured, so it isn't sent anywhere.
            if trialState == nil {
                sendTakeFiles(video: Storage.videos.appendingPathComponent(result.file))
            }
            testLink.holdFiles(false)
            trialTakeFinished(file: result.file, summary: summary)
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
        let vignette = VignetteRadial(photoMetadata: metadata)
        pipeline?.setCalibration(data.flatMap { try? DNGMetadata(dng: $0) }, levels: levels, vignette: vignette)
        if let vignette {
            Log.shared.info(String(
                format: "Lens shading: k %@, centre (%.4f, %.4f), corner gain %.2f",
                vignette.k.map { String(format: "%.3f", $0) }.joined(separator: " "),
                vignette.centreX, vignette.centreY, vignette.gain(radius: 1)))
        }
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
        keepCaptureSetupIfProven(frames: snapshot.frames)
        if isRecording {
            recordElapsed = Int(Date().timeIntervalSince(recordStart))
            audioPeak = audio.takePeak()
            if line.thermal == "CRITICAL" {
                Log.shared.warn("Stopping at \(recordElapsed)s: thermal state is critical")
                takeStopped("The phone is too hot.")
                stopRecording()
            } else if recordElapsed >= 3, (router.stats.secondsSinceFrame() ?? .infinity) > 3 {
                Log.shared.warn("Stopping at \(recordElapsed)s: no frame has arrived for over 3 seconds")
                takeStopped("The camera stopped delivering frames.")
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
