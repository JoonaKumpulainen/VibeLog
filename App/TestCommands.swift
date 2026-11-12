import Foundation
import VLCapture
import VLCore
import VLProcessing
import VLRecording

private let settingsDuringTake: Set<String> = ["tools", "punch", "look"]

/// What the test server may ask for. Anything not listed here is refused, nothing here deletes a
/// take, and settings that would end a take are refused during one.
extension AppModel {
    func updateTestLink() {
        testLink.onState = { [weak self] state in
            guard let self else { return }
            if state == "Connected", self.testLinkState != "Connected" { self.showNotice("Test link connected") }
            self.testLinkState = state
        }
        testLink.onCommand = { [weak self] command, reply in
            reply(self?.perform(command) ?? TestReply(id: command.id, ok: false, message: "App closing"))
        }
        guard testLinkOn else {
            testLink.stop()
            return
        }
        guard let base = TestLinkAddress.base(testServer, overInternet: testOverInternet), !testToken.isEmpty else {
            let secure = testServer.trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("https://")
            testLinkState = testServer.isEmpty || testToken.isEmpty ? "Needs a server and a token"
                : testOverInternet && !secure ? "Over the internet needs an https:// address"
                : !testOverInternet && secure ? "An https:// address needs Over the internet on"
                : "Needs a server and a token"
            testLinkOn = false
            return
        }
        if testOverInternet { Log.shared.warn("Test link connecting over the internet, to \(base.host ?? "?")") }
        testLink.start(base: base, token: testToken, overInternet: testOverInternet)
    }

    /// Sends what's selected in Diagnostics. Videos only go when asked for by name.
    func sendTakeFiles(video: URL) {
        guard testLinkOn else { return }
        if testSendsResults {
            testLink.send(file: Storage.videos.appendingPathComponent(video.lastPathComponent + ".json"))
            sendLog()
        }
        let gyro = TakeLibrary.gyroLog(for: video)
        if testSendsGyro, FileManager.default.fileExists(atPath: gyro.path) { testLink.send(file: gyro) }
    }

    /// The timing file is written after the take's other files, so it goes on its own.
    func sendTimingFile(_ file: URL) {
        if testLinkOn, testSendsGyro { testLink.send(file: file) }
    }

    /// Why the camera can't take an instruction now.
    private var cameraBlocked: String? {
        if let isBusy { return "Busy: \(isBusy)" }
        if playingTake != nil { return "The player or library is open" }
        if exportValues["exporting"] == "true" { return "Exporting a take" }
        return nil
    }

    /// The test link's own export, which the screen's export doesn't share.
    private var exportValues: [String: String] {
        MainActor.assumeIsolated {
            let job = testExport
            return [
                "exporting": String(job.progress != nil), "exportProgress": String(format: "%.2f", job.progress ?? 0),
                "exports": String(job.runs), "lastExport": job.message ?? "",
            ]
        }
    }

