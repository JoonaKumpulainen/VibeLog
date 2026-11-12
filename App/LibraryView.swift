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
    @State private var isSelecting = false
    @State private var selected: Set<URL> = []
    @State private var toDelete: [Take] = []
    @State private var confirmsDelete = false

    /// Two columns upright, and as many as fit when turned.
    private let columns = [GridItem(.adaptive(minimum: 170), spacing: 12)]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 16) {
                ForEach(takes) { take in
                    NavigationLink(value: take.url) {
                        TakeCell(take: take)
                    }
                    .buttonStyle(.plain)
                    .overlay { if isSelecting { selectionButton(take) } }
                    .contextMenu {
                        Button("Delete", systemImage: "trash", role: .destructive) { confirmDelete([take]) }
                    }
                }
            }
            .padding(12)
        }
        .overlay {
            if takes.isEmpty {
                ContentUnavailableView("No takes", systemImage: "film")
            }
        }
        .safeAreaInset(edge: .bottom) {
            if isSelecting {
                Button("Delete \(selected.count)", systemImage: "trash", role: .destructive) {
                    confirmDelete(takes.filter { selected.contains($0.url) })
                }
                .disabled(selected.isEmpty)
                .frame(maxWidth: .infinity, minHeight: 44)
                .background(Tokens.opaquePanel)
            }
        }
        .background(Color.black)
        .navigationTitle(isSelecting ? "\(selected.count) selected" : "Takes")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                if !takes.isEmpty {
                    Button(isSelecting ? "Cancel" : "Select") {
                        isSelecting.toggle()
                        selected = []
                    }
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("Done") { model.closeLastTake() }
            }
        }
        .confirmationDialog(
            toDelete.count == 1 ? "Delete this take?" : "Delete \(toDelete.count) takes?",
            isPresented: $confirmsDelete, titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                model.delete(toDelete)
                takes.removeAll { take in toDelete.contains { $0.url == take.url } }
                isSelecting = false
                selected = []
            }
        } message: {
            Text("The video and its details can't be recovered.")
        }
        // This also runs on return from a take that was deleted.
        .onAppear {
            DispatchQueue.global(qos: .utility).async {
                let found = TakeLibrary.takes()
                DispatchQueue.main.async { takes = found }
            }
        }
    }

    private func confirmDelete(_ takes: [Take]) {
        toDelete = takes
        confirmsDelete = true
    }

    /// Lies over a take, so its cell and thumbnail stay as they are.
    private func selectionButton(_ take: Take) -> some View {
        let isOn = selected.contains(take.url)
        return Button {
            if isOn { selected.remove(take.url) } else { selected.insert(take.url) }
        } label: {
            Color.clear
                .contentShape(Rectangle())
                .overlay(alignment: .topLeading) {
                    Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                        .font(.title2)
                        .foregroundStyle(isOn ? Tokens.held : Tokens.value)
                        .padding(8)
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(take.dateLabel)
        .accessibilityAddTraits(isOn ? .isSelected : [])
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
    @State private var showsExport = false
    @State private var confirmsDelete = false
    @Environment(\.verticalSizeClass) private var verticalSize

    init(url: URL) {
        _player = State(initialValue: AVPlayer(url: url))
        _take = State(initialValue: TakeLibrary.take(at: url))
    }

    var body: some View {
        // Turned, the actions move beside the picture, which keeps the full height.
        let turned = verticalSize == .compact
        let page = turned ? AnyLayout(HStackLayout(spacing: 0)) : AnyLayout(VStackLayout(spacing: 0))
        let actions = turned ? AnyLayout(VStackLayout(spacing: 0)) : AnyLayout(HStackLayout(spacing: 0))
        page {
            VideoPlayer(player: player)
            actions {
                Button { showsInfo = true } label: { action("Details", symbol: "info.circle") }
                ShareLink(items: take.files) { action("Share", symbol: "square.and.arrow.up") }
                Button {
                    player.pause()
                    showsExport = true
                } label: {
                    // A take with its look baked in can only be steadied.
                    action(ExportChoice.isLog(take) ? "Export" : "Stabilize", symbol: ExportChoice.isLog(take) ? "wand.and.stars" : "gyroscope")
                }
                Button(role: .destructive) {
                    confirmsDelete = true
                } label: {
                    action("Delete", symbol: "trash")
                }
            }
            .frame(width: turned ? 120 : nil)
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
        .sheet(isPresented: $showsExport) {
            ExportView(take: take)
        }
        .confirmationDialog(
            "Delete this take?", isPresented: $confirmsDelete, titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                player.replaceCurrentItem(with: nil)
                model.delete([take])
                dismiss()
            }
        } message: {
            Text("The video and its details can't be recovered.")
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
            ("Missed by the camera", info.missed.map(String.init) ?? "-"),
            ("Duplicates skipped", info.duplicates.map(String.init) ?? "-"),
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
            ("look", "Look"), ("exportedFrom", "Exported from"),
            ("exposureDuringTake", "Exposure"), ("shutter", "Shutter"), ("iso", "ISO"),
            ("whiteBalanceDuringTake", "White balance"), ("whiteBalance", "White balance values"),
            ("pipeline", "Pipeline"), ("debayer", "Debayer"), ("heatChanges", "Heat changes"),
            ("hotPath", "Pipeline when hot"), ("hotDebayer", "Debayer when hot"),
            ("orientation", "Hold"), ("lens", "Lens"), ("distortionCorrection", "Lens correction"),
            ("tools", "Tools"), ("audio", "Audio"), ("frameTime", "Frame time"), ("fileTag", "File tag"),
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
                    LabeledContent("Gyro log", value: take.files.count > 1 ? "Saved" : "None")
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
