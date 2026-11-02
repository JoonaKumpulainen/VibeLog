import Foundation
import VLCore
import VLProcessing
import VLRecording

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
        guard let base = TestLinkAddress.base(testServer), !testToken.isEmpty else {
            testLinkState = "Needs a server and a token"
            testLinkOn = false
            return
        }
        testLink.start(base: base, token: testToken)
    }

    /// Sends what's selected in Diagnostics. Videos only go when asked for by name.
    func sendTakeFiles(video: URL) {
        guard testLinkOn else { return }
        if testSendsResults {
            testLink.send(file: Storage.videos.appendingPathComponent(video.lastPathComponent + ".json"))
            sendLog()
        }
        if testSendsGyro {
            for file in [TakeLibrary.gyroLog(for: video), TakeLibrary.captureTiming(for: video)]
            where FileManager.default.fileExists(atPath: file.path) {
                testLink.send(file: file)
            }
        }
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
            if isRecording, name != "tools" { return refused("Only tools change during a take") }
            if let problem = applyTestSetting(name, value) { return refused(problem) }
            return done()
        case "record":
            guard let seconds = command.seconds, seconds > 0 else { return refused("record needs seconds") }
            guard !isRecording else { return refused("Already recording") }
            guard isBusy == nil, playingTake == nil, recordEncoded else { return refused("The camera is busy") }
            record(seconds: seconds)
            return done()
        case "stop":
            if isRecording { toggleRecord() }
            return done()
        case "controlTest":
            guard isStreaming, !isRecording else { return refused("Needs a running stream and no take") }
            runControlTest()
            return done()
        case "zoomProbe":
            guard !isRecording else { return refused("A take is running") }
            runZoomRawProbe()
            return done()
        case "sendLog":
            sendLog()
            return done()
        case "listFiles":
            return done(testFiles().joined(separator: "\n"))
        case "sendFile":
            guard let name = command.name.flatMap(TestLinkAddress.safeName) else { return refused("sendFile needs a name") }
            guard let file = [Storage.videos, Storage.logs, Storage.probes]
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
        [Storage.videos, Storage.logs, Storage.probes].flatMap { folder in
            let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path)
            return (names ?? []).sorted()
        }
    }

    private var testStatus: [String: String] {
        [
            "recording": String(isRecording), "streaming": String(isStreaming),
            "elapsed": String(recordElapsed), "lens": currentLensLabel,
            "codec": encoderPreset.id, "size": encoderSize.label, "aspect": widescreen ? "16:9" : "4:3",
            "frameRate": frameRateLabel, "curve": processing.curve.label, "gamut": processing.gamut.label,
            "pipeline": processing.pipeline.rawValue, "tools": toolsLabel,
            "fixedFrameTime": String(fixedFrameTime), "uncompressedAudio": String(pcmAudio),
            "saveGyro": String(saveGyroLog), "captureTiming": String(logCaptureTiming),
            "fps": String(format: "%.2f", stats.rollingFPS), "drops": String(takeDrops),
            "gpuMs": String(format: "%.1f", pipelineStats.gpuRecentMs),
            "thermal": status.thermal, "battery": status.battery, "freeGB": String(status.freeDiskGB),
            "shutter": exposureLocked ? shutterLabel : "auto", "iso": exposureLocked ? String(Int(iso)) : "auto",
            "lastResult": lastResult ?? "",
        ]
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
        case "frameRate":
            guard let fps = Double(value), FrameRates.all.contains(fps) else {
                return "frameRate takes: \(FrameRates.all.map(FrameRates.label).joined(separator: ", "))"
            }
            frameRate = fps
            return nil
        case "codec": return pick(EncoderPreset.all, \.id) { encoderPreset = $0 }
        case "size": return pick(EncoderSize.all, \.label) { encoderSize = $0 }
        case "aspect": return pick(["4:3", "16:9"], { $0 }) { widescreen = $0 == "16:9" }
        case "curve": return pick(LogCurve.allCases, \.label) { processing.curve = $0 }
        case "gamut": return pick(Gamut.allCases, \.label) { processing.gamut = $0 }
        case "pipeline": return pick(PipelineMode.allCases, \.rawValue) { processing.pipeline = $0 }
        case "debayer": return pick(DemosaicMethod.allCases, \.label) { processing.demosaic = $0 }
        case "peaking": return pick(PeakingSensitivity.allCases, \.rawValue) { processing.peakingSensitivity = $0 }
        case "exposureOffset":
            guard let stops = Double(value), (-3...3).contains(stops) else { return "exposureOffset takes -3 to 3" }
            processing.exposureStops = stops
            return nil
        case "uncompressedAudio": return flag { pcmAudio = $0 }
        case "saveGyro": return flag { saveGyroLog = $0 }
        case "captureTiming": return flag { logCaptureTiming = $0 }
        case "fixedFrameTime": return flag { fixedFrameTime = $0 }
        case "keepRecordingWhenHot": return flag { processing.reduceLoadWhenHot = $0 }
        case "autoDuringTake": return flag { lockAtRoll = !$0 }
        case "tools":
            let wanted = value == "none" ? [] : value.split(separator: ",").map(String.init)
            let unknown = wanted.filter { Tool(rawValue: $0) == nil }
            guard unknown.isEmpty else {
                return "tools takes none or: \(Tool.allCases.map(\.rawValue).joined(separator: ","))"
            }
            for tool in Tool.allCases where isOn(tool) != wanted.contains(tool.rawValue) { toggle(tool) }
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