    /// Bakes a take as the export screen would. `name` is a video's file name, or newest for the
    /// newest take still in log. `value` takes look, target and codec as name=value, split by
    /// semicolons, since look names can hold commas. Returns what's wrong, or nil once it starts.
    private func startTestExport(_ command: TestCommand) -> String? {
        var choice = ExportChoice()
        for part in (command.value ?? "").split(separator: ";") {
            let pair = part.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard pair.count == 2 else { return "export takes name=value settings, split by ;" }
            switch pair[0] {
            case "look":
                if ["monitor", "none"].contains(pair[1]) {
                    choice.lutName = ""
                } else if lookNames.contains(pair[1]) {
                    choice.lutName = pair[1]
                } else {
                    return "look takes monitor or: \(lookNames.joined(separator: ", "))"
                }
            case "lutMadeFor":
                guard ["log", "rec709"].contains(pair[1]) else { return "lutMadeFor takes log or rec709" }
                choice.lutMadeForRec709 = pair[1] == "rec709"
            case "target":
                guard let target = BakeTarget(rawValue: pair[1]) else {
                    return "target takes: \(BakeTarget.allCases.map(\.rawValue).joined(separator: ", "))"
                }
                choice.target = target
            case "codec":
                guard ExportChoice.codecs.contains(pair[1]) else {
                    return "codec takes \(ExportChoice.codecs.joined(separator: ", "))"
                }
                choice.codec = pair[1]
            case "size":
                guard let quality = ExportQuality(rawValue: pair[1]) else { return "size takes master, high or share" }
                choice.quality = quality
            case "resolution":
                guard let resolution = ExportResolution(rawValue: pair[1]) else { return "resolution takes full, medium or small" }
                choice.resolution = resolution
            case "crop":
                guard let crop = ExportCrop(rawValue: pair[1]) else { return "crop takes none, wide or tall" }
                choice.crop = crop
            case "shift":
                guard let shift = Double(pair[1]), (-1...1).contains(shift) else { return "shift takes -1 to 1" }
                choice.cropShift = shift
            case "log":
                // A curve's label, which pairs it with its own gamut, or curve/gamut by label.
                let names = pair[1].split(separator: "/").map(String.init)
                guard let target = ExportChoice.LogTarget.all.first(where: {
                    $0.curve.label == names[0] && (names.count == 1 ? $0.gamut == $0.curve.nativeGamut : $0.gamut.label == names[1])
                }) else { return "log takes a curve's label, such as S-Log3, or curve/gamut, such as S-Log3/S-Gamut3" }
                choice.logTarget = target
            case "effects":
                // As the effects setting takes them: none, or halation=1,bloom=0.5 and so on.
                for effect in pair[1].split(separator: ",") where pair[1] != "none" {
                    let parts = effect.split(separator: ":")
                    guard parts.count == 2, let number = Double(parts[1]),
                        let control = FXControl.allCases.first(where: { "\($0)" == String(parts[0]) }),
                        control.range.contains(number)
                    else { return "effects takes none, or halation, bloom, diffusion, vignette and grain as name:value" }
                    choice.effects[keyPath: control.keyPath] = number
                }
            case "stabilize":
                guard ["on", "off"].contains(pair[1]) else { return "stabilize takes on or off" }
                choice.stabilize = pair[1] == "on"
            case "smooth":
                guard let seconds = Double(pair[1]), (0.1...5).contains(seconds) else { return "smooth takes 0.1 to 5 seconds" }
                choice.stabilizeSeconds = seconds
            default:
                return "export takes look=, lutMadeFor=, target=, codec=, size=, resolution=, crop=, stabilize=, smooth= and effects=, split by ;"
            }
        }
        let wanted = command.name.flatMap(TestLinkAddress.safeName) ?? "newest"
        let takes = TakeLibrary.takes()
        let found = wanted == "newest"
            ? takes.first { ExportChoice.isLog($0) && !TakeLibrary.isExport($0.url) }
            : takes.first { $0.url.lastPathComponent == wanted }
        guard let take = found else { return wanted == "newest" ? "No take in log to export" : "No take named \(wanted)" }
        // A take with its look baked in can still be written again steadied, as it is.
        if !ExportChoice.isLog(take) {
            guard choice.stabilize else {
                return "\(take.url.lastPathComponent) already has its look baked in; only stabilize=on can export it"
            }
            choice.keepAsShot(take)
        }
        let chosen = choice
        return MainActor.assumeIsolated {
            guard testExport.progress == nil else { return "An export is running" }
            // The camera's stream takes close to a gigabyte, which a long 12 MP export needs, so
            // it stops for the export, as it does behind the export screen, and starts again after.
            let wasStreaming = isStreaming
            if wasStreaming { toggleStream() }
            testExport.onFinish = { [weak self] in
                guard let self, wasStreaming, !self.isStreaming, !self.isRecording else { return }
                self.toggleStream()
            }
            testExport.start(take: take, choice: chosen)
            return nil
        }
    }

