import SwiftUI
import VLCore

/// This phone's lens profiles: Apple's factory calibration for the lenses that give it, and the
/// field of view for the rest. Measured once, kept on the phone and out of presets, for
/// stabilization and lens correction to come.
struct LensesView: View {
    @EnvironmentObject private var model: AppModel
    let close: () -> Void
    @State private var profiles: [LensProfile] = []
    @State private var confirmingDelete = false

    var body: some View {
        Form {
            Section {
                Button("Measure Lenses") {
                    close()
                    model.measureLenses()
                }
                .disabled(model.isRecording)
            } footer: {
                Text("Releases the camera for a few seconds and takes a depth photo through the 1x and tele lens pairs, which carry Apple's factory calibration: focal length, optical centre and distortion. The ultra wide has none, so its focal length comes from its field of view.")
            }
            if profiles.isEmpty {
                Section {
                    Text("No lens measured on this phone yet.")
                        .foregroundStyle(.secondary)
                }
            }
            ForEach(profiles, id: \.fileName) { profile in
                Section(Self.name(profile.lens)) {
                    LabeledContent("Focal length", value: String(format: "%.1f px at %ld×%ld", profile.fx, profile.width, profile.height))
                    LabeledContent("Optical centre", value: String(format: "%.1f, %.1f", profile.cx, profile.cy))
                    LabeledContent("Field of view", value: String(format: "%.2f°", profile.fieldOfView))
                    if let range = profile.distortionRange {
                        LabeledContent("Distortion", value: String(format: "%+.2f%% at the edge, %ld points", range * 100, profile.distortionTable.count))
                    }
                    LabeledContent("Source", value: profile.source)
                    LabeledContent("Measured", value: profile.measured)
                }
            }
            if !profiles.isEmpty {
                Section {
                    ShareLink(items: profiles.map { LensProfile.folder.appendingPathComponent($0.fileName) }) {
                        Label("Share Profiles", systemImage: "square.and.arrow.up")
                    }
                    Button("Delete Profiles", role: .destructive) { confirmingDelete = true }
                } footer: {
                    Text("Saved as JSON in the lenses folder, which the Files app shows.")
                }
            }
        }
        .navigationTitle("Lenses")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { profiles = LensProfile.saved() }
        .confirmationDialog("Delete this phone's lens profiles?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                LensProfile.removeAll()
                profiles = []
            }
        }
    }

    static func name(_ lens: String) -> String {
        switch lens {
        case "back-wide": return "1x"
        case "back-ultrawide": return "Ultra Wide"
        case "back-tele": return "Tele"
        default: return lens
        }
    }
}
