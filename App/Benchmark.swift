import Foundation
import VLCapture
import VLCore

/// The benchmark: one guided run that measures this phone, offered at first launch and after an
/// iOS update, never started unasked. Each step is one of the measurements Diagnostics already
/// has, run in turn; progress is kept on disk after every step, so a crash is caught at the next
/// launch and that step skipped. Every step logs one `Benchmark:` line. A step that fails is
/// skipped and never blocks recording. See docs/decisions/benchmark.md.
extension AppModel {
    /// In order. The camera-on steps first, while the phone is coolest.
    static let benchmarkSteps = ["capture", "trials", "lenses", "measure", "probe"]
    static let benchmarkStepNames = [
        "capture": "Capture on each lens", "trials": "Trial takes", "lenses": "Lens profiles",
        "measure": "Encoders and GPU", "probe": "Camera formats",
    ]
    /// A step that hasn't finished in this long is given up on.
    static let benchmarkStepLimit: TimeInterval = 10 * 60

    /// For Diagnostics and the test link: the step under way, or how the last run ended.
    var benchmarkStatusText: String {
        if benchmarkRunning, let step = benchmark.running {
            return "running: " + (Self.benchmarkStepNames[step] ?? step)
        }
        if benchmark.finished {
            let failed = benchmark.results.values.filter { $0.status != "done" }.count
            return failed == 0 ? "finished" : "finished, \(failed) step\(failed == 1 ? "" : "s") failed"
        }
        let left = benchmark.pending(Self.benchmarkSteps).count
        return left == Self.benchmarkSteps.count ? "not run" : "\(left) of \(Self.benchmarkSteps.count) steps left"
    }