    /// The newest folder of timestamped results.
    private func newestFolder(in parent: URL) -> URL? {
        let names = try? FileManager.default.contentsOfDirectory(atPath: parent.path)
        return (names ?? []).max().map { parent.appendingPathComponent($0, isDirectory: true) }
    }

    private func sendFiles(in folder: URL, only names: [String]? = nil) -> Int {
        let found = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        let files = found.filter { names?.contains($0) ?? true }
        for name in files {
            testLink.send(file: folder.appendingPathComponent(name), name: "\(folder.lastPathComponent)_\(name)")
        }
        return files.count
    }

    private func sendLog() {
        guard let data = Log.shared.text().data(using: .utf8) else { return }
        testLink.send(data: data, name: "session_\(sessionStamp).log")
    }

    private func perform(_ command: TestCommand) -> TestReply {
        func done(_ message: String = "ok") -> TestReply {
            TestReply(id: command.id, ok: true, message: message, values: testStatus)
        }
        func refused(_ message: String) -> TestReply {
            TestReply(id: command.id, ok: false, message: message, values: testStatus)
        }
        switch command.action {
        case "status":
            return done()
        case "set":
            guard let name = command.name, let value = command.value else { return refused("set needs a name and a value") }
            if isRecording, !settingsDuringTake.contains(name) {
                return refused("Only \(settingsDuringTake.sorted().joined(separator: ", ")) change during a take")
            }
            if let problem = applyTestSetting(name, value) { return refused(problem) }
            return done()
        case "record":
            guard let seconds = command.seconds, seconds > 0 else { return refused("record needs seconds") }
            guard !isRecording else { return refused("Already recording") }
            if let cameraBlocked { return refused(cameraBlocked) }
            record(seconds: seconds)
            return done()
        case "stop":
            if isRecording { toggleRecord() }
            return done()
        case "stream":
            guard let value = command.value, ["on", "off"].contains(value) else { return refused("stream takes on or off") }
            guard !isRecording else { return refused("A take is running") }
            if let cameraBlocked { return refused(cameraBlocked) }
            if (value == "on") != isStreaming { toggleStream() }
            return done()
        case "focusAt":
            guard let point = command.value.flatMap(TestLinkAddress.point) else { return refused("focusAt takes x,y from 0 to 1") }
            guard !isRecording else { return refused("Focus can't change during a take") }
            focus(at: CGPoint(x: point.x, y: point.y))
            return done()
        case "applyPreset":
            guard let saved = presets.first(where: { $0.name == command.name }) else {
                return refused("Presets: \(presets.map(\.name).joined(separator: ", "))")
            }
            guard !isRecording else { return refused("A take is running") }
            apply(saved)
            return done()
        case "savePreset":
            guard let name = command.name, !name.isEmpty else { return refused("savePreset needs a name") }
            savePreset(named: name)
            return done()
        case "defaultPreset":
            guard let name = command.name, name == "none" || presets.contains(where: { $0.name == name })
            else { return refused("defaultPreset takes none or a preset's name") }
            defaultPreset = name == "none" ? "" : name
            return done()
        case "resetSettings":
            guard !isRecording else { return refused("A take is running") }
            resetSettings()
            return done()
        case "benchmark":
            guard !isRecording, isBusy == nil, !benchmarkRunning else { return refused("Busy, or a take is running") }
            startBenchmark(fresh: command.value == "fresh")
            return done()
        case "cancelBenchmark":
            cancelBenchmark()
            return done()
        case "trialTakes":
            guard !isRecording else { return refused("A take is running") }
            guard isStreaming else { return refused("The camera isn't running") }
            runTrialTakes()
            return done()
        case "encoderTest", "measureEncoders", "measurePhone", "probe", "measureLenses", "costTest":
            guard !isRecording else { return refused("A take is running") }
            if let cameraBlocked { return refused(cameraBlocked) }
            switch command.action {
            case "probe": runProbe()
            case "measureLenses": measureLenses()
            case "costTest": runCostTest()
            default: runEncoderTest()
            }
            return done()
        case "saveStill", "sendPreview":
            guard isStreaming, !isRecording else { return refused("Needs a running stream and no take") }
            command.action == "saveStill" ? saveStill() : sendPreview()
            return done()
        case "sendStill":
            guard let folder = newestFolder(in: Storage.stills) else { return refused("No stills") }
            return done("Sending \(sendFiles(in: folder)) files")
        case "sendReference":
            guard let folder = newestFolder(in: Storage.clips) else { return refused("No RAW clips") }
            let sent = sendFiles(in: folder, only: ["reference.dng", "reference_metadata.json", "clip.json"])
            return done("Sending \(sent) files from \(folder.lastPathComponent)")
        case "export":
            guard !isRecording else { return refused("A take is running") }
            if let problem = startTestExport(command) { return refused(problem) }
            return done()
        case "cancelExport":
            MainActor.assumeIsolated { testExport.cancel() }
            return done()
        case "controlTest":
            guard isStreaming, !isRecording else { return refused("Needs a running stream and no take") }
            runControlTest()
            return done()
        case "sendLog":
            sendLog()
            return done()
        case "listFiles":
            return done(testFiles().joined(separator: "\n"))
        case "sendFile":
            guard let name = command.name.flatMap(TestLinkAddress.safeName) else { return refused("sendFile needs a name") }
            guard let file = [Storage.videos, Storage.logs, Storage.probes, LensProfile.folder]
                .map({ $0.appendingPathComponent(name) })
                .first(where: { FileManager.default.fileExists(atPath: $0.path) })
            else { return refused("No file named \(name)") }
            testLink.send(file: file)
            return done()
        default:
            return refused("Unknown action \(command.action)")
        }
    }

