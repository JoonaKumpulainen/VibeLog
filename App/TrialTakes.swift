import Foundation
import VLCore
import VLProcessing
import VLRecording

/// Real 20-second takes of the setups this phone would record best, with the camera, the GPU and
/// the encoder working together. Separate trials miss what only shows then: on the base iPhone 16,
/// full-size ProRes encoded fine on its own and in a take's first 6 seconds, then lost half its
/// frames. Each take feeds the encoder and GPU evidence as any take does, then is deleted with
/// its details, gyro log and timing. The settings are put back after. Part of the benchmark in
/// docs/status.md; run from Diagnostics or the test link.
extension AppModel {
    static let trialSeconds = 20.0

    /// "2 of 3" while trial takes run, else empty; the test link reports it.
    var trialProgress: String {
        guard let state = trialState else { return "" }
        return "\(state.index) of \(state.plan.count)"
    }

    /// One trial: what it changes before recording.
    struct Trial {
        let label: String
        let preset: EncoderPreset
        let size: EncoderSize
        let bake: Bool
    }

    /// The setups worth trying here: the best codec and size, ProRes 422 HQ at full size if the
    /// phone has it and it isn't already first, and the best one again with the look baked in.
    var trialPlan: [Trial] {
        var plan: [Trial] = []
        let best = encoderSupport.bestDefault(for: encoderPreset) ?? (encoderPreset, encoderSize)
        plan.append(Trial(label: "\(best.preset.label) \(best.size.label), log", preset: best.preset, size: best.size, bake: false))
        if let hq = EncoderPreset.all.first(where: { $0.id == "prores422hq" }), encoderSupport.supports(hq),
           !(best.preset.id == hq.id && best.size == EncoderSize.all[0]) {
            plan.append(Trial(label: "\(hq.label) \(EncoderSize.all[0].label), log", preset: hq, size: EncoderSize.all[0], bake: false))
        }
        // BAKE picks its own codec, HEVC 4:2:0 or with Bake to ProRes ProRes 422 HQ, so the label
        // doesn't name one; the result line says what was written.
        plan.append(Trial(label: "look baked in, \(best.size.label)", preset: best.preset, size: best.size, bake: true))
        return plan
    }

    /// Runs the plan one take at a time. Refused during a take, or with the camera stopped.
    func runTrialTakes() {
        guard !isRecording, isBusy == nil, isStreaming, trialState == nil else { return }
        let saved = TrialState.Saved(
            preset: encoderPreset, size: encoderSize, widescreen: widescreen, bake: bakeLook,
            lut: selectedLUT, twelveBit: twelveBitProRes)
        trialState = TrialState(plan: trialPlan, saved: saved)
        Log.shared.info("Trial takes: " + trialPlan.map(\.label).joined(separator: "; "))
        nextTrial()
    }

    /// Stops the run: a take under way ends early, and no more start. Its settings go back.
    func cancelTrialTakes() {
        guard var state = trialState else { return }
        state.cancelled = true
        trialState = state
        Log.shared.info("Trial takes: cancelled")
        if isRecording {
            // Its end calls nextTrial, which finishes the run.
            toggleRecord()
        } else {
            finishTrials()
        }
    }

    private func nextTrial() {
        guard var state = trialState else { return }
        guard state.index < state.plan.count, !state.cancelled else {
            finishTrials()
            return
        }
        let trial = state.plan[state.index]
        isBusy = nil
        // BAKE first: turning it on or off swaps the codec by itself, so the codec comes after,
        // except for a baked trial, which keeps the codec BAKE chose.
        bakeLook = trial.bake
        if !trial.bake { encoderPreset = trial.preset }
        encoderSize = trial.size
        widescreen = false
        twelveBitProRes = false
        // A take baked with no look chosen would bake nothing, so it borrows ACES 2.0.
        if trial.bake, selectedLUT.isEmpty { selectedLUT = "ACES 2.0" }
        state.index += 1
        trialState = state
        showNotice("Trial take \(state.index) of \(state.plan.count): \(trial.label)", seconds: 4)
        // A moment for the pipeline to take the new settings before the take starts.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [self] in
            guard let state = trialState, !state.cancelled, !isRecording else { return }
            record(seconds: Self.trialSeconds)
        }
    }

    /// Called at the end of every take; only acts during trials.
    func trialTakeFinished(file: String, summary: String) {
        guard var state = trialState, state.index > 0 else { return }
        let trial = state.plan[state.index - 1]
        state.lines.append("\(trial.label): \(summary), heat \(SystemStatus.thermalName)")
        trialState = state
        Log.shared.info("Trial take \(state.index): \(trial.label): \(summary)")
        // The take was only for measuring: it goes, with everything beside it.
        let url = Storage.videos.appendingPathComponent(file)
        if FileManager.default.fileExists(atPath: url.path) {
            delete([TakeLibrary.take(at: url)])
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [self] in nextTrial() }
    }

    private func finishTrials() {
        guard let state = trialState else { return }
        // BAKE first, since turning it off swaps the codec back by itself; then the codec as it was.
        bakeLook = state.saved.bake
        encoderPreset = state.saved.preset
        encoderSize = state.saved.size
        widescreen = state.saved.widescreen
        selectedLUT = state.saved.lut
        twelveBitProRes = state.saved.twelveBit
        trialState = nil
        let report = ["VibeLog trial takes \(Storage.timestamp())", "device=\(SystemStatus.deviceModel)",
                      "seconds each=\(Int(Self.trialSeconds))", ""] + state.lines
        let url = Storage.probes.appendingPathComponent("trials_\(Storage.timestamp()).txt")
        try? report.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        lastResult = "Trial takes saved: probes/\(url.lastPathComponent)"
        showNotice("Trial takes done")
        Log.shared.info("Trial takes done: probes/\(url.lastPathComponent)")
    }
}

/// Where a run of trial takes stands.
struct TrialState {
    struct Saved {
        let preset: EncoderPreset
        let size: EncoderSize
        let widescreen: Bool
        let bake: Bool
        let lut: String
        let twelveBit: Bool
    }

    let plan: [AppModel.Trial]
    let saved: Saved
    var index = 0
    var lines: [String] = []
    var cancelled = false
}
