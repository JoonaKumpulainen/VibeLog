import SwiftUI
import VLCore
import VLRecording

/// Settings, Advanced, Benchmark: runs the benchmark and shows everything it found, step by step,
/// in short words and numbers, with what failed and why, and what each warning before a take means.
struct BenchmarkView: View {
    @EnvironmentObject private var model: AppModel
    /// Closes Settings, so a running benchmark shows on the camera screen.
    let close: () -> Void

    private var progress: BenchmarkProgress { model.benchmark }
    private var encoders: EncoderSupport { model.encoderSupport }
    private var gpu: GPUSupport { model.gpuSupport }

    var body: some View {
        Form {
            runSection
            if !progress.summary.isEmpty {
                Section("Summary") {
                    ForEach(progress.summary.components(separatedBy: "\n"), id: \.self) { line in
                        Text(line)
                    }
                }
            }
            stepsSection
            lensSection
            encoderSection
            gpuSection
            memorySection
            warningsSection
        }
        .navigationTitle("Benchmark")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: Running

    private var runSection: some View {
        Section {
            LabeledContent("Status", value: statusText)
            if model.benchmarkRunning {
                Button("Cancel Benchmark", role: .destructive) { model.cancelBenchmark() }
            } else {
                Button(progress.finished || progress.results.isEmpty ? "Run Benchmark" : "Resume Benchmark") {
                    close()
                    model.startBenchmark(fresh: progress.finished)
                }
                Button("Encoders and GPU Only") {
                    close()
                    model.runEncoderTest()
                }
            }
        } footer: {
            Text("The full run takes about 5 minutes. Lay the phone down still, with 50% battery or more. It measures each lens, the encoders and the GPU, and records a few short test takes, which it deletes. Nothing is ever turned off: settings past this phone's limits only warn before a take.")
        }
    }

    private var statusText: String {
        if model.benchmarkRunning, let step = progress.running {
            return "Running: " + (AppModel.benchmarkStepNames[step] ?? step)
        }
        if let date = progress.finishedAt {
            let problems = progress.results.values.filter { $0.status != "done" }.count
            let when = date.formatted(date: .abbreviated, time: .shortened)
            return problems == 0 ? "Done, \(when)" : "Done with \(problems) problem\(problems == 1 ? "" : "s"), \(when)"
        }
        let left = progress.pending(AppModel.benchmarkSteps).count
        return left == AppModel.benchmarkSteps.count ? "Not run yet" : "Stopped, \(left) of \(AppModel.benchmarkSteps.count) steps left"
    }

    // MARK: Steps

    private static let stepPurpose = [
        "capture": "Streams RAW from each lens for 8 seconds and counts the frames that arrive.",
        "trials": "Records a few short test takes, then deletes them, to see what real takes hold.",
        "lenses": "Saves each lens's distortion profile from Apple's calibration.",
        "measure": "Times each codec and size, and each GPU setup, with the camera stopped.",
        "probe": "Lists the camera's formats and frame rates.",
    ]

    private var stepsSection: some View {
        Section {
            ForEach(AppModel.benchmarkSteps, id: \.self) { step in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(AppModel.benchmarkStepNames[step] ?? step)
                        Spacer()
                        StepBadge(result: progress.results[step], running: model.benchmarkRunning && progress.running == step)
                    }
                    Text(Self.stepPurpose[step] ?? "")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let result = progress.results[step] {
                        Text(Self.outcome(result))
                            .font(.caption)
                            .foregroundStyle(result.status == "done" ? Color.secondary : Color.orange)
                    }
                }
            }
        } header: {
            Text("Steps")
        } footer: {
            Text("A step that fails is skipped, and the rest still run. Run the benchmark again to measure it.")
        }
    }

    /// What a step's saved result means, in words.
    static func outcome(_ result: BenchmarkProgress.StepResult) -> String {
        let took = result.seconds >= 1 ? String(format: " Took %.0f s", result.seconds) : ""
        let heat = result.heat.isEmpty ? "" : (took.isEmpty ? " Phone was \(result.heat)" : ", phone \(result.heat)")
        let tail = took.isEmpty && heat.isEmpty ? "" : took + heat + "."
        switch result.status {
        case "done":
            return (result.detail == "finished" ? "Finished." : "Result: \(result.detail).") + tail
        case "crashed":
            return "The app closed during this step, so it was skipped. Its results are missing."
        case "skipped":
            return result.detail == "cancelled" ? "Skipped: you cancelled it." : "Skipped: \(result.detail)."
        default:
            return "Failed: \(reason(result.detail)).\(tail)"
        }
    }

    /// The saved failure detail, said plainly.
    static func reason(_ detail: String) -> String {
        if detail.hasPrefix("couldn't start: ") {
            let why = String(detail.dropFirst("couldn't start: ".count))
            if why == "a take is running" { return "it couldn't start because a take was recording" }
            if why == "the camera isn't running" { return "it couldn't start because the camera wasn't running" }
            if why.hasPrefix("busy: ") { return "it couldn't start because the app was busy (\(why.dropFirst(6)))" }
            return "it couldn't start"
        }
        if detail.hasPrefix("didn't finish in") { return "it took too long, \(detail)" }
        if detail == "no lenses" { return "the phone reported no cameras" }
        return detail
    }

    // MARK: Lenses

    @ViewBuilder private var lensSection: some View {
        if !progress.capture.isEmpty {
            Section {
                ForEach(Array(progress.capture.enumerated()), id: \.offset) { _, capture in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("\(capture.lens) lens at \(Int(capture.frameRate)) fps")
                            Spacer()
                            Verdict(good: capture.holds, text: capture.holds ? "Holds" : "Too slow")
                        }
                        RateBar(value: capture.fps, goal: capture.frameRate, scale: max(30, capture.frameRate))
                        Text(lensLine(capture))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("RAW from each lens")
            } footer: {
                Text("A lens holds a rate when it delivers within 1 frame a second of it. A lens that can't hold 30 is tried at 24.")
            }
        }
    }

    private func lensLine(_ capture: LensCapture) -> String {
        var parts = [String(format: "Got %.1f of %.0f frames a second", capture.fps, capture.frameRate)]
        if capture.missed > 0 { parts.append("\(capture.missed) missed") }
        if capture.failures > 0 { parts.append("\(capture.failures) failed captures") }
        parts.append("setup: \(capture.setup)")
        return parts.joined(separator: ", ") + "."
    }

    // MARK: Encoders

    @ViewBuilder private var encoderSection: some View {
        Section {
            if !encoders.measured {
                Text("Not measured yet.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(encoderRows, id: \.id) { row in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("\(row.codec), \(row.size)")
                            Spacer()
                            Verdict(good: row.good, text: row.verdict)
                        }
                        if let fps = row.fps {
                            RateBar(value: fps, goal: EncoderSupport.realTimeFPS, scale: max(60, fps))
                            Text(String(format: "Encoded %.0f frames a second.", fps) + (row.note.map { " " + $0 } ?? ""))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else if let note = row.note {
                            Text(note).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        } header: {
            Text("Encoders")
        } footer: {
            Text(encoderFooter)
        }
    }

    private var encoderFooter: String {
        var text = "A take needs 30 frames a second. A real take outranks the test: one that held proves its codec and size, and one that dropped frames always warns."
        if encoders.measured {
            text += encoders.method == .quick
                ? " Measured by the quick check with the camera on, which reads low. Run the benchmark for a careful measure."
                : " Measured with the camera stopped"
            if !encoders.heat.isEmpty, encoders.method != .quick { text += ", phone \(encoders.heat)" }
            if encoders.method != .quick { text += "." }
        }
        return text
    }

    private struct EncoderRow {
        var id: String
        var codec: String
        var size: String
        var fps: Double?
        var good: Bool
        var verdict: String
        var note: String?
    }

    private var encoderRows: [EncoderRow] {
        var rows: [EncoderRow] = []
        let ids = EncoderSupport.presets.map { ($0.id, $0.label) } + [(EncoderSupport.twelveBitID, "ProRes 4444 12-bit")]
        for (id, label) in ids {
            guard encoders.codecs.contains(id) || id == EncoderSupport.twelveBitID else { continue }
            let measured = encoders.fps[id] ?? [:]
            if measured.isEmpty {
                if encoders.codecs.contains(id) {
                    rows.append(EncoderRow(id: id, codec: label, size: "every size", fps: nil, good: false,
                                           verdict: "Failed", note: "The encoder refused or failed every size."))
                }
                continue
            }
            let sizes = measured.keys.sorted { (Int($0.split(separator: "x").first ?? "") ?? 0) > (Int($1.split(separator: "x").first ?? "") ?? 0) }
            for size in sizes {
                let fps = measured[size] ?? 0
                let strained = encoders.strained[id]?.contains(size) == true
                let proven = encoders.proven[id]?.contains(size) == true
                let verdict: (Bool, String, String?)
                if strained {
                    verdict = (false, "Warns", "A take in this dropped frames at the encoder.")
                } else if proven {
                    verdict = (true, "Proven", "A real take held 30 fps.")
                } else if fps >= EncoderSupport.comfortableFPS {
                    verdict = (true, "OK", nil)
                } else if fps >= EncoderSupport.realTimeFPS {
                    verdict = (true, "Just OK", "Little to spare once the camera and GPU share the phone.")
                } else {
                    verdict = (false, "Warns", "Under 30, so frames may drop.")
                }
                rows.append(EncoderRow(id: id + size, codec: label, size: size, fps: fps, good: verdict.0,
                                       verdict: verdict.1, note: verdict.2))
            }
        }
        return rows
    }

    // MARK: GPU

    @ViewBuilder private var gpuSection: some View {
        Section {
            if gpu.costs.isEmpty {
                Text("Not measured yet.")
                    .foregroundStyle(.secondary)
            } else {
                let heaviest = gpu.costs.values.max() ?? 1
                ForEach(gpu.costs.keys.sorted(), id: \.self) { key in
                    let cost = gpu.costs[key] ?? 0
                    let state = gpuState(key)
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(Self.setupName(key))
                            Spacer()
                            Verdict(good: state.good, text: state.verdict)
                        }
                        CostBar(value: cost, scale: heaviest)
                        Text(String(format: "%.1f ms a frame, timed alone. ", cost) + state.note)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        } header: {
            Text("GPU")
        } footer: {
            Text("The test times each setup alone, and a take costs two to three times that. Only takes decide: a setup warns once a take fell behind in it, or when it costs more than anything a long take has held here. With no long takes yet, nothing warns.")
        }
    }

    private func gpuState(_ key: String) -> (good: Bool, verdict: String, note: String) {
        if gpu.strained.contains(key) { return (false, "Warns", "A take fell behind in it.") }
        if gpu.strainedHot.contains(key) { return (false, "When hot", "A take fell behind once the phone got hot. It only warns with the heat fallback off.") }
        if gpu.proven.contains(key) { return (true, "Proven", "A take of 2.5 minutes or more held.") }
        if gpu.warning(for: key) != nil { return (false, "Warns", "Heavier than anything a long take has held here.") }
        return (true, "OK", gpu.proven.isEmpty ? "No long take yet to compare with." : "No heavier than a setup a take held.")
    }

    /// "maximum-look-malvar" as "Maximum, baked look, Malvar debayer".
    static func setupName(_ key: String) -> String {
        let parts = key.split(separator: "-").map(String.init)
        guard parts.count == 3 else { return key }
        let path = parts[0] == "maximum" ? "Maximum" : "Efficient"
        let work = ["log": "log", "look": "baked look", "fx": "baked look and FX"][parts[1]] ?? parts[1]
        let debayer = parts[2] == "malvar" ? "Malvar debayer" : "Bilinear debayer"
        return "\(path), \(work), \(debayer)"
    }

    // MARK: Memory

    @ViewBuilder private var memorySection: some View {
        if progress.memoryLeftMB != nil || progress.memoryUsedMB != nil {
            Section {
                if let left = progress.memoryLeftMB {
                    HStack {
                        Text("Least memory left")
                        Spacer()
                        Text("\(left) MB")
                        Verdict(good: left >= AppModel.tightMemoryMB, text: left >= AppModel.tightMemoryMB ? "OK" : "Tight")
                    }
                }
                if let used = progress.memoryUsedMB {
                    LabeledContent("Most the app used", value: "\(used) MB")
                }
            } header: {
                Text("Memory while streaming")
            } footer: {
                Text("Under \(AppModel.tightMemoryMB) MB left, the lighter Efficient path suits this phone better.")
            }
        }
    }

    // MARK: Warnings

    private var warningsSection: some View {
        Section {
            WarningRow(title: "Codec and size", text: "The encoder was under 30 fps in the test, or dropped frames in a take.")
            WarningRow(title: "GPU setup", text: "A take fell behind on the GPU in this setup, or it's heavier than anything a long take has held.")
            WarningRow(title: "Heat", text: "The phone is hot, or was recently, so a take may stop early or heat quickly.")
            WarningRow(title: "Storage", text: "Little time left to record at this codec and size.")
            WarningRow(title: "Battery", text: "Low battery can make a take stall.")
        } header: {
            Text("What the warnings before a take mean")
        } footer: {
            Text("Format choices past a limit show \" !\". You can still record with them.")
        }
    }
}

private struct StepBadge: View {
    let result: BenchmarkProgress.StepResult?
    let running: Bool

    var body: some View {
        if running {
            ProgressView()
        } else if let result {
            switch result.status {
            case "done": Verdict(good: true, text: "Done")
            case "skipped": Text("Skipped").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            case "crashed": Verdict(good: false, text: "App closed")
            default: Verdict(good: false, text: "Failed")
            }
        } else {
            Text("Not run").font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct Verdict: View {
    let good: Bool
    let text: String

    var body: some View {
        Label(text, systemImage: good ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
            .font(.caption.weight(.semibold))
            .foregroundStyle(good ? Color.green : Color.orange)
            .labelStyle(.titleAndIcon)
    }
}

/// A rate against what it needs: the bar's length is the rate, the line the goal.
private struct RateBar: View {
    let value: Double
    let goal: Double
    let scale: Double

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.2))
                Capsule()
                    .fill(value >= goal - 1 ? Color.green : Color.orange)
                    .frame(width: width * min(max(value / scale, 0), 1))
                Rectangle()
                    .fill(Color.primary)
                    .frame(width: 2)
                    .offset(x: width * min(goal / scale, 1) - 1)
            }
        }
        .frame(height: 8)
        .accessibilityHidden(true)
    }
}

/// A cost against the heaviest setup timed.
private struct CostBar: View {
    let value: Double
    let scale: Double

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.2))
                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: geometry.size.width * min(max(value / max(scale, 0.001), 0), 1))
            }
        }
        .frame(height: 8)
        .accessibilityHidden(true)
    }
}

private struct WarningRow: View {
    let title: String
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
            Text(text).font(.caption).foregroundStyle(.secondary)
        }
    }
}
