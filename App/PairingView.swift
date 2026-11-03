import SwiftUI
import VLProcessing

/// Which color space each log curve records, which curve each color space records, and the
/// viewfinder LUT that goes with each curve. Everything here is kept in presets.
struct PairingView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $model.processing.pairsGamut) {
                    explained(
                        "Pair curve and color space",
                        "Choosing a log curve chooses its color space below, and the other way round. Off, either changes alone.")
                }
            }
            Section {
                ForEach(LogCurve.allCases.filter { $0 != .appleLog2 }) { curve in
                    Picker(curve.label, selection: gamutBinding(for: curve)) {
                        ForEach(GamutPairing.gamuts(for: curve)) { Text($0.label).tag($0) }
                    }
                }
            } header: {
                Text("Each curve records")
            } footer: {
                Text("Apple Log 2 always records Apple Wide Gamut.")
            }
            Section {
                ForEach(Gamut.allCases.filter { $0 != .appleWideGamut }) { gamut in
                    Picker(gamut.label, selection: curveBinding(for: gamut)) {
                        ForEach(GamutPairing.curves(for: gamut)) { Text($0.label).tag($0) }
                    }
                }
            } header: {
                Text("Each color space records")
            }
            Section {
                ForEach(LogCurve.allCases) { curve in
                    let gamut = model.processing.pairing.gamut(for: curve)
                    Picker(selection: lutBinding(for: curve, in: gamut)) {
                        Text("None").tag("")
                        ForEach(model.lookNames, id: \.self) { Text($0).tag($0) }
                    } label: {
                        explained(curve.label, gamut.label)
                    }
                }
            } header: {
                Text("Viewfinder LUT for each curve")
            } footer: {
                Text("A LUT goes with a curve in its color space, since a conversion LUT expects both. Choosing the curve shows its LUT, and choosing a LUT here in Settings chooses its curve. Import LUTs under Viewfinder.")
            }
            Section {
                Button("Restore the standard pairs") { model.processing.pairing = .standard }
            }
        }
        .disabled(model.isRecording)
        .navigationTitle("Color spaces and LUTs")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func gamutBinding(for curve: LogCurve) -> Binding<Gamut> {
        Binding(
            get: { model.processing.pairing.gamut(for: curve) },
            set: { model.processing.pairing.setGamut($0, for: curve) })
    }

    private func curveBinding(for gamut: Gamut) -> Binding<LogCurve> {
        Binding(
            get: { model.processing.pairing.curve(for: gamut) },
            set: { model.processing.pairing.setCurve($0, for: gamut) })
    }

    private func lutBinding(for curve: LogCurve, in gamut: Gamut) -> Binding<String> {
        Binding(
            get: { model.linkedLUT(curve, gamut) ?? "" },
            set: { model.linkLUT($0, to: curve, in: gamut) })
    }

    private func explained(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
