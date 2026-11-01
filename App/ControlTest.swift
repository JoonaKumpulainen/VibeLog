import Foundation
import VLCore

extension AppModel {
    static let controlTestSeconds = 46.0

    /// Measures what changing each camera control costs during a recording. Every step logs
    /// frame and failure counts, so the gaps between steps show any lost frames.
    func runControlTest() {
        guard isStreaming, recordEncoded, !isRecording, isBusy == nil else { return }
        let center = CGPoint(x: 0.5, y: 0.5)
        var steps: [(at: Double, label: String?, action: () -> Void)] = [
            (8, "tap focus center", { [camera] in camera.focus(at: center) }),
            (12, "tap focus corner", { [camera] in camera.focus(at: CGPoint(x: 0.3, y: 0.3)) }),
            (16, "rack focus", {}),
            (18, "rack done", {}),
            (20, "ISO ramp", {}),
            (22, "ramp done", {}),
            (24, "exposure auto", { [camera] in camera.setExposure(.auto, seconds: 1 / 100.0, iso: 100) }),
            (28, "bias +1", { [camera] in camera.setExposureBias(1) }),
            (32, "bias 0", { [camera] in camera.setExposureBias(0) }),
            (36, "focus auto", { [camera] in camera.setFocus(.auto, lensPosition: 0.8) }),
            (40, "meter center", { [camera] in camera.meter(at: center) }),
        ]
        // Dials send about ten changes a second.
        for tick in 0..<20 {
            let share = Float(tick) / 19
            steps.append((16 + Double(tick) / 10, nil, { [camera] in
                camera.setFocus(.locked, lensPosition: 0.3 + 0.5 * share)
            }))
            steps.append((20 + Double(tick) / 10, nil, { [camera] in
                camera.setExposure(.locked, seconds: 1 / 60.0, iso: 200 + 200 * share)
            }))
        }
        let savedSeconds = recordSeconds
        recordSeconds = Self.controlTestSeconds
        Log.shared.info("Control test started")
        toggleRecord()
        notice = "Control test running, keep still"
        logControlTest("baseline")

        for step in steps {
            DispatchQueue.main.asyncAfter(deadline: .now() + step.at) { [self] in
                guard isRecording else { return }
                step.action()
                if let label = step.label { logControlTest(label) }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.controlTestSeconds + 3) { [self] in
            applyExposure()
            applyBias()
            applyWhiteBalance()
            focusTapped = false
            applyFocus()
            recordSeconds = savedSeconds
            notice = "Control test finished, send the log"
            logControlTest("finished")
        }
    }

    private func logControlTest(_ label: String) {
        let snapshot = router.stats.snapshot()
        let capture = router.latestCapture
        Log.shared.info(String(
            format: "Control test %@: frames %d, fail %d, %.2f fps, gap max %.1f ms, 1/%.0f s, ISO %.0f, gains %@",
            label, snapshot.frames, snapshot.captureFailures, snapshot.rollingFPS, snapshot.gapMaxMs,
            capture.exposureSeconds > 0 ? 1 / capture.exposureSeconds : 0, capture.iso,
            capture.gains.map { String(format: "%.2f", $0) }.joined(separator: " ")))
    }
}
