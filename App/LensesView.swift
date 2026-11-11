import SwiftUI
import VLCore

/// This phone's lens profiles: Apple's factory calibration for the lenses that give it, and the
/// field of view for the rest. Measured once, kept on the phone and out of presets, for
/// stabilization and lens correction to come.
struct LensesView: View {
    @EnvironmentObject private var model: AppModel
    let close: () -> Void
    @State private var profiles: [LensProfile] = []
    /// The same lenses written as Gyroflow lens profiles, for the lenses Apple gave a table for.
    @State private var gyroflowFiles: [URL] = []
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
                Text("Releases the camera for about 15 seconds and takes five depth photos through each of the 1x and tele lens pairs, averaged, which carry Apple's factory calibration: focal length, optical centre and distortion. The ultra wide has none, so its focal length comes from its field of view.")
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
                    if let captures = profile.captures, captures > 1 {
                        LabeledContent(
                            "Captures",
                            value: String(
                                format: "%ld, centre within %.1f px, focal length within %.2f%%",
                                captures, profile.centreSpread ?? 0, (profile.focalSpread ?? 0) * 100))
                    }
                    if let focus = profile.focusPosition {
                        LabeledContent("Focus held at", value: String(format: "%.2f of the way to far", focus))
                    }
                    LabeledContent("Source", value: profile.source)
                    LabeledContent("Measured", value: profile.measured)
                }
            }
            if !gyroflowFiles.isEmpty {
                Section {
                    ShareLink(items: gyroflowFiles) {
                        Label("Share for Gyroflow", systemImage: "gyroscope")
                    }
                } footer: {
                    Text("Lens profiles Gyroflow loads, one for open gate and one for 16:9 for each lens with Apple's calibration, for takes with lens distortion correction off. Gyroflow fits them to smaller sizes itself. The ultra wide has none, and the readout time is left for Gyroflow to estimate.")
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
        .onAppear {
            profiles = LensProfile.saved()
            gyroflowFiles = GyroflowProfile.write(profiles)
        }
        .confirmationDialog("Delete this phone's lens profiles?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                LensProfile.removeAll()
                profiles = []
                gyroflowFiles = []
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
