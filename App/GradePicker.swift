import AVFoundation
import SwiftUI
import VLCore
import VLRecording

/// The exported and baked videos whose sidecars keep their grade, newest first, to copy one onto
/// an export. Picking one hands its grade back and closes the list.
struct GradePicker: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    /// The take being exported, which can't lend its own grade.
    let excluding: URL
    let onPick: (GradeRecipe) -> Void
    @State private var sources: [(take: Take, recipe: GradeRecipe)]? = nil

    var body: some View {
        NavigationStack {
            List {
                if let sources {
                    if sources.isEmpty {
                        Text("No exported or baked videos with a grade yet. Videos made before this version don't keep theirs.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(sources, id: \.take.id) { source in
                        Button {
                            onPick(source.recipe)
                            dismiss()
                        } label: {
                            GradeSourceRow(take: source.take, recipe: source.recipe, lookMissing: lookMissing(source.recipe))
                        }
                        .buttonStyle(.plain)
                    }
                } else {
                    ProgressView()
                }
            }
            .navigationTitle("Copy Grade From")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
        .task {
            let excluded = excluding
            sources = await Task.detached(priority: .userInitiated) {
                TakeLibrary.takes(in: Storage.videos).compactMap { take in
                    guard take.url != excluded, let recipe = GradeRecipe.from(metadata: take.info?.metadata) else { return nil }
                    return (take, recipe)
                }
            }.value
        }
    }

    private func lookMissing(_ recipe: GradeRecipe) -> Bool {
        !recipe.look.isEmpty && !model.isAvailableLook(recipe.look)
    }
}

private struct GradeSourceRow: View {
    let take: Take
    let recipe: GradeRecipe
    let lookMissing: Bool
    @State private var thumbnail: UIImage?

    var body: some View {
        HStack(spacing: 12) {
            Color.black
                .frame(width: 64, height: 64)
                .overlay {
                    if let thumbnail {
                        Image(uiImage: thumbnail).resizable().scaledToFill()
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 2) {
                Text(take.dateLabel)
                Text((TakeLibrary.isExport(take.url) ? "Exported" : "Baked") + ": " + recipe.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if lookMissing {
                    Text("Its look isn't on this phone, so the grade goes on the current look.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .task {
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: take.url))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 160, height: 160)
            if let frame = try? await generator.image(at: .zero) {
                thumbnail = UIImage(cgImage: frame.image)
            }
        }
    }
}