    private func testFiles() -> [String] {
        [Storage.videos, Storage.logs, Storage.probes, Storage.clips, Storage.stills, LensProfile.folder].flatMap { folder in
            let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path)
            return (names ?? []).sorted()
        }
    }

    private var testStatus: [String: String] {
        [
            "app": SystemStatus.appVersion, "phone": SystemStatus.deviceModel, "encoderLimits": encoderLimitsText, "gpuLimits": gpuLimitsText, "gpuSetup": gpuSetupKey, "trials": trialProgress, "benchmark": benchmarkStatusText,
            "recording": String(isRecording), "streaming": String(isStreaming),
            "screen": playingTake == nil ? openScreen : "player", "busy": isBusy ?? "",
            "method": method.rawValue, "encodeVideo": String(recordEncoded),
            "whiteBalance": whiteBalanceLocked ? String(Int(temperature)) : "auto",
            "focus": focusLocked ? String(format: "%.2f", lensPosition) : "auto",
            "look": processing.monitor.rawValue, "lut": selectedLUT.isEmpty ? "none" : selectedLUT,
            "stopAfter": String(recordSeconds),
            "presets": presets.map(\.name).joined(separator: ", "),
            "defaultPreset": defaultPreset.isEmpty ? "none" : defaultPreset,
            "elapsed": String(recordElapsed), "lens": currentLensLabel,
            "codec": encoderPreset.id, "size": encoderSize.label, "aspect": widescreen ? "16:9" : "4:3",
            "frameRate": frameRateLabel, "curve": processing.curve.label, "gamut": processing.gamut.label,
            "pairsGamut": String(processing.pairsGamut),
            "pipeline": processing.pipeline.rawValue, "tools": toolsLabel,
            "fixedFrameTime": String(fixedFrameTime), "uncompressedAudio": String(pcmAudio),
            "stereoAudio": String(stereoAudio),
            "distortionCorrection": String(distortionCorrection), "vignetteCorrection": String(processing.vignetteCorrection), "bakeEffects": String(processing.bakeEffects), "twelveBitProRes": String(twelveBitProRes),
            "bakeLook": String(bakeLook), "bakeToProRes": String(bakeToProRes), "bakeTarget": bakeTarget.rawValue,
            "effects": lookEffects.label, "scopeOverlaid": String(scopeOverlaid), "hdrViewfinder": String(hdrViewfinder), "fineLookLUT": String(fineLookLUT), "hdrShown": String(showsHDRViewfinder), "fileTagWritten": takeFileTag.label, "grade": lookGrade.label, "style": currentStyleChoice.map { String($0.dropFirst(Self.stylePrefix.count)) } ?? "",
            "efficientWhenHot": String(processing.efficientWhenHot), "isoAuto": String(isoAuto),
            "bilinearWhenHot": String(processing.bilinearWhenHot),
            "yields": String(pipelineStats.monitorYields),
            "fileTag": fileTag.rawValue, "frameGuide": frameGuide.rawValue,
            "desqueeze": String(processing.desqueeze), "copyMs": String(format: "%.1f", pipelineStats.copyMs),
            "queueMs": String(format: "%.1f", pipelineStats.queueMs),
            "drawMs": String(format: "%.1f", pipelineStats.drawMs),
            "saveGyro": String(saveGyroLog), "captureTiming": String(logCaptureTiming),
            "appPreview": appPreviewConnected ? "connected" : "disconnected",
            "captureSetup": captureSupport.setup.label,
            "fps": String(format: "%.2f", stats.rollingFPS), "drops": String(takeDrops),
            "gpuMs": String(format: "%.1f", pipelineStats.gpuRecentMs),
            "thermal": status.thermal, "battery": status.battery, "freeGB": String(status.freeDiskGB),
            "shutter": exposureLocked ? shutterLabel : "auto", "iso": exposureLocked ? String(Int(iso)) : "auto",
            "lastResult": lastResult ?? "", "lastTake": lastTakeFile,
        ].merging(exportValues) { $1 }
    }

    /// Returns what's wrong, or nil once it's set.
    private func applyTestSetting(_ name: String, _ value: String) -> String? {
        func flag(_ apply: (Bool) -> Void) -> String? {
            guard let parsed = Bool(value) else { return "\(name) takes true or false" }
            apply(parsed)
            return nil
        }
        func pick<T>(_ options: [T], _ label: (T) -> String, _ apply: (T) -> Void) -> String? {
            guard let match = options.first(where: { label($0) == value }) else {
                return "\(name) takes: \(options.map(label).joined(separator: ", "))"
            }
            apply(match)
            return nil
        }
        switch name {
        case "lens": return pick(lenses, \.zoomLabel) { lensID = $0.id }
        // By label, so a decimal rate would match as typed.
        case "frameRate": return pick(FrameRates.all, FrameRates.label) { frameRate = $0 }
        case "codec": return pick(EncoderPreset.all, \.id) { encoderPreset = $0 }
        case "size": return pick(EncoderSize.all, \.label) { encoderSize = $0 }
        case "aspect": return pick(["4:3", "16:9"], { $0 }) { widescreen = $0 == "16:9" }
        case "curve": return pick(LogCurve.allCases, \.label) { processing.curve = $0 }
        case "gamut": return pick(Gamut.allCases, \.label) { processing.gamut = $0 }
        case "pairsGamut": return flag { processing.pairsGamut = $0 }
        case "pipeline": return pick(PipelineMode.allCases, \.rawValue) { processing.pipeline = $0 }
        case "debayer": return pick(DemosaicMethod.allCases, \.label) { processing.demosaic = $0 }
        case "peaking": return pick(PeakingSensitivity.allCases, \.rawValue) { processing.peakingSensitivity = $0 }
        case "exposureOffset":
            guard let stops = Double(value), (-3...3).contains(stops) else { return "exposureOffset takes -3 to 3" }
            processing.exposureStops = stops
            return nil
        case "uncompressedAudio": return flag { pcmAudio = $0 }
        case "stereoAudio": return flag { stereoAudio = $0 }
        case "saveGyro": return flag { saveGyroLog = $0 }
        case "captureTiming": return flag { logCaptureTiming = $0 }
        case "fixedFrameTime": return flag { fixedFrameTime = $0 }
        case "distortionCorrection": return flag { distortionCorrection = $0 }
        case "vignetteCorrection": return flag { processing.vignetteCorrection = $0 }
        case "bakeEffects": return flag { processing.bakeEffects = $0 }
        case "twelveBitProRes": return flag { twelveBitProRes = $0 }
        case "bakeLook": return flag { bakeLook = $0 }
        case "bakeToProRes": return flag { bakeToProRes = $0 }
        case "bakeTarget":
            guard !isRecording else { return "bakeTarget can't change during a take" }
            return pick(BakeTarget.allCases, \.rawValue) { bakeTarget = $0 }
        case "scopeOverlaid": return flag { scopeOverlaid = $0 }
        case "hdrViewfinder": return flag { hdrViewfinder = $0 }
        case "fineLookLUT": return flag { fineLookLUT = $0 }
        case "effects":
            // "none", or names and values such as bloom=0.5,grain=0.3, from the FX sliders' ranges.
            guard !isRecording else { return "effects can't change during a take" }
            var effects = LookEffects()
            for part in value.split(separator: ",") where value != "none" {
                let pair = part.split(separator: "=")
                guard pair.count == 2, let number = Double(pair[1]),
                    let control = FXControl.allCases.first(where: { "\($0)" == String(pair[0]) }),
                    control.range.contains(number)
                else { return "effects takes none, or halation, bloom, diffusion, vignette and grain as name=value" }
                effects[keyPath: control.keyPath] = number
            }
            lookEffects = effects
            return nil
        case "style":
            guard !isRecording else { return "style can't change during a take" }
            guard let style = style(forChoice: Self.stylePrefix + value) else {
                return "style takes: \(styles.map(\.name).joined(separator: ", "))"
            }
            processing.monitor = .rec709
            previewStyle(style)
            return nil
        case "grade":
            // "none", or names and values such as exposure=0.5,saturation=1.2, from the slider ranges,
            // and wheels as shadows=x:y:luminance, each -1 to 1.
            guard !isRecording else { return "grade can't change during a take" }
            var grade = LookGrade()
            for part in value.split(separator: ",") where value != "none" {
                let pair = part.split(separator: "=")
                if pair.count == 2, let range = ToneRange.allCases.first(where: { $0.name == String(pair[0]) }) {
                    let numbers = pair[1].split(separator: ":").compactMap { Double($0) }
                    guard numbers.count == 3, numbers.allSatisfy({ (-1...1).contains($0) }) else {
                        return "a wheel takes shadows, midtones or highlights as name=x:y:luminance, each -1 to 1"
                    }
                    grade.wheels[range.rawValue].x = numbers[0]
                    grade.wheels[range.rawValue].y = numbers[1]
                    grade.wheels[range.rawValue].luminance = numbers[2]
                    continue
                }
                guard pair.count == 2, let number = Double(pair[1]),
                    let control = GradeControl.allCases.first(where: { "\($0)" == String(pair[0]) }),
                    control.range.contains(number)
                else { return "grade takes none, or exposure, contrast, temperature, tint and saturation as name=value" }
                grade[keyPath: control.keyPath] = number
            }
            lookGrade = grade
            return nil
        case "efficientWhenHot": return flag { processing.efficientWhenHot = $0 }
        case "isoAuto":
            guard exposureLocked else { return "isoAuto needs a set shutter first" }
            return flag { isoAuto = $0 }
        case "frameGuide": return pick(FrameGuide.allCases, \.rawValue) { frameGuide = $0 }
        case "fileTag": return pick(FileTag.allCases, \.rawValue) { fileTag = $0 }
        case "desqueeze":
            guard let amount = Double(value), (1...2).contains(amount) else { return "desqueeze takes 1 to 2" }
            processing.desqueeze = amount
            return nil
        case "slowViewfinderWhenHot": return flag { processing.reduceLoadWhenHot = $0 }
        case "bilinearWhenHot": return flag { processing.bilinearWhenHot = $0 }
        case "idlePauseMinutes":
            guard let minutes = Double(value), minutes >= 0 else { return "idlePauseMinutes takes 0 for never, or minutes" }
            idlePauseMinutes = minutes
            return nil
        case "autoDuringTake": return flag { lockAtRoll = !$0 }
        case "tools":
            let wanted = value == "none" ? [] : value.split(separator: ",").map(String.init)
            let unknown = wanted.filter { Tool(rawValue: $0) == nil }
            guard unknown.isEmpty else {
                return "tools takes none or: \(Tool.allCases.map(\.rawValue).joined(separator: ","))"
            }
            for tool in Tool.allCases where isOn(tool) != wanted.contains(tool.rawValue) { toggle(tool) }
            return nil
        case "method": return pick(CaptureMethod.allCases, \.rawValue) { method = $0 }
        case "encodeVideo": return flag { recordEncoded = $0 }
        case "writeFrames": return flag { writeFrames = $0 }
        case "look": return pick(MonitorMode.allCases, \.rawValue) { processing.monitor = $0 }
        case "lut":
            if value == "none" {
                selectedLUT = ""
                return nil
            }
            return pick(lookNames, { $0 }) { selectedLUT = $0 }
        case "lutMadeFor": return pick(["log", "rec709"], { $0 }) { processing.lutExpectsRec709 = $0 == "rec709" }
        case "freezeViewfinder": return flag { processing.pauseMonitorWhileRecording = $0 }
        case "punch":
            guard let point = TestLinkAddress.point(value) else { return "punch takes x,y from 0 to 1" }
            movePunch(to: CGPoint(x: point.x, y: point.y))
            return nil
        case "stopAfter":
            guard let seconds = Double(value), seconds >= 0 else { return "stopAfter takes seconds, 0 for never" }
            recordSeconds = seconds
            return nil
        case "whiteBalance":
            if value == "auto" {
                whiteBalanceLocked = false
                return nil
            }
            guard let kelvin = Float(value), (2000...10000).contains(kelvin) else {
                return "whiteBalance takes auto or 2000 to 10000"
            }
            temperature = kelvin
            whiteBalanceLocked = true
            return nil
        case "tint":
            guard let wanted = Float(value), (-150...150).contains(wanted) else { return "tint takes -150 to 150" }
            tint = wanted
            return nil
        case "focus":
            if value == "auto" {
                releaseFocus()
                return nil
            }
            guard let position = Float(value), (0...1).contains(position) else { return "focus takes auto or 0 to 1" }
            lensPosition = position
            focusLocked = true
            return nil
        case "exposureBias":
            guard let stops = Float(value), (-2...2).contains(stops) else { return "exposureBias takes -2 to 2" }
            exposureBias = stops
            return nil
        case "shutter":
            if value == "auto" {
                exposureLocked = false
                return nil
            }
            guard let denominator = Double(value), denominator >= frameRate else {
                return "shutter takes auto, or a denominator of at least the frame rate"
            }
            shutterStops = log2(denominator)
            exposureLocked = true
            return nil
        case "iso":
            guard let wanted = Double(value), isoRange.contains(wanted) else {
                return "iso takes \(Int(isoRange.lowerBound)) to \(Int(isoRange.upperBound))"
            }
            iso = Float(wanted)
            return nil
        default:
            return "Unknown setting \(name)"
        }
    }
}
