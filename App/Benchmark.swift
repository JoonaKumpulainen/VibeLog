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

    // MARK: The end

    private func finishBenchmark() {
        benchmarkRunning = false
        benchmark.finishedAt = Date()
        benchmark.save()
        let failed = benchmark.results.filter { $0.value.status != "done" }.map(\.key).sorted()
        Log.shared.info("Benchmark: finished" + (failed.isEmpty ? "" : ", without \(failed.joined(separator: ", "))"))
        showNotice(failed.isEmpty ? "This phone is measured" : "This phone is measured, apart from \(failed.count) step\(failed.count == 1 ? "" : "s")", seconds: 4)
        // Without log sharing, nothing tells the owner how the benchmark went on this phone.
        if !logUploader.settings.on { benchmarkAsksSharing = true }
    }
}