    /// At launch: notes a step the app died in, and offers the benchmark when this phone and iOS
    /// version haven't had one and the owner hasn't said Later.
    func checkBenchmarkAtLaunch() {
        if let crashed = benchmark.noteCrash() {
            benchmark.save()
            Log.shared.error(BenchmarkProgress.logLine(crashed, benchmark.results[crashed]!))
        }
        if !benchmark.finished, !benchmark.declined {
            // After the camera has settled, so the offer doesn't land on a black screen.
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [self] in
                if !isRecording, isBusy == nil, !benchmarkRunning { benchmarkOffer = true }
            }
        }
    }

    func declineBenchmark() {
        benchmarkOffer = false
        benchmark.declined = true
        benchmark.save()
        Log.shared.info("Benchmark: offered, and put off until asked or the next iOS version")
    }

    /// Starts or resumes the benchmark. `fresh` forgets earlier results, for Measure this phone again.
    func startBenchmark(fresh: Bool) {
        guard !isRecording, isBusy == nil, !benchmarkRunning else { return }
        benchmarkOffer = false
        if fresh || benchmark.finished {
            benchmark = BenchmarkProgress(device: SystemStatus.deviceModel,
                                          system: ProcessInfo.processInfo.operatingSystemVersionString)
        }
        benchmark.declined = false
        benchmarkRunning = true
        Log.shared.info("Benchmark: starting, \(benchmark.pending(Self.benchmarkSteps).joined(separator: ", ")) to go, "
            + "heat \(SystemStatus.thermalName), battery \(SystemStatus.batteryText), free \(SystemStatus.freeDisk / 1_000_000_000) GB")
        nextBenchmarkStep()
    }

    func cancelBenchmark() {
        guard benchmarkRunning else { return }
        benchmarkRunning = false
        Log.shared.info("Benchmark: cancelled; it resumes where it stopped when started again")
    }

    private func nextBenchmarkStep() {
        guard benchmarkRunning else { return }
        guard let step = benchmark.pending(Self.benchmarkSteps).first else {
            finishBenchmark()
            return
        }
        benchmark.begin(step)
        benchmark.save()
        let started = Date()
        let name = Self.benchmarkStepNames[step] ?? step
        let index = (Self.benchmarkSteps.firstIndex(of: step) ?? 0) + 1
        showNotice("Measuring this phone, \(index) of \(Self.benchmarkSteps.count): \(name)", seconds: 4)
        Log.shared.info("Benchmark: \(step) started")
        let finish: (String, String) -> Void = { [self] status, detail in
            let result = BenchmarkProgress.StepResult(
                status: status, detail: detail, heat: SystemStatus.thermalName,
                seconds: Date().timeIntervalSince(started))
            benchmark.finish(step, result)
            benchmark.save()
            Log.shared.info(BenchmarkProgress.logLine(step, result))
            // A moment between steps for the camera to settle.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [self] in nextBenchmarkStep() }
        }
        switch step {
        case "capture":
            measureCapturePerLens(finish: finish)
        case "trials":
            whenStreaming { [self] in
                runTrialTakes()
                guard trialState != nil else { finish("failed", "couldn't start: \(whyNotStarted)"); return }
                waitFor(step, until: { [self] in trialState == nil && !isRecording }, finish: finish)
            }
        case "lenses":
            whenStreaming { [self] in
                measureLenses()
                guard isBusy != nil else { finish("failed", "couldn't start: \(whyNotStarted)"); return }
                waitFor(step, until: { [self] in isBusy == nil && isStreaming }, finish: finish)
            }
        case "measure":
            whenStreaming { [self] in
                runEncoderTest()
                guard isBusy != nil else { finish("failed", "couldn't start: \(whyNotStarted)"); return }
                waitFor(step, until: { [self] in isBusy == nil && isStreaming }, finish: finish)
            }
        case "probe":
            whenStreaming { [self] in
                runProbe()
                guard isBusy != nil else { finish("failed", "couldn't start: \(whyNotStarted)"); return }
                waitFor(step, until: { [self] in isBusy == nil && isStreaming }, finish: finish)
            }
        default:
            finish("skipped", "unknown step")
        }
    }

    /// Why a measurement refused to start, for the log.
    private var whyNotStarted: String {
        if isRecording { return "a take is running" }
        if let busy = isBusy { return "busy: \(busy)" }
        if !isStreaming { return "the camera isn't running" }
        return "it refused"
    }

    /// Waits until the camera streams, starting it if it was stopped, then runs `then`.
    private func whenStreaming(_ then: @escaping () -> Void) {
        if isStreaming, isBusy == nil {
            then()
            return
        }
        if !isStreaming, isBusy == nil { toggleStream() }
        let deadline = Date().addingTimeInterval(30)
        func check() {
            if isStreaming, isBusy == nil { then(); return }
            guard Date() < deadline, benchmarkRunning else { then(); return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { check() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { check() }
    }

    /// Polls once a second until `done` holds, then reports the step with the app's last result.
    private func waitFor(_ step: String, until done: @escaping () -> Bool, finish: @escaping (String, String) -> Void) {
        let deadline = Date().addingTimeInterval(Self.benchmarkStepLimit)
        let before = lastResult
        func check() {
            if done() {
                let detail = lastResult != before ? (lastResult ?? "finished") : "finished"
                finish("done", detail)
            } else if Date() > deadline {
                finish("failed", "didn't finish in \(Int(Self.benchmarkStepLimit / 60)) minutes")
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { check() }
            }
        }
        // Give the step a moment to mark itself busy before checking.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { check() }
    }

    // MARK: Capture on each lens

    /// Streams each lens for about 8 seconds and counts what arrives. A stall moves the phone down
    /// the capture setup ladder as at any other time, and the lens is measured again on the new
    /// setup. A lens that can't hold 30 fps is tried at 24. Memory is sampled throughout.
    private func measureCapturePerLens(finish: @escaping (String, String) -> Void) {
        let originalLens = lensID
        let originalRate = frameRate
        let order = lenses.sorted { $0.zoom < $1.zoom }
        guard !order.isEmpty else {
            finish("failed", "no lenses")
            return
        }
        benchmark.capture = []
        var leastLeft = Int.max
        var mostUsed = 0

        func restore(_ status: String, _ detail: String) {
            lensID = originalLens
            frameRate = originalRate
            benchmark.memoryLeftMB = leastLeft == Int.max ? nil : leastLeft
            benchmark.memoryUsedMB = mostUsed == 0 ? nil : mostUsed
            finish(status, detail)
        }

        func measure(_ index: Int, rate: Double, attempt: Int) {
            guard benchmarkRunning else { restore("skipped", "cancelled"); return }
            guard index < order.count else {
                let best = LensCapture.bestRates(benchmark.capture)
                let summary = order.map { lens in
                    let rate = best[lens.zoomLabel] ?? 0
                    return "\(lens.zoomLabel) " + (rate > 0 ? "\(Int(rate)) fps" : "under 24 fps")
                }.joined(separator: ", ")
                restore("done", summary + ", setup \(captureSupport.setup.label), memory left \(leastLeft == Int.max ? 0 : leastLeft) MB")
                return
            }
            let lens = order[index]
            if lensID != lens.id { lensID = lens.id }
            if frameRate != rate { frameRate = rate }
            // The lens change and the frame rate rebuild the session; give it time, then start
            // the stream if it stopped.
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [self] in
                if !isStreaming, isBusy == nil { toggleStream() }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [self] in
                    let step = captureSupport.step
                    let first = router.stats.snapshot()
                    let started = Date()
                    var samples = 0
                    func sample() {
                        leastLeft = min(leastLeft, SystemStatus.availableMemory / 1_000_000)
                        mostUsed = max(mostUsed, SystemStatus.footprint / 1_000_000)
                        samples += 1
                        if samples < 8 {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { sample() }
                            return
                        }
                        let last = router.stats.snapshot()
                        let seconds = Date().timeIntervalSince(started)
                        // A stall rebuilt the session meanwhile: measure this lens again on the
                        // setup the phone moved to, up to the ladder's length.
                        if captureSupport.step != step || last.frames < first.frames || !isStreaming {
                            Log.shared.info("Benchmark: \(lens.zoomLabel) at \(Int(rate)) fps stalled, now on \(captureSupport.setup.label)")
                            if attempt < CaptureSetup.ladder.count {
                                measure(index, rate: rate, attempt: attempt + 1)
                            } else {
                                benchmark.capture.append(LensCapture(
                                    lens: lens.zoomLabel, frameRate: rate, fps: 0, missed: 0, failures: 0,
                                    setup: captureSupport.setup.label))
                                measure(index + 1, rate: originalRate, attempt: 0)
                            }
                            return
                        }
                        let result = LensCapture(
                            lens: lens.zoomLabel, frameRate: rate,
                            fps: Double(last.frames - first.frames) / seconds,
                            missed: last.estimatedMissed - first.estimatedMissed,
                            failures: last.captureFailures - first.captureFailures,
                            setup: captureSupport.setup.label)
                        benchmark.capture.append(result)
                        benchmark.save()
                        Log.shared.info(String(
                            format: "Benchmark: %@ at %.0f fps delivered %.1f fps, missed %d, failures %d, on %@, memory left %d MB",
                            lens.zoomLabel, rate, result.fps, result.missed, result.failures, result.setup,
                            SystemStatus.availableMemory / 1_000_000))
                        if !result.holds, rate > 24, FrameRates.all.contains(24) {
                            measure(index, rate: 24, attempt: 0)
                        } else {
                            measure(index + 1, rate: originalRate, attempt: 0)
                        }
                    }
                    sample()
                }
            }
        }
        whenStreaming { measure(0, rate: 30, attempt: 0) }
    }

    // MARK: Fitting the defaults

    /// What the app last chose by itself, by setting. A setting that still reads so is the app's,
    /// and may move; one that differs is the owner's choice and stays. A phone with no record yet
    /// keeps what it has, so an update never moves a choice already made.
    private static let fittedKey = "fittedDefaults"

    private var fittedNow: [String: String] {
        ["codec": encoderPreset.id, "size": encoderSize.label, "frameRate": String(frameRate),
         "pipeline": processing.pipeline.rawValue]
    }

    /// Notes the current settings as the app's own choice, as after the first launch's fit.
    func recordFittedDefaults() {
        UserDefaults.standard.set(fittedNow, forKey: Self.fittedKey)
    }

    /// Moves the settings nobody has touched to what the benchmark found, and says what moved.
    func fitDefaultsToBenchmark() -> [String] {
        guard let fitted = UserDefaults.standard.dictionary(forKey: Self.fittedKey) as? [String: String] else {
            recordFittedDefaults()
            return []
        }
        let untouched = { (key: String) in fitted[key] == self.fittedNow[key] }
        var moved: [String] = []
        if untouched("codec"), untouched("size"), !bakeLook, let best = encoderSupport.bestDefault(for: encoderPreset) {
            if best.preset != encoderPreset {
                moved.append("codec \(encoderPreset.label) to \(best.preset.label)")
                encoderPreset = best.preset
            }
            if best.size != encoderSize {
                moved.append("size \(encoderSize.label) to \(best.size.label)")
                encoderSize = best.size
            }
        }
        // The main lens decides the frame rate: 24 where it can't hold 30.
        let mainRate = LensCapture.bestRates(benchmark.capture)["1x"] ?? 30
        if untouched("frameRate"), mainRate == 24, frameRate > 24 {
            moved.append("frame rate to 24 fps, as the main lens can't stream 30 here")
            frameRate = 24
        }
        // Little memory left while streaming: the Efficient path, which skips the full-size image.
        if untouched("pipeline"), processing.pipeline == .maximum,
           let left = benchmark.memoryLeftMB, left < Self.tightMemoryMB {
            moved.append("the Efficient path, as only \(left) MB of memory was left while streaming")
            processing.pipeline = .efficient
        }
        // A setup that fell behind without heat on the Maximum path: the Efficient path.
        if untouched("pipeline"), processing.pipeline == .maximum,
           gpuSupport.strained.contains(where: { $0.hasPrefix("maximum-log") }) {
            moved.append("the Efficient path, as Maximum fell behind in a take here")
            processing.pipeline = .efficient
        }
        recordFittedDefaults()
        if !moved.isEmpty { Log.shared.info("Benchmark: fitted " + moved.joined(separator: "; ")) }
        return moved
    }

    /// Below this, in MB left while streaming at full size, the phone gets the lighter path.
    static let tightMemoryMB = 500

    // MARK: The end

    private func finishBenchmark() {
        benchmarkRunning = false
        benchmark.finishedAt = Date()
        benchmark.fitted = fitDefaultsToBenchmark()
        benchmark.save()
        let failed = benchmark.results.filter { $0.value.status != "done" }.map(\.key).sorted()
        Log.shared.info("Benchmark: finished" + (failed.isEmpty ? "" : ", without \(failed.joined(separator: ", "))"))
        benchmark.summary = benchmarkSummaryText(failed: failed)
        benchmark.save()
        Log.shared.info("Benchmark: summary: " + benchmark.summary.replacingOccurrences(of: "\n", with: " / "))
        benchmarkSummaryShown = true
    }

    /// After the summary: without log sharing, nothing tells the owner how it went on this phone.
    func benchmarkSummaryClosed() {
        if !logUploader.settings.on { benchmarkAsksSharing = true }
    }

    /// The one-time notice: what this phone records best, what it can't, and what moved.
    private func benchmarkSummaryText(failed: [String]) -> String {
        var lines: [String] = []
        if let best = encoderSupport.bestDefault(for: encoderPreset) {
            lines.append("Records best: \(best.preset.label) at \(best.size.label).")
        }
        let rates = LensCapture.bestRates(benchmark.capture)
        let lensWords = lenses.sorted { $0.zoom < $1.zoom }.compactMap { lens -> String? in
            guard let rate = rates[lens.zoomLabel] else { return nil }
            return rate > 0 ? "\(lens.zoomLabel) at \(Int(rate)) fps" : "\(lens.zoomLabel) not steadily"
        }
        if !lensWords.isEmpty { lines.append("RAW streams on " + lensWords.joined(separator: ", ") + ".") }
        var cannot: [String] = []
        if !encoderSupport.hasProRes {
            cannot.append("no ProRes encoder, so HEVC only")
        } else if let hq = encoderSupport.fps["prores422hq"]?[EncoderSize.all[0].label], hq < EncoderSupport.realTimeFPS {
            cannot.append(String(format: "ProRes 422 HQ at full size encodes at %.0f fps, under the 30 a take needs", hq))
        }
        for (lens, rate) in rates.sorted(by: { $0.key < $1.key }) where rate < 30 {
            cannot.append(rate > 0 ? "the \(lens) lens holds 24 fps, not 30" : "the \(lens) lens didn't stream RAW steadily")
        }
        if let left = benchmark.memoryLeftMB, left < Self.tightMemoryMB {
            cannot.append("little memory to spare (\(left) MB), so the lighter Efficient path suits it")
        }
        if !cannot.isEmpty { lines.append("Can't: " + cannot.joined(separator: "; ") + ".") }
        if !benchmark.fitted.isEmpty { lines.append("Changed for you: " + benchmark.fitted.joined(separator: "; ") + ".") }
        if !failed.isEmpty {
            lines.append("Not measured: " + failed.map { Self.benchmarkStepNames[$0] ?? $0 }.joined(separator: ", ")
                + ". Try Measure this phone again in Settings, Advanced, Diagnostics.")
        }
        lines.append("Every codec and setting stays available; ones past this phone's limit warn before a take.")
        return lines.joined(separator: "\n")
    }
}
