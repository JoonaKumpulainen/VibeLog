import Foundation
import VLCore

extension AppModel {
    static let controlTestSeconds = 46.0

    /// Measures what changing each camera control costs during a recording. Every step logs
    /// frame and failure counts, so the gaps between steps show any lost frames.
    func runControlTest() {
        guard isStreaming, recordEncoded, !isRecording, isBusy == nil else { return }
        let steps: [(at: Double, label: String, action: () -> Void)] = [
            (8, "focus lens 0.2", { [camera] in camera.setFocus(.locked, lensPosition: 0.2) }),
            (12, "focus lens 0.9", { [camera] in camera.setFocus(.locked, lensPosition: 0.9) }),
            (16, "focus auto", { [camera] in camera.setFocus(.auto, lensPosition: 0.8) }),
            (20, "exposure 1/60 ISO 200", { [camera] in camera.setExposure(.locked, seconds: 1 / 60.0, iso: 200) }),
            (24, "exposure 1/120 ISO 400", { [camera] in camera.setExposure(.locked, seconds: 1 / 120.0, iso: 400) }),
            (28, "exposure auto", { [camera] in camera.setExposure(.auto, seconds: 1 / 100.0, iso: 100) }),
            (32, "white balance 3200 K", { [camera] in camera.setWhiteBalance(.locked, temperature: 3200, tint: 0) }),
            (36, "white balance 6500 K", { [camera] in camera.setWhiteBalance(.locked, temperature: 6500, tint: 0) }),
            (40, "white balance auto", { [camera] in camera.setWhiteBalance(.auto, temperature: 5600, tint: 0) }),
        ]
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
                logControlTest(step.label)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.controlTestSeconds + 3) { [self] in
            applyExposure()
            applyWhiteBalance()
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
