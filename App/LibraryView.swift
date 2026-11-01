import AVFoundation
import AVKit
import SwiftUI
import VLRecording

/// Everything behind the last take's thumbnail. It opens on that take, with the takes one step back.
struct TakeCover: View {
    @State private var path: [URL]

    init(url: URL) {
        _path = State(initialValue: [url])
    }

    var body: some View {
        NavigationStack(path: $path) {
            LibraryView()
                .navigationDestination(for: URL.self) { TakePlayer(url: $0) }
        }
        .preferredColorScheme(.dark)
        .tint(Tokens.held)
    }
}

/// Newest first. The camera is stopped behind this screen, so decoding thumbnails adds no load to
/// a take.
struct LibraryView: View {
    @EnvironmentObject private var model: AppModel
    @State private var takes: [Take] = []

    private let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 16) {
                ForEach(takes) { take in
                    NavigationLink(value: take.url) {
                        TakeCell(take: take)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(12)
        }
        .overlay {
            if takes.isEmpty {
                ContentUnavailableView("No takes", systemImage: "film")
            }
        }
        .background(Color.black)
        .navigationTitle("Takes")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Done") { model.closeLastTake() }
            }
        }
        // This also runs on return from a take that was deleted.
        .onAppear {
            DispatchQueue.global(qos: .utility).async {
                let found = TakeLibrary.takes()
                DispatchQueue.main.async { takes = found }
            }
        }
    }
}

private extension Take {
    var durationLabel: String? {
        info.map { Duration.seconds($0.seconds).formatted(.time(pattern: .minuteSecond)) }
    }

    var dateLabel: String {
        date?.formatted(date: .abbreviated, time: .shortened) ?? url.lastPathComponent
    }

    var sizeLabel: String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}

private struct TakeCell: View {
    let take: Take
    @State private var thumbnail: UIImage?

    private var summary: String {
        [take.durationLabel, take.info?.preset].compactMap { $0 }.joined(separator: " · ")
    }

    private var dropped: Int { take.info?.framesDropped ?? 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Color.black
                .aspectRatio(1, contentMode: .fit)
                .overlay {
                    if let thumbnail {
                        Image(uiImage: thumbnail)
                            .resizable()
                            .scaledToFill()
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: Tokens.panelRadius))
                .overlay(alignment: .topTrailing) {
                    if dropped > 0 {
                        StatusLine(text: "\(dropped) DROP", warns: true)
                            .padding(10)
                    }
                }
            Text(take.dateLabel)
                .font(.subheadline)
                .foregroundStyle(Tokens.value)
            Text(summary)
                .font(.caption)
                .foregroundStyle(Tokens.label)
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(dropped > 0 ? "\(dropped) frames dropped" : "")
        .task {
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: take.url))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 360, height: 360)
            if let frame = try? await generator.image(at: .zero) {
                thumbnail = UIImage(cgImage: frame.image)
            }
        }
    }
}

/// Plays a take, with its details, sharing and delete beneath it. The clip carries its own
/// rotation.
struct TakePlayer: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer
    @State private var take: Take
    @State private var showsInfo = false
    @State private var confirmsDelete = false

    init(url: URL) {
        _player = State(initialValue: AVPlayer(url: url))
        _take = State(initialValue: TakeLibrary.take(at: url))
    }

    var body: some View {
        VStack(spacing: 0) {
            VideoPlayer(player: player)
            HStack(spacing: 0) {
                Button { showsInfo = true } label: { action("Details", symbol: "info.circle") }
                ShareLink(item: take.url) { action("Share", symbol: "square.and.arrow.up") }
                Button(role: .destructive) {
                    confirmsDelete = true
                } label: {
                    action("Delete", symbol: "trash")
                }
            }
            .padding(.vertical, 4)
        }
        .background(Color.black)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Done") { model.closeLastTake() }
            }
        }
        .sheet(isPresented: $showsInfo) {
            TakeInfoView(take: take)
        }
        .confirmationDialog(
            "Delete this take?", isPresented: $confirmsDelete, titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                player.replaceCurrentItem(with: nil)
                model.delete(take)
                dismiss()
            }
        } message: {
            Text("This can't be undone.")
        }
        .onAppear { player.play() }
        .onDisappear { player.pause() }
    }

    private func action(_ title: String, symbol: String) -> some View {
        Label(title, systemImage: symbol)
            .labelStyle(.titleAndIcon)
            .font(.subheadline)
            .frame(maxWidth: .infinity, minHeight: 44)
            .contentShape(Rectangle())
    }
}

/// What the take was recorded with, from its sidecar.
private struct TakeInfoView: View {
    @Environment(\.dismiss) private var dismiss
    let take: Take

    private var recording: [(String, String)] {
        guard let info = take.info else { return [] }
        var rows = [
            ("Codec", info.preset),
            ("Size", "\(info.width)x\(info.height)"),
            ("Length", take.durationLabel ?? "-"),
            ("Frames written", "\(info.framesWritten)"),
            ("Frames dropped", "\(info.framesDropped)"),
            ("Measured rate", String(format: "%.2f fps", info.fps)),
            ("Data rate", String(format: "%.0f MB/s", info.megabytesPerSecond)),
        ]
        if let failure = info.failure { rows.append(("Failure", failure)) }
        return rows
    }

    private var picture: [(String, String)] {
        let names = [
            ("frameRate", "Frame rate"), ("curve", "Log curve"), ("gamut", "Gamut"),
            ("aspect", "Aspect"), ("exposureStops", "Exposure offset"),
            ("exposureDuringTake", "Exposure"), ("whiteBalanceDuringTake", "White balance"),
            ("pipeline", "Pipeline"), ("orientation", "Hold"),
            ("reducedLoadAtStart", "Reduced load at start"),
        ]
        return names.compactMap { key, name in take.info?.metadata[key].map { (name, $0) } }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    LabeledContent("Date", value: take.dateLabel)
                    LabeledContent("File size", value: take.sizeLabel)
                    LabeledContent("File", value: take.url.lastPathComponent)
                }
                if !recording.isEmpty {
                    Section("Recording") { rows(recording) }
                }
                if !picture.isEmpty {
                    Section("Picture") { rows(picture) }
                }
            }
            .navigationTitle("Details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
        .tint(Tokens.held)
    }

    private func rows(_ rows: [(String, String)]) -> some View {
        ForEach(rows, id: \.0) { LabeledContent($0.0, value: $0.1) }
    }
}
